import ContinuumRevivedCore
import SwiftUI

/// A number that can be switched off, in Array's settings pattern: a switch with
/// the plain-words help, and while on, a slider with its live value beside it.
/// The stored value is whatever the resolver already reads (see
/// `SettingsOptionalNumber`), so turning the switch off writes the same 0 or
/// "Off" it always meant. A row with no `off` is just the stepped slider.
struct OptionalNumberRow: View {
    let row: SettingsRow
    let spec: SettingsOptionalNumber
    let model: SettingsModel

    var body: some View {
        let binding = model.binding(for: row.field)
        let stored = model.value(of: row.field) ?? spec.onValue
        let on = spec.isOn(stored)
        let number = spec.number(from: stored)
        Group {
            if spec.off != nil {
                Toggle(isOn: Binding(get: { on },
                                     set: { binding.set($0 ? spec.onValue : (spec.off ?? spec.onValue)) })) {
                    SettingsRowLabel(title: row.field.label, help: row.help)
                }
                .toggleStyle(.switch)
                if on {
                    LabeledContent(spec.sliderLabel) { slider(binding: binding, number: number) }
                }
            } else {
                LabeledContent {
                    slider(binding: binding, number: number)
                } label: {
                    SettingsRowLabel(title: row.field.label, help: row.help)
                }
            }
        }
    }

    private func slider(binding: SettingsBinding, number: Double) -> some View {
        HStack(spacing: 10) {
            if spec.stops.isEmpty {
                Slider(value: Binding(get: { number }, set: { binding.set(spec.storedValue(forNumber: $0)) }),
                       in: spec.range, step: spec.step)
                    .frame(minWidth: 160, maxWidth: 240)
            } else {
                let index = spec.stops.firstIndex(of: number) ?? 0
                Slider(value: Binding(get: { Double(index) },
                                      set: { binding.set(spec.storedValue(forNumber: spec.stops[min(spec.stops.count - 1, max(0, Int($0.rounded())))])) }),
                       in: 0...Double(max(1, spec.stops.count - 1)), step: 1)
                    .frame(minWidth: 160, maxWidth: 240)
            }
            Text(spec.display(number))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
        }
    }
}

/// A stored bool drawn as two side-by-side words (Patient / Quick). The first
/// word is `false`, so the key and its values are exactly what the switch wrote.
struct SegmentedToggleRow: View {
    let row: SettingsRow
    let titles: SettingsToggleTitles
    let model: SettingsModel

    var body: some View {
        let binding = model.binding(for: row.field)
        LabeledContent {
            Picker(selection: Binding(get: { binding.bool }, set: { binding.set(.bool($0)) })) {
                Text(titles.off).tag(false)
                Text(titles.on).tag(true)
            } label: { Text(row.field.label) }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 200)
        } label: {
            SettingsRowLabel(title: row.field.label, help: row.help)
        }
    }
}
