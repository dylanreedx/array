import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationClient

/// Opened deliberately from File > Collaboration. Merely starting Array never
/// reads collaboration credentials, contacts a service or presents this window.
@MainActor
final class CollaborationHubWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let content: CollaborationHubView
    var onClose: (() -> Void)?
    init(model: CollaborationAccountController) {
        content = CollaborationHubView(model: model)
        window = CollaborationWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 720),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Collaboration"
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.delegate = self
        window.center()
    }
    func show() { CollaborationWindow.present(window) }
    func windowWillClose(_ notification: Notification) { content.stop(); onClose?() }
}

@MainActor
final class CollaborationHubView: NSView, TokenThemed {
    let model: CollaborationAccountController
    var onOpenArea: ((SharedAreaController, SharedArea.ID<SharedArea.Person>, UUID) -> Void)?
    private let title = NSTextField(labelWithString: "Work together in a shared workspace")
    private let subtitle = NSTextField(wrappingLabelWithString: "Share context and discussion while keeping your own checkout and agents.")
    private let accountLabel = NSTextField(labelWithString: "Account")
    private let accountChoice = ChoiceButton(title: "Choose an account")
    private let endpoint = NSTextField()
    private let enrollment = NSSecureTextField()
    private let device = NSTextField()
    private let connect = ComposerActionButton(presentation: CollaborationHubView.action("Connect", symbol: "person.badge.key"))
    private let identity = NSTextField(labelWithString: "")
    private let workspaceLabel = NSTextField(labelWithString: "Shared workspace")
    private let workspaceAction = ChoiceButton(title: "Create a workspace")
    private let workspaceValue = NSTextField()
    private let workspaceName = NSTextField()
    private let open = ComposerActionButton(presentation: CollaborationHubView.action("Create workspace", symbol: "plus"))
    private let knownAreas = ChoiceButton(title: "Recent shared workspaces")
    private let inviteLabel = NSTextField(labelWithString: "Invite to the open shared workspace")
    private let invitePerson = NSTextField()
    private let inviteRole = ChoiceButton(title: "Editor")
    private let invite = ComposerActionButton(presentation: CollaborationHubView.action("Create invitation", symbol: "person.badge.plus"))
    private let invitation = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "Connect using your Array collaboration enrollment. Provider CLI login stays with your agents.")
    private var currentArea: UUID?
    private var currentAreaRole: Collaboration.Role?
    private var busy = false
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(model: CollaborationAccountController) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 680, height: 720))
        wantsLayer = true
        for view in [title, subtitle, accountLabel, accountChoice, endpoint, enrollment, device, connect, identity,
                     workspaceLabel, workspaceAction, workspaceValue, workspaceName, open, knownAreas,
                     inviteLabel, invitePerson, inviteRole, invite, invitation, status] { addSubview(view) }
        title.font = .token(.title)
        for label in [subtitle, identity, invitation, status] { label.font = .token(.body); label.isSelectable = true }
        status.setAccessibilityLabel("Collaboration status")
        for label in [accountLabel, workspaceLabel, inviteLabel] { label.font = .token(.label) }
        configure(endpoint, placeholder: "Collaboration service URL (https://…)", accessibility: "Collaboration service URL")
        configure(enrollment, placeholder: "One-time Array enrollment code", accessibility: "One-time Array enrollment code")
        configure(device, placeholder: "Device name", accessibility: "Device name"); device.stringValue = "This Mac"
        configure(workspaceValue, placeholder: "Invitation code", accessibility: "Workspace ID or invitation code")
        configure(workspaceName, placeholder: "Workspace name on this Mac", accessibility: "Local workspace name"); workspaceName.stringValue = "Shared workspace"
        configure(invitePerson, placeholder: "Teammate's collaboration ID", accessibility: "Teammate collaboration ID")
        workspaceAction.items = [ChoiceItem(id: "create", title: "Create a workspace"), ChoiceItem(id: "join", title: "Join with an invitation"), ChoiceItem(id: "open", title: "Open a workspace by ID")]
        workspaceAction.onSelection = { [weak self] _ in self?.refresh() }
        accountChoice.onSelection = { [weak self] item in
            guard let self else { return }
            if model.activeAccount?.id != item.id { model.signOut(); setOpenArea(nil) }
            refresh()
        }
        inviteRole.items = [ChoiceItem(id: "editor", title: "Editor", detail: "Discuss and arrange shared work"), ChoiceItem(id: "viewer", title: "Viewer", detail: "Read shared work")]
        knownAreas.onSelection = { [weak self] item in
            guard let self, item.id != "none" else { return }
            workspaceAction.selectedID = "open"; workspaceValue.stringValue = item.id; refresh()
        }
        connect.target = self; connect.action = #selector(connectAccount)
        open.target = self; open.action = #selector(openWorkspace)
        invite.target = self; invite.action = #selector(createInvitation)
        model.onChange = { [weak self] in self?.refreshAccounts(); self?.refresh() }
        refreshAccounts(); refresh(); applyTokens()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var isFlipped: Bool { true }

    private func configure(_ field: NSTextField, placeholder: String, accessibility: String) {
        field.placeholderString = placeholder; field.font = .token(.body)
        field.isBezeled = false; field.focusRingType = .none
        field.setAccessibilityLabel(accessibility)
    }
    static func action(_ title: String, symbol: String, enabled: Bool = true, loading: Bool = false) -> AgentComposerPresentation {
        .init(primaryAction: .send, title: title, symbolName: symbol, accessibilityLabel: title,
              isEnabled: enabled, isLoading: loading, secondaryActions: [])
    }
    @discardableResult
    func stop() -> Task<Void, Never>? {
        let previous = task
        generation = UUID(); task?.cancel(); task = nil; busy = false
        model.signOut(); model.onChange = nil
        return previous
    }
    func setOpenArea(_ area: UUID?, role: Collaboration.Role? = nil) {
        currentArea = area; currentAreaRole = role; invitation.stringValue = ""; refresh()
    }
    private func refreshAccounts() {
        let selected = accountChoice.selectedID
        var items = model.accounts.map { ChoiceItem(id: $0.id, title: $0.label, detail: $0.endpoint) }
        if let retained = model.pendingAccount { items.append(ChoiceItem(id: "recover", title: "Finish saved connection: \(retained.label)", detail: retained.endpoint)) }
        accountChoice.items = items + [ChoiceItem(id: "new", title: "Connect another account…")]
        if let selected, accountChoice.items.contains(where: { $0.id == selected }) { accountChoice.selectedID = selected }
        if let active = model.activeAccount {
            identity.stringValue = "Your collaboration ID: \(active.identity.person.rawValue.uuidString)"
            knownAreas.items = active.knownAreas.map { ChoiceItem(id: $0.id.uuidString, title: $0.label) }
            if knownAreas.items.isEmpty { knownAreas.items = [ChoiceItem(id: "none", title: "No recent shared workspaces", enabled: false)] }
        } else { identity.stringValue = ""; knownAreas.items = [] }
    }
    private func refresh() {
        let isNew = accountChoice.selectedID == "new"
        endpoint.isHidden = !isNew; enrollment.isHidden = !isNew; device.isHidden = !isNew
        let connected = model.activeAccount != nil
        for view in [workspaceAction, workspaceName, workspaceValue, open, knownAreas] { view.isHidden = !connected }
        let mode = workspaceAction.selectedID ?? "create"
        workspaceValue.isHidden = !connected || mode == "create"
        workspaceValue.placeholderString = mode == "join" ? "Invitation code" : "Shared workspace ID"
        connect.presentation = Self.action(accountChoice.selectedID == "recover" ? "Save connection" : isNew ? "Connect" : "Use account", symbol: "person.badge.key", enabled: !busy, loading: busy)
        open.presentation = Self.action(mode == "create" ? "Create workspace" : mode == "join" ? "Join workspace" : "Open workspace", symbol: mode == "create" ? "plus" : "arrow.up.right", enabled: connected && !busy)
        let mayInvite = connected && currentArea != nil && currentAreaRole == .owner
        for view in [inviteLabel, invitePerson, inviteRole, invite, invitation] { view.isHidden = !mayInvite }
        invite.presentation = Self.action("Create invitation", symbol: "person.badge.plus", enabled: mayInvite && !busy)
        for control in [accountChoice, workspaceAction, knownAreas, inviteRole] { control.isEnabled = !busy }
        for field in [endpoint, enrollment, device, workspaceValue, workspaceName, invitePerson] { field.isEnabled = !busy }
        needsLayout = true
    }
    private func perform(progress: String = "Connecting…", _ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; status.stringValue = progress; refresh()
        let current = generation
        task = Task { [weak self] in
            do {
                try await work()
                guard let self, generation == current else { return }
                busy = false; task = nil; refreshAccounts(); refresh()
            } catch {
                guard let self, generation == current else { return }
                busy = false; task = nil
                if model.pendingAccount != nil, let failure = error as? CollaborationAccountFailure,
                   failure == .credentialRetainedMetadataFailure || failure == .credentialRetainedVerificationFailure {
                    enrollment.stringValue = ""
                    refreshAccounts(); accountChoice.selectedID = "recover"
                }
                if let failure = error as? CollaborationAccountFailure {
                    switch failure {
                    case .areaRetainedMetadataFailure(let area), .invitationAcceptedStateUnavailable(let area):
                        setOpenArea(nil)
                        workspaceAction.selectedID = "open"; workspaceValue.stringValue = area.uuidString
                    default: break
                    }
                }
                status.stringValue = Self.message(error)
                refreshAccounts(); refresh()
            }
        }
    }
    @objc private func connectAccount() {
        let selection = accountChoice.selectedID
        let address = endpoint.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = enrollment.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceLabel = device.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        perform { [weak self] in
            guard let self else { return }
            let account: CollaborationLocalAccount
            if selection == "recover" {
                let retained = try model.rememberRetainedCredential()
                account = try await model.select(accountID: retained.id)
            } else if selection == "new" {
                guard let url = URL(string: address) else { throw CollaborationCredentialStoreError.invalidEndpoint }
                let service = try CollaborationServiceEndpoint(url)
                account = try await model.enroll(endpoint: service, code: code, deviceLabel: deviceLabel, accountLabel: deviceLabel)
                enrollment.stringValue = ""
            } else if let selection { account = try await model.select(accountID: selection) }
            else { throw CollaborationAccountFailure.accountMissing }
            accountChoice.selectedID = account.id
            setOpenArea(nil); status.stringValue = "Connected. Create a shared workspace or join an invitation."
        }
    }
    func focusAccount(_ accountID: String, area: UUID) {
        guard !busy else {
            setOpenArea(nil); status.stringValue = "Finish the current action, then choose Invite collaborator again."
            return
        }
        perform(progress: "Loading workspace…") { [weak self] in
            guard let self else { return }
            if model.activeAccount?.id != accountID { _ = try await model.select(accountID: accountID) }
            let state = try await model.openArea(id: area)
            accountChoice.selectedID = accountID; setOpenArea(area, role: state.scope.role)
            status.stringValue = "Create an invitation using your teammate's collaboration ID."
        }
    }
    @objc private func openWorkspace() {
        let mode = workspaceAction.selectedID ?? "create"
        let value = workspaceValue.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = workspaceName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        perform(progress: mode == "create" ? "Creating workspace…" : mode == "join" ? "Joining workspace…" : "Opening workspace…") { [weak self] in
            guard let self else { return }
            let state: Collaboration.State
            switch mode {
            case "create": state = try await model.createArea(label: name.isEmpty ? "Shared workspace" : name)
            case "join": state = try await model.acceptInvitation(code: value, label: name.isEmpty ? "Shared workspace" : name)
            default:
                guard let id = UUID(uuidString: value) else { throw CollaborationCredentialStoreError.scopeMismatch }
                state = try await model.openArea(id: id, label: name.isEmpty ? nil : name)
            }
            guard let account = model.activeAccount else { return }
            let area = state.document.id.rawValue
            let controller = try model.makeSharedAreaController(area: area)
            setOpenArea(area, role: state.scope.role)
            status.stringValue = "Opened shared workspace \(area.uuidString). Code changes stay in each owner's checkout."
            onOpenArea?(controller, account.identity.person, area)
        }
    }
    @objc private func createInvitation() {
        guard let area = currentArea, let accountID = model.activeAccount?.id else { return }
        let target = invitePerson.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let role: Collaboration.Role = inviteRole.selectedID == "viewer" ? .viewer : .editor
        perform(progress: "Creating invitation…") { [weak self] in
            guard let self else { return }
            guard let person = UUID(uuidString: target) else { throw CollaborationCredentialStoreError.scopeMismatch }
            let result = try await model.invite(area: area, person: .init(person), role: role)
            guard currentArea == area, model.activeAccount?.id == accountID else {
                status.stringValue = "Ready. The previous invitation is hidden because the workspace changed."
                return
            }
            invitation.stringValue = "Invitation: \(result.code)\nExpires \(result.expiresAt.formatted(date: .abbreviated, time: .shortened)). Share this code with the selected teammate."
            status.stringValue = "Invitation created for the selected collaboration ID."
        }
    }
    private static func message(_ error: any Error) -> String {
        if let account = error as? CollaborationAccountFailure { return account.localizedDescription }
        if error is CollaborationCredentialStoreError { return "Check the service URL, account, workspace ID or teammate ID and try again." }
        if let client = error as? CollaborationClientError, case let .server(status, _) = client {
            switch status {
            case 401: return "This device is no longer signed in. Request a new Array device enrollment code."
            case 403: return "Your account does not have permission for this action."
            case 404: return "This shared workspace is unavailable to your account."
            case 410: return "This invitation or enrollment code has expired or was already used."
            default: break
            }
        }
        return "Collaboration could not finish this action. Your local work is preserved. Check your connection and access, then retry."
    }
    override func layout() {
        super.layout()
        let x = CGFloat(Space.xl), width = bounds.width - 2 * x
        func place(_ view: NSView, y: CGFloat, h: CGFloat = 32, left: CGFloat = 0, w: CGFloat? = nil) {
            let rect = NSRect(x: x + left, y: y, width: w ?? width, height: h)
            if view.frame != rect { view.frame = rect }
        }
        place(title, y: 24, h: 30); place(subtitle, y: 60, h: 44)
        place(accountLabel, y: 114, h: 20); place(accountChoice, y: 140, w: width - 150); place(connect, y: 140, left: width - 140, w: 140)
        place(endpoint, y: 184); place(enrollment, y: 226, w: width - 190); place(device, y: 226, left: width - 180, w: 180)
        place(identity, y: 268, h: 22)
        place(workspaceLabel, y: 308, h: 20); place(workspaceAction, y: 334, w: width - 190); place(open, y: 334, left: width - 180, w: 180)
        place(workspaceName, y: 376, w: width * 0.42); place(workspaceValue, y: 376, left: width * 0.44, w: width * 0.56)
        place(knownAreas, y: 418)
        place(inviteLabel, y: 468, h: 20); place(invitePerson, y: 494, w: width - 290); place(inviteRole, y: 494, left: width - 280, w: 100); place(invite, y: 494, left: width - 170, w: 170)
        place(invitation, y: 536, h: 70); place(status, y: 626, h: 70)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyTokens() }
    func applyTokens() {
        layer?.backgroundColor = SurfaceToken.panel.color.cgColor(in: self)
        for label in [title, accountLabel, workspaceLabel, inviteLabel] { label.textColor = TextToken.textPrimary.color.nsColor(in: self) }
        for label in [subtitle, identity, invitation, status] { label.textColor = TextToken.textSecondary.color.nsColor(in: self) }
        for field in [endpoint, enrollment, device, workspaceValue, workspaceName, invitePerson] {
            field.textColor = TextToken.textPrimary.color.nsColor(in: self)
            field.backgroundColor = SurfaceToken.overlay.color.nsColor(in: self)
        }
    }
}
