import AppKit
import ContinuumRevivedAgentUI

/// `--sidebar-hover-card-overlay-check`: a sidebar row's hover card never draws
/// over Settings. Settings is a scrim and card inside the main window, so the
/// hover card (also a subview of that window) used to be added above it.
///
/// Drives production: the real `AgentInboxView` hover path and the real
/// `SettingsModal.show(in:)`. Order of events matters, so both are covered:
/// an open card when Settings appears, and a hover that begins under Settings.
@MainActor
enum SidebarHoverCardOverlayChecks {
    static func run() throws -> String {
        struct Failure: Error, CustomStringConvertible { let description: String }
        func expect(_ ok: @autoclosure () -> Bool, _ message: String) throws {
            if !ok() { throw Failure(description: "hover card overlay: " + message) }
        }
        for dark in [false, true] {
            let tag = dark ? "dark" : "light"
            let f = try SidebarHelperHoverChecks.fixture(style: "duplex", dark: dark)
            defer { f.close() }
            let inbox = f.inbox
            inbox.hoverCardEnabled = true
            inbox.hoverCardScheduler = { _, work in work(); return {} }
            guard let host = f.window.contentView else { throw Failure(description: "no content view") }
            func cards() -> [NSView] { host.subviews.filter { $0 is InboxHoverCardView } }
            let lead = SidebarHelperHoverChecks.uuid(SidebarHelperHoverChecks.busyLead)
            let other = SidebarHelperHoverChecks.uuid(SidebarHelperHoverChecks.idleLead)

            try expect(inbox.hoverRowForQA(id: lead), "\(tag): the lead row must be hoverable")
            try expect(cards().count == 1, "\(tag): hovering a row must open its card")

            let defaults = UserDefaults(suiteName: f.suite) ?? .standard
            let modal = SettingsModal(model: SettingsModel(
                defaults: defaults, navKeymap: .resolve(defaults: defaults, warn: { _ in }),
                initialPaneID: "general"))
            modal.show(in: f.window)
            defer { modal.close() }
            try expect(host.subviews.last is SettingsOverlayView, "\(tag): Settings must be the top subview")
            try expect(cards().isEmpty, "\(tag): an open card must leave when Settings opens — \(cards().count) left")

            // The pointer is still over the list under the scrim.
            try expect(inbox.hoverRowForQA(id: other), "\(tag): the second row must be hoverable")
            try expect(cards().isEmpty, "\(tag): a hover under Settings must not draw a card")
            try expect(host.subviews.last is SettingsOverlayView, "\(tag): nothing may sit above Settings")

            modal.close()
            _ = inbox.hoverRowForQA(id: nil)
            try expect(inbox.hoverRowForQA(id: lead), "\(tag): hover must work after Settings closes")
            try expect(cards().count == 1, "\(tag): the card must return once Settings is closed")
        }
        return "hover card: leaves when Settings opens, never drawn over it, returns after (light and dark)"
    }
}
