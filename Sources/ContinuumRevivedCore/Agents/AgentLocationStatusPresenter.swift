import Foundation

/// Host-local, bounded text for native Home / Where / What surfaces.
///
/// This presentation deliberately remains non-Codable: `detailText` may contain
/// full checkout and activity paths for a local tooltip/disclosure. Compact lines
/// prefer project-relative or short external labels, while explicit booleans let a
/// renderer reserve a non-truncating outbound marker instead of relying on a glyph
/// buried at the tail of an elided string.
public struct AgentLocationStatusPresentation: Equatable, Sendable {
    public let locationText: String
    public let whatText: String
    public let locationAccessibilityValue: String
    public let whatAccessibilityValue: String
    public let detailText: String
    public let homeWhereCollapsed: Bool
    public let whereIsExternal: Bool
    public let whatIsExternal: Bool
}

public enum AgentLocationStatusPresenter {
    private static let maximumCompactTextLength = 240
    private static let maximumDetailComponentLength = 4_096

    public static func present(
        _ snapshot: AgentLocationSnapshot,
        projectName: String? = nil
    ) -> AgentLocationStatusPresentation {
        let homeName = boundedSingleLine(
            projectName,
            fallback: snapshot.home.projectRoot?.lastPathComponent
                ?? snapshot.home.checkoutRoot.lastPathComponent,
            maximumLength: 80)
        let wherePresentation = presentWhere(snapshot.workingLocation, homeName: homeName)
        let whatPresentation = presentWhat(snapshot, homeName: homeName)

        return AgentLocationStatusPresentation(
            locationText: boundedSingleLine(
                wherePresentation.text,
                fallback: "Home \(homeName)",
                maximumLength: maximumCompactTextLength),
            whatText: boundedSingleLine(
                whatPresentation.text,
                fallback: "What No observed activity",
                maximumLength: maximumCompactTextLength),
            locationAccessibilityValue: wherePresentation.accessibility,
            whatAccessibilityValue: whatPresentation.accessibility,
            detailText: detailText(snapshot, homeName: homeName),
            homeWhereCollapsed: snapshot.workingLocation.relationToHome == .root,
            whereIsExternal: snapshot.workingLocation.relationToHome == .outside,
            whatIsExternal: whatPresentation.isExternal)
    }

    private static func presentWhere(
        _ location: AgentWorkingLocation,
        homeName: String
    ) -> (text: String, accessibility: String) {
        switch location.relationToHome {
        case .root:
            return (
                "Home \(homeName)",
                "Home and Where: \(homeName), project root.")
        case .inside:
            let relative = boundedSingleLine(
                location.relativePath,
                fallback: location.directory.lastPathComponent,
                maximumLength: maximumCompactTextLength)
            return (
                "Home \(homeName) · Where \(relative)",
                "Home: \(homeName). Where: \(relative), inside Home.")
        case .outside:
            let external = shortExternalDirectory(location.directory)
            return (
                "Home \(homeName) · Where \(external)",
                "Home: \(homeName). Where: \(external), outside Home.")
        }
    }

    private static func presentWhat(
        _ snapshot: AgentLocationSnapshot,
        homeName: String
    ) -> (text: String, accessibility: String, isExternal: Bool) {
        if let current = snapshot.what {
            let relation = snapshot.whatRelationToHome
            let target = compactTarget(
                current.targetPath,
                relationToHome: relation,
                snapshot: snapshot,
                homeName: homeName)
            let phrase = currentPhrase(current.operation, target: target)
            let spoken = spokenCurrentPhrase(current.operation, target: target)
            return (
                "What \(phrase)",
                "What: \(spoken)\(spokenRelationSuffix(relation))",
                relation == .outside)
        }

        if let recent = snapshot.lastUsefulWhat {
            let relation = snapshot.lastUsefulWhatRelationToHome
            let target = compactTarget(
                recent.targetPath,
                relationToHome: relation,
                snapshot: snapshot,
                homeName: homeName)
            let visual = recentPhrase(recent.operation, target: target)
            let spoken = spokenRecentPhrase(recent.operation, target: target)
            return (
                "Last \(visual)",
                "Last observed activity: \(spoken)\(spokenRelationSuffix(relation))",
                relation == .outside)
        }

        return ("What No observed activity", "What: no observed activity.", false)
    }

    private static func compactTarget(
        _ target: URL?,
        relationToHome: AgentPathRelation?,
        snapshot: AgentLocationSnapshot,
        homeName: String
    ) -> String? {
        guard let target else { return nil }
        switch relationToHome {
        case .root:
            return homeName
        case .inside:
            return AgentPathRelation.relativePath(
                target.standardizedFileURL,
                relativeTo: snapshot.home.checkoutRoot.standardizedFileURL)
                .map { boundedSingleLine($0, fallback: target.lastPathComponent, maximumLength: 180) }
        case .outside:
            let whereRoot = snapshot.workingLocation.directory.standardizedFileURL
            switch AgentPathRelation.classify(target.standardizedFileURL, relativeTo: whereRoot) {
            case .root:
                return shortExternalDirectory(whereRoot)
            case .inside:
                let relative = AgentPathRelation.relativePath(target.standardizedFileURL, relativeTo: whereRoot)
                let base = shortExternalDirectory(whereRoot)
                return relative.map {
                    boundedSingleLine("\(base)/\($0)", fallback: target.lastPathComponent, maximumLength: 180)
                }
            case .outside:
                return shortExternalPath(target)
            }
        case nil:
            return shortExternalPath(target)
        }
    }

    private static func currentPhrase(
        _ operation: AgentObservedActivity.Operation,
        target: String?
    ) -> String {
        joined(currentVerb(operation), target)
    }

    private static func spokenCurrentPhrase(
        _ operation: AgentObservedActivity.Operation,
        target: String?
    ) -> String {
        joined(currentVerb(operation).lowercased(), target)
    }

    private static func recentPhrase(
        _ operation: AgentObservedActivity.Operation,
        target: String?
    ) -> String {
        joined(recentVerb(operation), target)
    }

    private static func spokenRecentPhrase(
        _ operation: AgentObservedActivity.Operation,
        target: String?
    ) -> String {
        joined(recentVerb(operation).lowercased(), target)
    }

    private static func joined(_ verb: String, _ target: String?) -> String {
        guard let target, !target.isEmpty else { return verb }
        return "\(verb) \(target)"
    }

    private static func currentVerb(_ operation: AgentObservedActivity.Operation) -> String {
        switch operation {
        case .reading: return "Reading"
        case .editing: return "Editing"
        case .running: return "Running"
        case .searching: return "Searching"
        case .thinking: return "Thinking"
        case .waiting: return "Waiting"
        case .messaging: return "Messaging"
        case .inspecting: return "Inspecting"
        case .completed: return "Completed"
        case .interrupted: return "Interrupted"
        case .failed: return "Failed"
        }
    }

    private static func recentVerb(_ operation: AgentObservedActivity.Operation) -> String {
        switch operation {
        case .reading: return "Read"
        case .editing: return "Edited"
        case .running: return "Ran"
        case .searching: return "Searched"
        case .thinking: return "Thought"
        case .waiting: return "Waited"
        case .messaging: return "Messaged"
        case .inspecting: return "Inspected"
        case .completed: return "Completed"
        case .interrupted: return "Interrupted"
        case .failed: return "Failed"
        }
    }

    private static func spokenRelationSuffix(_ relation: AgentPathRelation?) -> String {
        switch relation {
        case .root: return ", at Home."
        case .inside: return ", inside Home."
        case .outside: return ", outside Home."
        case nil: return "."
        }
    }

    private static func shortExternalDirectory(_ url: URL) -> String {
        boundedSingleLine(url.lastPathComponent, fallback: "/", maximumLength: 120)
    }

    private static func shortExternalPath(_ url: URL) -> String {
        let components = url.standardizedFileURL.pathComponents.filter { $0 != "/" }
        let tail = components.suffix(2).joined(separator: "/")
        return boundedSingleLine(tail, fallback: url.lastPathComponent, maximumLength: 180)
    }

    private static func detailText(
        _ snapshot: AgentLocationSnapshot,
        homeName: String
    ) -> String {
        var lines = [
            "Home: \(homeName) — \(boundedPath(snapshot.home.checkoutRoot.path))",
            "Where: \(boundedPath(snapshot.workingLocation.directory.path)) (\(relationLabel(snapshot.workingLocation.relationToHome)) Home)",
        ]
        if let projectRoot = snapshot.home.projectRoot,
           projectRoot.standardizedFileURL != snapshot.home.checkoutRoot.standardizedFileURL {
            lines.insert("Project root: \(boundedPath(projectRoot.path))", at: 1)
        }
        if let current = snapshot.what {
            lines.append(detailActivity("What", current, relation: snapshot.whatRelationToHome))
        } else {
            lines.append("What: no current observed activity")
        }
        if let recent = snapshot.lastUsefulWhat, recent != snapshot.what {
            lines.append(detailActivity(
                "Last useful",
                recent,
                relation: snapshot.lastUsefulWhatRelationToHome))
        }
        return lines.joined(separator: "\n")
    }

    private static func detailActivity(
        _ prefix: String,
        _ activity: AgentObservedActivity,
        relation: AgentPathRelation?
    ) -> String {
        let target = activity.targetPath.map { " — \(boundedPath($0.path))" } ?? ""
        let relationDetail = relation.map { ", \(relationLabel($0)) Home" } ?? ""
        return "\(prefix): \(currentVerb(activity.operation).lowercased())\(target) — "
            + "\(evidenceLabel(activity.evidenceSource)), \(timestamp(activity.updatedAt))"
            + relationDetail
    }

    private static func relationLabel(_ relation: AgentPathRelation) -> String {
        switch relation {
        case .root: return "at"
        case .inside: return "inside"
        case .outside: return "outside"
        }
    }

    private static func evidenceLabel(_ source: AgentObservedActivity.EvidenceSource) -> String {
        switch source {
        case .toolEvent: return "tool event"
        case .lifecycleEvent: return "runtime lifecycle"
        case .hostAction: return "host action"
        }
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func boundedPath(_ path: String) -> String {
        boundedSingleLine(path, fallback: "Unavailable", maximumLength: maximumDetailComponentLength)
    }

    private static func boundedSingleLine(
        _ candidate: String?,
        fallback: String,
        maximumLength: Int
    ) -> String {
        let source = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = source?.isEmpty == false ? source! : fallback
        let flattened = chosen.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) ? " " : Character(String(scalar))
        }
        let normalized = String(flattened).split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard normalized.count > maximumLength else { return normalized }
        return String(normalized.prefix(maximumLength - 1)) + "…"
    }
}
