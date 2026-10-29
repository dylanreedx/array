import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import SwiftUI

// The Settings row kit: system font, label (and an optional secondary line) on
// the left, the control on the right, inside a grouped Form. Every row carries
// its registry anchor (`settingsAnchor`), which gives it an accessibility
// identifier, a scroll target, the search highlight, and a census entry.

extension View {
    /// Keep `style` on the app's corner style (Settings › Appearance › Corner
    /// style), so a SwiftUI shape drawn from it re-renders live.
    func onCornerStyleChange(_ style: Binding<CornerStyle>) -> some View {
        onReceive(NotificationCenter.default.publisher(for: CornerStyleController.didChangeNotification)) { _ in
            style.wrappedValue = CornerStyle.current
        }
    }
}

extension CornerStyle {
    /// The radius this style draws for a Default radius of `base`.
    func cgRadius(_ base: Double) -> CGFloat { CGFloat(radius(base)) }
}

/// Frames of anchored rows, in the pane's coordinate space.
struct SettingsAnchorFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

enum SettingsCoordinateSpace {
    static let pane = "ArraySettingsPane"
}

private struct SettingsPaneKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    /// The pane a row is drawn in, for the census.
    var settingsPaneID: String {
        get { self[SettingsPaneKey.self] }
        set { self[SettingsPaneKey.self] = newValue }
    }
}

private struct SettingsAnchorModifier: ViewModifier {
    let anchor: String
    let model: SettingsModel
    @State private var cornerStyle = CornerStyle.current
    @Environment(\.settingsPaneID) private var paneID

    func body(content: Content) -> some View {
        let highlighted = model.highlightedEntryID == anchor
        content
            .id(anchor)
            .accessibilityIdentifier(anchor)
            .background(
                RoundedRectangle(cornerRadius: cornerStyle.cgRadius(6), style: .continuous)
                    .fill(Color.accentColor.opacity(highlighted ? 0.22 : 0))
                    .padding(-6)
                    .onCornerStyleChange($cornerStyle)
                    .animation(.easeOut(duration: highlighted ? 0.15 : 0.6), value: highlighted)
            )
            .background(GeometryReader { proxy in
                Color.clear.preference(
                    key: SettingsAnchorFrameKey.self,
                    value: [anchor: proxy.frame(in: .named(SettingsCoordinateSpace.pane))])
            })
            .onAppear { model.noteAppeared(anchor, pane: paneID) }
            .onDisappear { model.noteDisappeared(anchor, pane: paneID) }
    }
}

/// A row's scroll target, accessibility identifier and frame, WITHOUT a census
/// entry: for rows that come and go with the state of their section (an image's
/// opacity, a custom colour), which search reaches through their section's
/// always-present row instead.
private struct SettingsFrameModifier: ViewModifier {
    let anchor: String

    func body(content: Content) -> some View {
        content
            .id(anchor)
            .accessibilityIdentifier(anchor)
            .background(GeometryReader { proxy in
                Color.clear.preference(
                    key: SettingsAnchorFrameKey.self,
                    value: [anchor: proxy.frame(in: .named(SettingsCoordinateSpace.pane))])
            })
    }
}

extension View {
    func settingsAnchor(_ anchor: String, model: SettingsModel) -> some View {
        modifier(SettingsAnchorModifier(anchor: anchor, model: model))
    }

    func settingsFrame(_ anchor: String) -> some View {
        modifier(SettingsFrameModifier(anchor: anchor))
    }

    /// A state-dependent element: its frame and identifier as `settingsFrame`,
    /// plus the exact words it rendered in `SettingsModel.renderedTexts`.
    func settingsRenderedText(_ id: String, _ text: String, model: SettingsModel) -> some View {
        settingsFrame(id)
            .onChange(of: text, initial: true) { _, rendered in model.noteRenderedText(id, rendered) }
            .onDisappear { model.noteRenderedText(id, nil) }
    }
}

/// The left half of every row.
struct SettingsRowLabel: View {
    let title: String
    let help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let help {
                Text(help)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// "Reset to Default" on every keyed row, replacing the old per-row status line.
private struct SettingsResetMenu: ViewModifier {
    let field: SettingsField
    let model: SettingsModel

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Reset to Default") { model.reset(field) }
                .disabled(!model.isModified(field))
        }
    }
}

extension View {
    func settingsResettable(_ field: SettingsField, model: SettingsModel) -> some View {
        modifier(SettingsResetMenu(field: field, model: model))
    }
}

struct ToggleRow: View {
    let row: SettingsRow
    let model: SettingsModel

    var body: some View {
        let binding = model.binding(for: row.field)
        Toggle(isOn: Binding(get: { binding.bool }, set: { binding.set(.bool($0)) })) {
            SettingsRowLabel(title: row.field.label, help: row.help)
        }
        .toggleStyle(.switch)
    }
}

struct PickerRow: View {
    let row: SettingsRow
    let model: SettingsModel
    /// A short, ordered set of looks (Corner style's Sharp / Default / Rounded)
    /// reads as a segmented control rather than a menu.
    var segmented = false

    var body: some View {
        if case let .choice(_, label, options, _, _) = row.field {
            let binding = model.binding(for: row.field)
            let picker = Picker(selection: Binding(get: { binding.string }, set: { binding.set(.string($0)) })) {
                ForEach(options, id: \.self) { option in
                    Text(row.field.displayTitle(forOption: option)).tag(option)
                }
            } label: {
                SettingsRowLabel(title: label, help: row.help)
            }
            if segmented {
                picker.pickerStyle(.segmented)
            } else {
                picker.pickerStyle(.menu)
            }
        }
    }
}

struct SliderRow: View {
    let row: SettingsRow
    let model: SettingsModel

    var body: some View {
        if case let .slider(_, label, range, _, _, format) = row.field {
            let binding = model.binding(for: row.field)
            LabeledContent {
                HStack(spacing: 10) {
                    Slider(value: Binding(get: { binding.double }, set: { binding.set(.double($0)) }), in: range)
                        .frame(minWidth: 160, maxWidth: 240)
                    Text(format.string(for: binding.double))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }
            } label: {
                SettingsRowLabel(title: label, help: row.help)
            }
        }
    }
}

struct NumberRow: View {
    let row: SettingsRow
    let model: SettingsModel
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var spec: (label: String, range: ClosedRange<Double>, unit: String, step: Double)? {
        if case let .number(_, label, range, _, unit, step) = row.field { return (label, range, unit, step) }
        return nil
    }

    private func text(for value: Double) -> String {
        if value == 0, let zero = row.zeroTitle { return zero }
        guard let spec else { return "" }
        return spec.step < 1 ? String(format: "%.2f", value).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
            : String(Int(value.rounded()))
    }

    private func commit() {
        model.pendingEdits[row.field.key ?? row.field.label] = nil
        let binding = model.binding(for: row.field)
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if let zero = row.zeroTitle, trimmed.caseInsensitiveCompare(zero) == .orderedSame || trimmed.isEmpty {
            binding.set(.double(0))
        } else if let number = Double(trimmed) {
            binding.set(.double(number))
        }
        draft = text(for: model.binding(for: row.field).double)
    }

    var body: some View {
        if let spec {
            let binding = model.binding(for: row.field)
            LabeledContent {
                HStack(spacing: 6) {
                    TextField("", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 76)
                        .focused($focused)
                        .onSubmit(commit)
                        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                        .onChange(of: draft) { _, value in
                            // Not gated on focus: an AppKit-driven responder change
                            // never reaches FocusState, and the edit must survive.
                            if value != text(for: model.binding(for: row.field).double) {
                                model.pendingEdits[row.field.key ?? row.field.label] = commit
                            }
                        }
                    Stepper("", value: Binding(get: { binding.double }, set: {
                        binding.set(.double($0))
                        draft = text(for: model.binding(for: row.field).double)
                    }), in: spec.range, step: spec.step)
                    .labelsHidden()
                    if !(binding.double == 0 && row.zeroTitle != nil) {
                        Text(spec.unit).foregroundStyle(.secondary)
                    }
                }
            } label: {
                SettingsRowLabel(title: spec.label, help: row.help)
            }
            .onAppear { draft = text(for: binding.double) }
            .onChange(of: model.revision) { _, _ in if !focused { draft = text(for: model.binding(for: row.field).double) } }
        }
    }
}

struct TextRow: View {
    let row: SettingsRow
    let model: SettingsModel
    /// URL rows validate inline and persist only a complete URL.
    var validatesURL = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var isValid: Bool { !validatesURL || URL(string: draft)?.scheme != nil }

    private func commit() {
        model.pendingEdits[row.field.key ?? row.field.label] = nil
        guard isValid, draft != model.binding(for: row.field).string else { return }
        model.binding(for: row.field).set(.string(draft))
    }

    var body: some View {
        let binding = model.binding(for: row.field)
        LabeledContent {
            VStack(alignment: .trailing, spacing: 4) {
                TextField("", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180, maxWidth: 280)
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                    .onChange(of: draft) { _, value in
                        if value != model.binding(for: row.field).string {
                            model.pendingEdits[row.field.key ?? row.field.label] = commit
                        }
                    }
                if !isValid {
                    Text("Enter a complete address, including https://")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
        } label: {
            SettingsRowLabel(title: row.field.label, help: row.help)
        }
        .onAppear { draft = binding.string }
        .onChange(of: model.revision) { _, _ in if !focused { draft = model.binding(for: row.field).string } }
    }
}

struct PathRow: View {
    let row: SettingsRow
    let model: SettingsModel

    var body: some View {
        let binding = model.binding(for: row.field)
        LabeledContent {
            HStack {
                Text(binding.string.isEmpty ? "Not selected" : binding.string)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Button("Choose…") {
                    let picker = NSOpenPanel()
                    picker.canChooseFiles = false
                    picker.canChooseDirectories = true
                    picker.canCreateDirectories = true
                    guard picker.runModal() == .OK, let url = picker.url else { return }
                    binding.set(.string(url.path))
                }
            }
        } label: {
            SettingsRowLabel(title: row.field.label, help: row.help)
        }
    }
}

struct ButtonRow: View {
    let title: String
    let buttonTitle: String
    var help: String?
    var enabled = true
    let action: () -> Void

    var body: some View {
        LabeledContent {
            Button(buttonTitle, action: action).disabled(!enabled)
        } label: {
            SettingsRowLabel(title: title, help: help)
        }
    }
}

/// A status badge (SF Symbol + words) and an optional action.
struct StatusRow: View {
    enum Tone { case good, warning, neutral }
    let title: String
    let status: String
    let symbol: String
    let tone: Tone
    var detail: String?
    var actionTitle: String?
    var action: (() -> Void)?

    private var tint: Color {
        switch tone {
        case .good: return .green
        case .warning: return .orange
        case .neutral: return .secondary
        }
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                Label(status, systemImage: symbol)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(tint)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                }
            }
        } label: {
            SettingsRowLabel(title: title, help: detail)
        }
    }
}

struct InfoRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// An AppKit view embedded in a Form row, sized to its fitting size.
struct EmbeddedAppKitView: NSViewRepresentable {
    let make: () -> NSView

    func makeNSView(context: Context) -> NSView { make() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        let fitting = nsView.fittingSize
        let width = proposal.width ?? max(fitting.width, nsView.frame.width)
        let height = fitting.height > 0 ? fitting.height : nsView.frame.height
        return CGSize(width: width, height: height)
    }
}


/// Compact native theme cards, using the same semantic surfaces as the app.
struct NeutralThemePickerRow: View {
    let model: SettingsModel
    let row: SettingsRow

    var body: some View {
        let binding = model.binding(for: row.field)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
            ForEach(AppTheme.allCases, id: \.self) { theme in
                Button { binding.set(.string(theme.rawValue)) } label: {
                    ThemePreviewCard(theme: theme, selected: binding.string == theme.rawValue)
                        .environment(\.colorScheme, theme.appearance == .dark ? .dark : .light)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(theme.title), \(theme.appearance.rawValue) theme")
                .accessibilityAddTraits(binding.string == theme.rawValue ? .isSelected : [])
                .accessibilityIdentifier("ArraySettingsTheme.\(theme.rawValue)")
            }
        }
        .padding(.vertical, 4)
    }
}

struct ThemePreviewCard: View {
    let theme: AppTheme
    let selected: Bool
    @State private var cornerStyle = CornerStyle.current

    private func surface(_ token: SurfaceToken) -> Color {
        Color(nsColor: token.color(for: theme).nsColor(for: theme.appearance))
    }

    private var foreground: Color {
        Color(nsColor: TextToken.textPrimary.color.nsColor(for: theme.appearance))
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            surface(.tileBody)
            GeometryReader { geometry in
                VStack(alignment: .leading, spacing: 8) {
                    Rectangle().fill(surface(.tileChrome)).frame(width: geometry.size.width * 0.62, height: 11)
                    Rectangle().fill(foreground.opacity(0.035)).frame(width: geometry.size.width * 0.23, height: 3)
                    Rectangle().fill(foreground.opacity(0.035)).frame(width: geometry.size.width * 0.47, height: 3)
                    Rectangle().fill(surface(.tileChrome)).frame(width: geometry.size.width * 0.74, height: 12).padding(.top, 6)
                    Rectangle().fill(surface(.cardMessage)).frame(width: geometry.size.width * 0.82, height: 13)
                }
                .padding(.horizontal, 20)
                .padding(.top, 22)
            }
            LinearGradient(colors: [surface(.tileBody).opacity(0), surface(.tileBody)], startPoint: .top, endPoint: .bottom)
                .frame(height: 94)
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    ThemeCardTitle(theme: theme).fixedSize()
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 13))
                    }
                }
                HStack(spacing: -3) {
                    ForEach([SurfaceToken.canvas, .panel, .tileChrome, .cardMessage, .overlay], id: \.self) { token in
                        Circle().fill(surface(token))
                            .overlay(Circle().stroke(foreground.opacity(0.5), lineWidth: 0.5))
                            .frame(width: 11, height: 11)
                    }
                }
                .accessibilityHidden(true)
            }
            .foregroundStyle(foreground)
            .padding(16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: cornerStyle.cgRadius(12), style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: cornerStyle.cgRadius(12), style: .continuous))
        .onCornerStyleChange($cornerStyle)
    }
}


/// Native label keeps its intrinsic width through AppKit appearance flips inside
/// the mixed light/dark preview grid. The parent button owns accessibility.
private struct ThemeCardTitle: NSViewRepresentable {
    let theme: AppTheme

    func makeNSView(context: Context) -> NSTextField {
        let label = NSTextField(labelWithString: theme.title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setAccessibilityElement(false)
        return label
    }

    func updateNSView(_ label: NSTextField, context: Context) {
        label.stringValue = theme.title
        label.appearance = NSAppearance(named: theme.appearance == .dark ? .darkAqua : .aqua)
        label.textColor = TextToken.textPrimary.color.nsColor(for: theme.appearance)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}
