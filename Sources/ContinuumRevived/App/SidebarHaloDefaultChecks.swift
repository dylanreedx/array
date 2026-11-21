import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// `--sidebar-halo-default-check`. With NO `ARRAY_SIDEBAR_LEAD_ICON` set, the
/// production `AgentInboxView` cells must show the Halo (lead icon as the fold
/// control, helper characters in the left column) when agent icons are on, and
/// the classic expander and dots when they are off. Reduce Motion: a static icon.
/// `ARRAY_HALO_STILLS_OUT` additionally writes default-{light,dark}.png.
@MainActor
enum SidebarHaloDefaultChecks {
    typealias Failure = SidebarLeadIconRoundChecks.Failure
    static var leadId: UUID { SidebarLeadIconRoundChecks.id(1) }
    static var helperIds: [UUID] { [11, 12, 13].map { SidebarLeadIconRoundChecks.id($0) } }

    static func run() throws -> String {
        guard ProcessInfo.processInfo.environment["ARRAY_SIDEBAR_LEAD_ICON"] == nil else {
            throw Failure(description: "unset ARRAY_SIDEBAR_LEAD_ICON: this check asserts the default")
        }
        let suite = "ArrayHaloDefault-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AgentCharacterController.shared
        controller.windowIsVisible = { _ in true }
        func configure(enabled: Bool) {
            defaults.set(enabled, forKey: AgentCharacterConfig.enabledKey)
            controller.adopt(defaults: defaults)
            controller.reload()
        }
        var windows: [NSWindow] = []
        defer { windows.forEach { $0.orderOut(nil) } }
        func makeInbox(_ appearance: NSAppearance.Name = .aqua, reduceMotion: Bool = false) -> AgentInboxView {
            controller.reduceMotion = { reduceMotion }
            let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 300, height: 320))
            inbox.clock = { SidebarLeadIconRoundChecks.now }
            inbox.prefersReducedMotion = { reduceMotion }
            inbox.onRowAction = { _, _ in }
            inbox.hoverCardEnabled = false
            let window = NSWindow(contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = inbox
            window.orderFrontOffscreenForChecks()
            windows.append(window)
            let keep = Set([1, 11, 12, 13].map(SidebarLeadIconRoundChecks.id))
            inbox.reload(rows: SidebarLeadIconRoundChecks.rows().filter { keep.contains($0.id) })
            inbox.layoutForQA()
            return inbox
        }
        func cell(_ inbox: AgentInboxView, _ id: UUID) throws -> AgentInbox96CellView {
            guard let c = inbox.cellForQA(id: id) else { throw Failure(description: "no cell for row") }
            return c
        }

        // Icons on, nothing else set: Halo.
        configure(enabled: true)
        let on = makeInbox()
        let lead = try cell(on, leadId)
        guard lead.leadPlateShownForQA else { throw Failure(description: "icons on: lead shows no icon plate (\(lead.leadPlateStateForQA))") }
        guard !lead.foldGlyphVisibleForQA else { throw Failure(description: "icons on: the classic expander still shows beside the icon") }
        for id in helperIds {
            guard try cell(on, id).characterRectForQA != nil else {
                throw Failure(description: "icons on: helper row has no character in its left column")
            }
        }

        // Icons off: the classic expander and dots.
        configure(enabled: false)
        let off = makeInbox()
        let offLead = try cell(off, leadId)
        guard !offLead.leadPlateShownForQA else { throw Failure(description: "icons off: lead still shows the icon plate") }
        guard offLead.foldGlyphVisibleForQA else { throw Failure(description: "icons off: the classic expander is missing") }
        for id in helperIds {
            guard try cell(off, id).characterRectForQA == nil else {
                throw Failure(description: "icons off: a helper row still shows a character")
            }
        }

        // Reduce Motion: folding the lead leaves a static icon, no motion in flight.
        configure(enabled: true)
        let calm = makeInbox(reduceMotion: true)
        guard try cell(calm, leadId).clickDisclosureForQA() else { throw Failure(description: "reduce motion: no lead fold to click") }
        calm.layoutForQA()
        let calmLead = try cell(calm, leadId)
        let plate = calmLead.leadPlateForQA
        guard calmLead.leadPlateShownForQA, plate.animationKeysForQA.isEmpty else {
            throw Failure(description: "reduce motion: icon not static (shown=\(calmLead.leadPlateShownForQA) animations=\(plate.animationKeysForQA))")
        }
        guard plate.haloStrokeEndForQA == (plate.expanded ? 1 : 0) else {
            throw Failure(description: "reduce motion: halo ring not at rest for expanded=\(plate.expanded)")
        }

        // Stills of the default sidebar, light and dark.
        var written: [String] = []
        if let dir = ProcessInfo.processInfo.environment["ARRAY_HALO_STILLS_OUT"], !dir.isEmpty {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for (appearance, tone) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                configure(enabled: true)
                _ = makeInbox(appearance)
                let window = windows.last!
                CATransaction.flush()
                RunLoop.current.run(until: Date().addingTimeInterval(0.6))
                guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                          [.boundsIgnoreFraming, .bestResolution]),
                      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    throw Failure(description: "still capture failed (\(tone))")
                }
                let path = "\(dir)/default-\(tone).png"
                try data.write(to: URL(fileURLWithPath: path))
                written.append(path)
            }
        }
        return "sidebar halo default: icons-on Halo, icons-off expander, reduce-motion static \(written.joined(separator: " "))"
    }
}
