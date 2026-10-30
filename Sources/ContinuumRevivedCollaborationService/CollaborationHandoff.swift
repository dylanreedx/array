import Foundation
import Crypto
import GRDB
import ContinuumRevivedCollaborationProtocol

extension CollaborationStore {
    static func validateHandoffCiphertext(_ db: Database, keyData: Data) throws {
        let key = SymmetricKey(data: keyData)
        func decode<T: Decodable>(_ type: T.Type, _ bytes: Data) throws -> T {
            try JSONDecoder().decode(type, from: AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key))
        }
        if try db.tableExists("agent_control") {
            for row in try Row.fetchAll(db, sql: "SELECT area,object,state FROM agent_control") {
                let state = try decode(Collaboration.AgentControlState.self, row["state"])
                guard state.area.rawValue == UUID(uuidString: row["area"]), state.object.rawValue == UUID(uuidString: row["object"]) else { throw CollaborationStoreError.invalidDatabaseKey }
            }
        }
        if try db.tableExists("agent_control_operations") {
            for row in try Row.fetchAll(db, sql: "SELECT area,result FROM agent_control_operations") {
                let state = try decode(Collaboration.AgentControlState.self, row["result"])
                guard state.area.rawValue == UUID(uuidString: row["area"]) else { throw CollaborationStoreError.invalidDatabaseKey }
            }
        }
        if try db.tableExists("agent_dispatches") {
            for row in try Row.fetchAll(db, sql: "SELECT area,id,command FROM agent_dispatches") {
                let command = try decode(Collaboration.AgentDispatchCommand.self, row["command"])
                guard command.area.rawValue == UUID(uuidString: row["area"]), command.id == UUID(uuidString: row["id"]) else { throw CollaborationStoreError.invalidDatabaseKey }
            }
        }
    }
    static func registerHandoffMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("collaboration-v4-agent-handoff") { db in
            try db.execute(sql: """
                CREATE TABLE agent_control(area TEXT NOT NULL REFERENCES areas(id), object TEXT NOT NULL,
                  state BLOB NOT NULL, PRIMARY KEY(area,object));
                CREATE TABLE agent_control_operations(area TEXT NOT NULL REFERENCES areas(id), operation TEXT NOT NULL,
                  actor TEXT NOT NULL REFERENCES devices(id), digest BLOB NOT NULL, result BLOB NOT NULL,
                  PRIMARY KEY(area,operation));
                CREATE TABLE agent_dispatches(area TEXT NOT NULL REFERENCES areas(id), id TEXT NOT NULL,
                  object TEXT NOT NULL, host TEXT NOT NULL REFERENCES hosts(id), actor TEXT NOT NULL REFERENCES devices(id),
                  digest BLOB NOT NULL, command BLOB NOT NULL, phase TEXT NOT NULL, claim TEXT,
                  PRIMARY KEY(area,id));
                CREATE INDEX agent_dispatch_host_pending ON agent_dispatches(area,host,phase);
                """)
        }
    }

    /// Publication withdrawal is definitive for commands that have not crossed
    /// admission. Resolve their receipts in the same document transaction even
    /// when removing the last source means its host will no longer poll. An
    /// attempted dispatch retains its outcome/uncertainty for host recovery.
    func refreshHandoffAccess(_ db: Database, area: UUID, document: SharedArea.Document) throws {
        var sources: [SharedArea.ID<SharedArea.Object>: SharedArea.Source] = [:]
        for item in document.items where item.kind == .agentObservation {
            if let source = item.source { sources[item.id] = source }
        }
        let rows = try Row.fetchAll(db, sql: "SELECT id,command FROM agent_dispatches WHERE area=? AND phase IN ('queued','claimed')",
            arguments: [area.uuidString])
        for row in rows {
            let command = try unseal(Collaboration.AgentDispatchCommand.self, row["command"])
            guard sources[command.object] != command.source else { continue }
            try db.execute(sql: "UPDATE agent_dispatches SET phase='refused' WHERE area=? AND id=?",
                arguments: [area.uuidString, row["id"] as String])
        }
    }

    public func registerAgentHost(token: String, area: UUID, request: Collaboration.AgentHostRegistration) throws -> Collaboration.AgentControlState {
        try database.write { db in
            let caller = try authenticate(db, token), current = try scope(db, caller, area)
            guard current.epoch == request.epoch else { throw CollaborationStoreError.staleEpoch }
            let source = try agentSource(db, area: area, object: request.object)
            try requireSourceHost(db, caller: caller, source: source)
            if let prior = try control(db, area: area, object: request.object) {
                guard prior.source == source else { throw CollaborationStoreError.unavailable }
                if prior.hostGeneration == request.generation, prior.epoch == current.epoch { return prior }
                guard prior.revision < UInt64.max else { throw CollaborationStoreError.invalidRequest }
                let state = Collaboration.AgentControlState(area: .init(area), object: request.object, source: source,
                    hostGeneration: request.generation, epoch: current.epoch, revision: prior.revision + 1, controller: source.owner)
                try saveControl(db, state)
                // A new execution binding cannot consume requests addressed to
                // its retired generation. Claimed/attempted requests stay honest.
                try db.execute(sql: "UPDATE agent_dispatches SET phase='refused' WHERE area=? AND object=? AND phase='queued'",
                    arguments: [area.uuidString, request.object.rawValue.uuidString])
                return state
            }
            let state = Collaboration.AgentControlState(area: .init(area), object: request.object, source: source,
                hostGeneration: request.generation, epoch: current.epoch, revision: 1, controller: source.owner)
            try saveControl(db, state)
            return state
        }
    }

    public func agentControl(token: String, area: UUID, object: SharedArea.ID<SharedArea.Object>) throws -> Collaboration.AgentControlState {
        try database.read { db in
            let caller = try authenticate(db, token); _ = try scope(db, caller, area)
            let source = try agentSource(db, area: area, object: object)
            guard let state = try control(db, area: area, object: object), state.source == source else { throw CollaborationStoreError.unavailable }
            return state
        }
    }

    public func changeAgentControl(token: String, area: UUID, object: SharedArea.ID<SharedArea.Object>,
                                   request: Collaboration.AgentControlMutation) throws -> Collaboration.AgentControlState {
        try database.write { db in
            let caller = try authenticate(db, token), current = try scope(db, caller, area)
            let digest = try handoffDigest(request, object: object)
            if let old = try Row.fetchOne(db, sql: "SELECT actor,digest,result FROM agent_control_operations WHERE area=? AND operation=?",
                                         arguments: [area.uuidString, request.id.uuidString]) {
                guard old["actor"] as String == caller.device.uuidString, old["digest"] as Data == digest else { throw SharedArea.Failure.changedIntent }
                return try unseal(Collaboration.AgentControlState.self, old["result"])
            }
            guard current.epoch == request.epoch else { throw CollaborationStoreError.staleEpoch }
            let source = try agentSource(db, area: area, object: object)
            guard var state = try control(db, area: area, object: object), state.source == source else { throw CollaborationStoreError.unavailable }
            guard state.epoch == current.epoch, state.hostGeneration == request.hostGeneration, state.revision == request.expectedRevision else { throw SharedArea.Failure.conflict }
            switch request.action {
            case .offer(let offer):
                guard caller.person == source.owner, current.role != .viewer, offer.recipient != caller.person else { throw CollaborationStoreError.forbidden }
                let recipient = Collaboration.Identity(person: offer.recipient, device: caller.device)
                guard try scope(db, recipient, area).role != .viewer else { throw CollaborationStoreError.forbidden }
                state.offer = offer
            case .accept(let offerID):
                guard current.role != .viewer, let offer = state.offer, offer.id == offerID,
                      offer.recipient == caller.person else { throw CollaborationStoreError.forbidden }
                state.controller = caller.person; state.offer = nil
            case .reclaim:
                guard caller.person == source.owner else { throw CollaborationStoreError.forbidden }
                state.controller = source.owner; state.offer = nil
            }
            guard state.revision < UInt64.max else { throw CollaborationStoreError.invalidRequest }
            state.revision += 1
            try saveControl(db, state)
            try db.execute(sql: "INSERT INTO agent_control_operations(area,operation,actor,digest,result) VALUES (?,?,?,?,?)",
                arguments: [area.uuidString, request.id.uuidString, caller.device.uuidString, digest, try seal(state)])
            return state
        }
    }

    public func enqueueAgentPrompt(token: String, area: UUID, object: SharedArea.ID<SharedArea.Object>,
                                   request: Collaboration.AgentPromptRequest) throws -> Collaboration.AgentDispatchReceipt {
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, request.text.utf8.count <= 65_536 else {
            throw CollaborationStoreError.invalidRequest
        }
        return try database.write { db in
            let caller = try authenticate(db, token), current = try scope(db, caller, area)
            let digest = try handoffDigest(request, object: object)
            try expireDispatches(db, area: area)
            if let row = try dispatchRow(db, area: area, id: request.id) {
                guard row["actor"] as String == caller.device.uuidString, row["digest"] as Data == digest else { throw SharedArea.Failure.changedIntent }
                return try dispatchReceipt(row)
            }
            guard current.epoch == request.epoch else { throw CollaborationStoreError.staleEpoch }
            guard current.role != .viewer else { throw CollaborationStoreError.forbidden }
            let source = try agentSource(db, area: area, object: object)
            guard let state = try control(db, area: area, object: object), state.source == source,
                  state.epoch == current.epoch, state.hostGeneration == request.hostGeneration, state.revision == request.controlRevision else { throw SharedArea.Failure.conflict }
            guard state.controller == caller.person else { throw CollaborationStoreError.forbidden }
            let document = try handoffDocument(db, area: area)
            guard let context = document.contexts.first(where: { $0.id == request.contextRevision }),
                  document.items.contains(where: { $0.id == context.object }),
                  document.contexts.last(where: { $0.object == context.object })?.id == context.id else { throw SharedArea.Failure.conflict }
            let command = Collaboration.AgentDispatchCommand(id: request.id, area: .init(area), object: object, source: source,
                requester: caller, epoch: current.epoch, controlRevision: state.revision, hostGeneration: state.hostGeneration,
                context: context, text: request.text, mode: request.mode)
            try db.execute(sql: "INSERT INTO agent_dispatches(area,id,object,host,actor,digest,command,phase,created) VALUES (?,?,?,?,?,?,?,'queued',?)",
                arguments: [area.uuidString, request.id.uuidString, object.rawValue.uuidString, source.host.rawValue.uuidString,
                            caller.device.uuidString, digest, try seal(command), clock().timeIntervalSince1970])
            return .init(command: command, phase: .queued)
        }
    }

    public func agentDispatchReceipt(token: String, area: UUID, id: UUID) throws -> Collaboration.AgentDispatchReceipt {
        try database.write { db in
            let caller = try authenticate(db, token); _ = try scope(db, caller, area)
            try expireDispatches(db, area: area)
            guard let row = try dispatchRow(db, area: area, id: id) else { throw CollaborationStoreError.unavailable }
            let receipt = try dispatchReceipt(row)
            guard receipt.command.requester.person == caller.person || receipt.command.source.owner == caller.person else { throw CollaborationStoreError.forbidden }
            return receipt
        }
    }

    public func pendingAgentDispatches(token: String, area: UUID, host: SharedArea.ID<SharedArea.Host>) throws -> [Collaboration.AgentDispatchReceipt] {
        try database.write { db in
            let caller = try authenticate(db, token); _ = try scope(db, caller, area)
            guard try String.fetchOne(db, sql: "SELECT device FROM hosts WHERE id=?", arguments: [host.rawValue.uuidString]) == caller.device.uuidString else { throw CollaborationStoreError.forbidden }
            try expireDispatches(db, area: area)
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM agent_dispatches WHERE area=? AND host=? AND phase IN ('queued','claimed','dispatching') ORDER BY rowid LIMIT 64",
                arguments: [area.uuidString, host.rawValue.uuidString])
            var result: [Collaboration.AgentDispatchReceipt] = []
            for row in rows {
                let receipt = try dispatchReceipt(row)
                if receipt.phase == .dispatching {
                    // A changed grant cannot erase the original host's known
                    // outcome. It may report that outcome, never dispatch anew.
                    result.append(receipt); continue
                }
                do { try validateDispatchAuthority(db, receipt.command) }
                catch {
                    if receipt.phase == .queued || receipt.phase == .claimed {
                        try db.execute(sql: "UPDATE agent_dispatches SET phase='refused' WHERE area=? AND id=?",
                            arguments: [area.uuidString, receipt.command.id.uuidString])
                    }
                    continue
                }
                result.append(receipt)
            }
            return result
        }
    }

    /// Claims and admission never invoke a provider. The original host owns the
    /// irreversible local attempt marker and its actual supervisor acceptance.
    public func claimAgentDispatch(token: String, area: UUID, id: UUID, claim: Collaboration.AgentHostClaim,
                                   admit: Bool = false) throws -> Collaboration.AgentDispatchReceipt {
        try database.write { db in
            let caller = try authenticate(db, token); _ = try scope(db, caller, area)
            try expireDispatches(db, area: area)
            guard let row = try dispatchRow(db, area: area, id: id) else { throw CollaborationStoreError.unavailable }
            let receipt = try dispatchReceipt(row)
            try requireSourceHost(db, caller: caller, source: receipt.command.source)
            guard claim.hostGeneration == receipt.command.hostGeneration else { throw SharedArea.Failure.conflict }
            if let existing = receipt.claimID, existing != claim.claimID { throw SharedArea.Failure.conflict }
            if receipt.phase.isFinal {
                if admit && receipt.phase == .accepted && receipt.command.mode == .queue {
                    // Array accepted this into its durable next-turn queue.
                    // Starting that queued prompt still owes current authority.
                    try validateDispatchAuthority(db, receipt.command)
                }
                return receipt
            }
            try validateDispatchAuthority(db, receipt.command)
            if admit {
                guard receipt.claimID == claim.claimID, receipt.phase == .claimed || receipt.phase == .dispatching else { throw CollaborationStoreError.forbidden }
            }
            let phase: Collaboration.AgentDispatchPhase = admit ? .dispatching : receipt.phase == .dispatching ? .dispatching : .claimed
            try db.execute(sql: "UPDATE agent_dispatches SET claim=?,phase=? WHERE area=? AND id=?",
                arguments: [claim.claimID.uuidString, phase.rawValue, area.uuidString, id.uuidString])
            return .init(command: receipt.command, phase: phase, claimID: claim.claimID)
        }
    }

    public func finishAgentDispatch(token: String, area: UUID, id: UUID, outcome: Collaboration.AgentHostOutcome) throws -> Collaboration.AgentDispatchReceipt {
        guard outcome.phase.isFinal else { throw CollaborationStoreError.invalidRequest }
        return try database.write { db in
            let caller = try authenticate(db, token); _ = try scope(db, caller, area)
            guard let row = try dispatchRow(db, area: area, id: id) else { throw CollaborationStoreError.unavailable }
            let receipt = try dispatchReceipt(row)
            try requireSourceHost(db, caller: caller, source: receipt.command.source)
            guard receipt.command.hostGeneration == outcome.claim.hostGeneration, receipt.claimID == outcome.claim.claimID else { throw CollaborationStoreError.forbidden }
            if receipt.phase.isFinal {
                guard receipt.phase == outcome.phase else { throw SharedArea.Failure.changedIntent }
                return receipt
            }
            guard receipt.phase == .dispatching || (receipt.phase == .claimed && outcome.phase != .accepted) else { throw CollaborationStoreError.forbidden }
            try db.execute(sql: "UPDATE agent_dispatches SET phase=? WHERE area=? AND id=?",
                arguments: [outcome.phase.rawValue, area.uuidString, id.uuidString])
            return .init(command: receipt.command, phase: outcome.phase, claimID: receipt.claimID)
        }
    }

    private func handoffDocument(_ db: Database, area: UUID) throws -> SharedArea.Document {
        guard let data = try Data.fetchOne(db, sql: "SELECT snapshot FROM areas WHERE id=?", arguments: [area.uuidString]) else { throw CollaborationStoreError.unavailable }
        return try unseal(SharedArea.Document.self, data)
    }
    private func agentSource(_ db: Database, area: UUID, object: SharedArea.ID<SharedArea.Object>) throws -> SharedArea.Source {
        guard let item = try handoffDocument(db, area: area).items.first(where: { $0.id == object }),
              item.kind == .agentObservation, let source = item.source else { throw CollaborationStoreError.unavailable }
        return source
    }
    private func requireSourceHost(_ db: Database, caller: Collaboration.Identity, source: SharedArea.Source) throws {
        guard source.owner == caller.person,
              try String.fetchOne(db, sql: "SELECT device FROM hosts WHERE id=?", arguments: [source.host.rawValue.uuidString]) == caller.device.uuidString else { throw CollaborationStoreError.forbidden }
    }
    private func control(_ db: Database, area: UUID, object: SharedArea.ID<SharedArea.Object>) throws -> Collaboration.AgentControlState? {
        guard let data = try Data.fetchOne(db, sql: "SELECT state FROM agent_control WHERE area=? AND object=?", arguments: [area.uuidString, object.rawValue.uuidString]) else { return nil }
        return try unseal(Collaboration.AgentControlState.self, data)
    }
    private func saveControl(_ db: Database, _ state: Collaboration.AgentControlState) throws {
        try db.execute(sql: "INSERT INTO agent_control(area,object,state) VALUES (?,?,?) ON CONFLICT(area,object) DO UPDATE SET state=excluded.state",
            arguments: [state.area.rawValue.uuidString, state.object.rawValue.uuidString, try seal(state)])
    }
    private func handoffDigest<T: Encodable>(_ value: T, object: SharedArea.ID<SharedArea.Object>) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var data = Data(object.rawValue.uuidString.utf8); data.append(try encoder.encode(value))
        return Data(SHA256.hash(data: data))
    }
    private func dispatchRow(_ db: Database, area: UUID, id: UUID) throws -> Row? {
        try Row.fetchOne(db, sql: "SELECT * FROM agent_dispatches WHERE area=? AND id=?", arguments: [area.uuidString, id.uuidString])
    }
    private func dispatchReceipt(_ row: Row) throws -> Collaboration.AgentDispatchReceipt {
        guard let phase = Collaboration.AgentDispatchPhase(rawValue: row["phase"]) else { throw CollaborationStoreError.invalidRequest }
        let claim: String? = row["claim"]
        return .init(command: try unseal(Collaboration.AgentDispatchCommand.self, row["command"]), phase: phase, claimID: claim.flatMap(UUID.init(uuidString:)))
    }
    private func validateDispatchAuthority(_ db: Database, _ command: Collaboration.AgentDispatchCommand) throws {
        guard try Int.fetchOne(db, sql: "SELECT revoked FROM devices WHERE id=? AND person=?", arguments: [command.requester.device.uuidString, command.requester.person.rawValue.uuidString]) == 0 else { throw CollaborationStoreError.forbidden }
        let current = try scope(db, command.requester, command.area.rawValue)
        guard current.role != .viewer, current.epoch == command.epoch else { throw CollaborationStoreError.forbidden }
        let source = try agentSource(db, area: command.area.rawValue, object: command.object)
        guard source == command.source, let state = try control(db, area: command.area.rawValue, object: command.object),
              state.source == source, state.controller == command.requester.person,
              state.epoch == current.epoch, state.revision == command.controlRevision, state.hostGeneration == command.hostGeneration else { throw CollaborationStoreError.forbidden }
        let document = try handoffDocument(db, area: command.area.rawValue)
        guard document.contexts.contains(command.context), document.items.contains(where: { $0.id == command.context.object }),
              document.contexts.last(where: { $0.object == command.context.object })?.id == command.context.id else { throw CollaborationStoreError.forbidden }
    }
}
