import AppKit
import ContinuumRevivedCore
import SwiftUI

// Row kinds for the Settings cleanup (General, Sidebar, Agent Icons, Canvas,
// Keyboard): a segmented choice, a switch over a three-way stored value, a
// number shown as a slider with its live value, and a toolbar-buttons checklist.
// Every one writes the field's existing key and values; nothing is migrated.

/// An `NSSegmentedControl` the checks can find by identifier and drive with
/// `sendAction`, like the app's other real controls.
struct SettingsSegmentedControl: NSViewRepresentable {
    let ids: [String]
    let titles: [String]
    let selected: String
    let identifier: String
    let label: String
    let onSelect: (String) -> Void

    final class Coordinator: NSObject {
        var ids: [String] = []
        var onSelect: (String) -> Void = { _ in }
        @objc func changed(_ sender: NSSegmentedControl) {
            guard ids.indices.contains(sender.selectedSegment) else { return }
            onSelect(ids[sender.selectedSegment])
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: titles, trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.segmentStyle = .rounded
        control.setAccessibilityIdentifier(identifier)
        control.setAccessibilityLabel(label)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.ids = ids
        context.coordinator.onSelect = onSelect
        if control.segmentCount != titles.count {
            control.segmentCount = titles.count
        }
        for (index, title) in titles.enumerated() where control.label(forSegment: index) != title {
            control.setLabel(title, forSegment: index)
        }
        control.selectedSegment = ids.firstIndex(of: selected) ?? -1
        control.invalidateIntrinsicContentSize()
    }
}

/// A short choice shown side by side, every option visible at once.
struct SegmentedChoiceRow: View {
    let row: SettingsRow
    let model: SettingsModel

    static func identifier(forKey key: String) -> String { "settings.segmented.\(key)" }

    var body: some View {
        if case let .choice(key, label, options, _, _) = row.field {
            let binding = model.binding(for: row.field)
            LabeledContent {
                SettingsSegmentedControl(ids: options, titles: options.map(row.field.displayTitle(forOption:)),
                                         selected: binding.string, identifier: Self.identifier(forKey: key), label: label,
                                         onSelect: { binding.set(.string($0)) })
                    .fixedSize()
            } label: {
                SettingsRowLabel(title: label, help: row.help)
            }
        }
    }
}

/// "Confirm before closing a tile": a switch (off writes `never`), and while on
/// the scope: Terminals and browsers, or Every tile. The stored key and values
/// are the old three-way choice.
struct CloseConfirmRow: View {
    let row: SettingsRow
    let model: SettingsModel

    static let scopeIdentifier = "settings.closeConfirm.scope"

    var body: some View {
        let binding = model.binding(for: row.field)
        let off = binding.string == DeleteConfirmPolicy.never.rawValue
        Group {
            Toggle(isOn: Binding(get: { !off },
                                 set: { binding.set(.string($0 ? DeleteConfirmPolicy.runtimes.rawValue : DeleteConfirmPolicy.never.rawValue)) })) {
                SettingsRowLabel(title: row.field.label, help: row.help)
            }
            .toggleStyle(.switch)
            if !off {
                let scopes = [DeleteConfirmPolicy.runtimes.rawValue, DeleteConfirmPolicy.always.rawValue]
                LabeledContent("Ask for") {
                    SettingsSegmentedControl(ids: scopes, titles: scopes.map(row.field.displayTitle(forOption:)),
                                             selected: binding.string, identifier: Self.scopeIdentifier, label: "Ask for",
                                             onSelect: { binding.set(.string($0)) })
                        .fixedSize()
                }
            }
        }
    }
}

/// "Animate while working": a switch over the stored motion (`working` / `never`).
struct MotionSwitchRow: View {
    let row: SettingsRow
    let model: SettingsModel

    var body: some View {
        let binding = model.binding(for: row.field)
        Toggle(isOn: Binding(get: { binding.string == AgentCharacterConfig.Motion.working.rawValue },
                             set: { binding.set(.string(($0 ? AgentCharacterConfig.Motion.working : .never).rawValue)) })) {
            SettingsRowLabel(title: row.field.label, help: row.help)
        }
        .toggleStyle(.switch)
    }
}

/// A number as a slider with its live value beside it. The stored value is still
/// the field's number; a stored value outside the slider's span (Hold for up to
/// 2000 ms) loads and shows its real value, and is only rewritten when dragged.
struct NumberSliderRow: View {
    let row: SettingsRow
    let model: SettingsModel

    /// Rows drawn as sliders, with the span the track covers when it is narrower
    /// than the stored range. The span's lower bound sits on the row's step grid.
    static let tracks: [String: ClosedRange<Double>?] = [
        FocusBorderConfig.gapKey: nil,
        WorkspaceSidebarConfig.widthKey: 184...640,
        TileGapResolver.userDefaultsKey: nil,
        ZoneBoundsConfig.paddingKey: nil,
        NavKeymap.leaderDwellDefaultsKey: Double(NavKeymap.minimumLeaderDwellMs)...1_000,
    ]

    /// Snapped in code rather than by `Slider(step:)`, which draws a tick for every step.
    static func snapped(_ value: Double, to step: Double, from origin: Double) -> Double {
        guard step > 0 else { return value }
        return origin + ((value - origin) / step).rounded() * step
    }

    var body: some View {
        if case let .number(key, label, range, _, unit, step) = row.field {
            let binding = model.binding(for: row.field)
            let track = Self.tracks[key].flatMap { $0 } ?? range
            let value = binding.double
            LabeledContent {
                HStack(spacing: 10) {
                    Slider(value: Binding(get: { min(track.upperBound, max(track.lowerBound, value)) },
                                          set: { binding.set(.double(Self.snapped($0, to: step, from: track.lowerBound))) }),
                           in: track)
                        .frame(minWidth: 160, maxWidth: 240)
                        .accessibilityIdentifier("settings.slider.\(key)")
                    Text("\(Int(value.rounded())) \(unit)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .trailing)
                }
            } label: {
                SettingsRowLabel(title: label, help: row.help)
            }
        }
    }
}

/// "Toolbar buttons": one checklist on Array's choice popover instead of a switch
/// per button. Each button keeps its own `FloatingToolbarConfig.itemVisibleKey`.
struct ToolbarButtonsRow: View {
    let row: SettingsRow
    let model: SettingsModel

    static let identifier = "settings.toolbarButtons"

    static func buttons() -> [(id: String, title: String, field: SettingsField)] {
        CommandRegistry.definitions().compactMap { definition in
            guard let item = definition.floatingToolbarItem else { return nil }
            let field = SettingsField.toggle(key: FloatingToolbarConfig.itemVisibleKey(commandID: definition.id.rawValue),
                                             label: "Show \(item.title) button", default: FloatingToolbarConfig.defaultItemVisible)
            return (definition.id.rawValue, item.title, field)
        }
    }

    var body: some View {
        let _ = model.revision
        LabeledContent {
            ToolbarButtonsChecklist(model: model)
                .frame(width: 180, height: ChoiceButton.controlHeight)
        } label: {
            SettingsRowLabel(title: row.field.label, help: row.help)
        }
    }
}

private struct ToolbarButtonsChecklist: NSViewRepresentable {
    let model: SettingsModel

    final class Coordinator { var items: [ChoiceItem] = []; var title = "" }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ChoiceButton {
        let button = ChoiceButton(title: "Buttons")
        button.popoverPresentation = .checklist
        button.keepsSelectionForItem = { _ in true }
        button.setAccessibilityLabel("Toolbar buttons")
        button.setAccessibilityIdentifier(ToolbarButtonsRow.identifier)
        return button
    }

    func updateNSView(_ button: ChoiceButton, context: Context) {
        let buttons = ToolbarButtonsRow.buttons()
        let items = buttons.map { entry -> ChoiceItem in
            var item = ChoiceItem(id: entry.id, title: entry.title)
            item.check = model.binding(for: entry.field).bool ? .on : .off
            item.keepsOpen = true
            return item
        }
        let shown = items.filter { $0.check == .on }.count
        let title = "\(shown) of \(items.count) shown"
        button.onSelection = { item in
            guard let entry = ToolbarButtonsRow.buttons().first(where: { $0.id == item.id }) else { return }
            model.write(.bool(!model.binding(for: entry.field).bool), to: entry.field)
        }
        if context.coordinator.items != items {
            context.coordinator.items = items
            button.items = items
            context.coordinator.title = ""
        }
        if context.coordinator.title != title {
            context.coordinator.title = title
            button.setPresentationTitle(title)
        }
    }
}
