import AppKit
import ContinuumRevivedCore
import SwiftUI

/// The card's content: the sidebar (search field on top, panes or results) and
/// the selected pane.
struct SettingsRootView: View {
    let model: SettingsModel

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(model: model)
                .frame(width: 224)
            Divider()
            SettingsDetail(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    let model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            SettingsSearchField(model: model)
                .frame(height: 28)
                .padding(.horizontal, 12)
                .padding(.top, 16)
                .padding(.bottom, 10)
            if model.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                SettingsPaneList(model: model)
            } else {
                SettingsResultsList(model: model)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.55))
    }
}

private struct SettingsPaneList: View {
    let model: SettingsModel

    /// Consecutive panes that share a sidebar heading, so the heading draws once.
    private var runs: [(heading: String?, panes: [SettingsSection])] {
        var result: [(String?, [SettingsSection])] = []
        for pane in model.visiblePanes {
            if let last = result.last, last.0 == pane.sidebarHeading {
                result[result.count - 1].1.append(pane)
            } else {
                result.append((pane.sidebarHeading, [pane]))
            }
        }
        return result
    }

    var body: some View {
        // Drawn rows rather than a source-list `List`: the source-list selection is
        // a visual-effect material, which renders as a black bar in every capture
        // (`cacheDisplay`) the witnesses and the UI tour take.
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(runs.enumerated()), id: \.offset) { index, run in
                    if let heading = run.heading {
                        Text(heading)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.top, index == 0 ? 0 : 12)
                            .padding(.bottom, 3)
                    } else if index > 0 {
                        Spacer().frame(height: 12)
                    }
                    ForEach(run.panes, id: \.id) { pane in
                        paneRow(pane)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
    }

    private func paneRow(_ pane: SettingsSection) -> some View {
        let selected = pane.id == model.selectedPaneID
        return Button {
            model.selectPane(pane.id)
        } label: {
            Label(pane.title, systemImage: pane.iconSystemName ?? "gearshape")
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.accentColor : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ArraySettingsPane.\(pane.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SettingsResultsList: View {
    let model: SettingsModel

    var body: some View {
        let groups = model.groupedResults
        if groups.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text("No settings match “\(model.searchQuery)”")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .accessibilityIdentifier("ArraySettingsSearchEmpty")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(groups, id: \.paneID) { group in
                            Text(group.paneTitle)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.top, 10)
                                .padding(.bottom, 2)
                            ForEach(group.results, id: \.entry.id) { result in
                                resultRow(result)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
                .onChange(of: model.selectedResultIndex) { _, index in
                    guard let index, model.searchResults.indices.contains(index) else { return }
                    proxy.scrollTo(model.searchResults[index].entry.id)
                }
            }
        }
    }

    private func resultRow(_ result: SettingsSearch.Result) -> some View {
        let index = model.searchResults.firstIndex { $0.entry.id == result.entry.id }
        let selected = index != nil && index == model.selectedResultIndex
        return Button {
            model.reveal(result.entry)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(result.entry.label)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                if let group = result.entry.groupTitle, group != result.entry.label {
                    Text(group)
                        .font(.caption)
                        .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(result.entry.id)
        .accessibilityIdentifier("ArraySettingsResult.\(result.entry.id)")
    }
}

/// The real search field: an `NSSearchField`, so ⌘F and the witnesses can make it
/// first responder, and every keystroke lands in `SettingsModel.searchQuery`.
struct SettingsSearchField: NSViewRepresentable {
    static let identifier = "ArraySettingsSearch"
    let model: SettingsModel

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let model: SettingsModel
        var focusToken = 0
        init(model: SettingsModel) { self.model = model }

        @MainActor func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            model.searchQuery = field.stringValue
        }

        @MainActor @objc func searchChanged(_ sender: NSSearchField) {
            model.searchQuery = sender.stringValue
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search"
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        field.sendsSearchStringImmediately = true
        field.setAccessibilityIdentifier(Self.identifier)
        field.setAccessibilityLabel("Search settings")
        context.coordinator.focusToken = model.searchFocusToken
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != model.searchQuery { field.stringValue = model.searchQuery }
        if context.coordinator.focusToken != model.searchFocusToken {
            context.coordinator.focusToken = model.searchFocusToken
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }
}

// MARK: - Detail

private struct SettingsDetail: View {
    let model: SettingsModel

    var body: some View {
        if let pane = model.selectedPane {
            VStack(alignment: .leading, spacing: 0) {
                Text(pane.title)
                    .font(.title2.weight(.semibold))
                    .padding(.leading, 28)
                    .padding(.trailing, 56)
                    .padding(.top, 18)
                    .padding(.bottom, 2)
                    .accessibilityAddTraits(.isHeader)
                SettingsPaneForm(model: model, pane: pane)
                    .environment(\.settingsPaneID, pane.id)
                    .id(pane.id)
            }
        }
    }
}

private struct SettingsPaneForm: View {
    let model: SettingsModel
    let pane: SettingsSection
    @State private var handledScrollToken = 0

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let request = model.scrollRequest, request.token > handledScrollToken else { return }
        handledScrollToken = request.token
        DispatchQueue.main.async {
            proxy.scrollTo(request.anchor, anchor: .center)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                ForEach(pane.groups, id: \.id) { group in
                    if group.rows.count == 1, case .shortcuts = group.rows[0].field {
                        SettingsShortcutSections(model: model)
                    } else {
                        Section {
                            ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in
                                SettingsFieldRow(model: model, row: row)
                            }
                        } header: {
                            if let title = group.title { Text(title) }
                        } footer: {
                            if let footer = group.footer {
                                Text(footer)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .coordinateSpace(name: SettingsCoordinateSpace.pane)
            .background(GeometryReader { geometry in
                Color.clear
                    .onAppear { model.viewportSize = geometry.size }
                    .onChange(of: geometry.size) { _, size in model.viewportSize = size }
            })
            .onPreferenceChange(SettingsAnchorFrameKey.self) { frames in
                MainActor.assumeIsolated { model.noteFrames(frames) }
            }
            .onChange(of: model.scrollRequest) { _, _ in scroll(proxy) }
            .onAppear { scroll(proxy) }
        }
    }
}

/// One schema row, drawn by its kind.
struct SettingsFieldRow: View {
    let model: SettingsModel
    let row: SettingsRow

    var body: some View {
        let field = row.field
        let _ = model.revision
        if field.isVisible(in: model.defaults) {
            switch field {
            case .agentSounds:
                SettingsSoundRows(model: model)
            case .custom("harnessStatus", _):
                SettingsHarnessRows(model: model)
            case .shortcuts:
                EmptyView()
            default:
                rowContent(field)
                    .settingsAnchor(SettingsRegistry.anchor(for: field) ?? field.label, model: model)
                    .settingsResettable(field, model: model)
            }
        }
    }

    @ViewBuilder
    private func rowContent(_ field: SettingsField) -> some View {
        switch field {
        case .toggle:
            ToggleRow(row: row, model: model)
        case let .choice(key, _, _, _, _) where key == AgentModelConfig.modelKey:
            SettingsModelPickerRow(model: model, row: row)
        case .choice:
            PickerRow(row: row, model: model)
        case .slider:
            SliderRow(row: row, model: model)
        case .number:
            NumberRow(row: row, model: model)
        case let .text(key, _, _) where key == EditorPreferences.fontFamilyKey:
            SettingsFontFamilyRow(model: model, row: row)
        case .text:
            TextRow(row: row, model: model)
        case .url:
            TextRow(row: row, model: model, validatesURL: true)
        case .directory:
            PathRow(row: row, model: model)
        case let .info(text):
            InfoRow(text: text)
        case let .action(id, label, buttonTitle):
            let enabled = model.canPerform(action: id)
            ButtonRow(title: label, buttonTitle: buttonTitle,
                      help: enabled || id != "checkForUpdates" ? row.help : "Updates are checked in the released app only.",
                      enabled: enabled) { model.perform(action: id) }
        case let .custom(id, label):
            if let make = model.customViews[id] {
                EmbeddedAppKitView(make: make)
            } else {
                InfoRow(text: "\(label) is not available here.")
            }
        case .agentSounds, .shortcuts:
            EmptyView()
        }
    }
}

// MARK: - Model picker

private struct SettingsModelPickerRow: View {
    let model: SettingsModel
    let row: SettingsRow

    var body: some View {
        let items = model.modelPickerItems()
        let providers = items.filter(\.offered).reduce(into: [String]()) { if !$0.contains($1.provider) { $0.append($1.provider) } }
        let missing = items.first { !$0.offered }
        VStack(alignment: .leading, spacing: 6) {
            Picker(selection: Binding(get: { model.storedModel }, set: { model.write(.string($0), to: row.field) })) {
                ForEach(providers, id: \.self) { provider in
                    Section(provider.isEmpty ? "Models" : provider) {
                        ForEach(items.filter { $0.offered && $0.provider == provider }) { item in
                            Text(item.title).tag(item.id)
                        }
                    }
                }
                if let missing {
                    Text("\(missing.id) (not offered)").tag(missing.id)
                }
            } label: {
                SettingsRowLabel(title: row.field.label, help: items.isEmpty ? "Waiting for \(model.currentHarness.rawValue) to list its models." : row.help)
            }
            .pickerStyle(.menu)
            if let missing {
                Label("\(model.currentHarness.rawValue) does not offer \(missing.id). Choose one of its models.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("ArraySettingsModelWarning")
            }
        }
    }
}

// MARK: - Editor font

private enum MonospacedFontFamilies {
    /// Computed once: checking every installed family for fixed pitch is not free.
    @MainActor static let all: [String] = {
        NSFontManager.shared.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch || font.fontDescriptor.symbolicTraits.contains(.monoSpace)
        }
    }()
}

private struct SettingsFontFamilyRow: View {
    let model: SettingsModel
    let row: SettingsRow

    var body: some View {
        let binding = model.binding(for: row.field)
        let current = binding.string
        var families = [EditorPreferences.defaultFontFamily] + MonospacedFontFamilies.all
        if !families.contains(current) { families.insert(current, at: 1) }
        return Picker(selection: Binding(get: { current }, set: { binding.set(.string($0)) })) {
            ForEach(families, id: \.self) { family in
                Text(family).tag(family)
            }
        } label: {
            SettingsRowLabel(title: row.field.label, help: row.help)
        }
        .pickerStyle(.menu)
    }
}

// MARK: - Agent CLIs

private struct SettingsHarnessRows: View {
    let model: SettingsModel

    private func describe(_ readiness: HarnessReadiness) -> (String, String, StatusRow.Tone, Bool) {
        switch readiness {
        case .ready: return ("Ready", "checkmark.circle.fill", .good, false)
        case .checking: return ("Checking…", "clock", .neutral, false)
        case .missing: return ("Not installed", "xmark.circle", .warning, false)
        case .loggedOut: return ("Signed out", "person.crop.circle.badge.exclamationmark", .warning, true)
        case let .unavailable(reason): return (reason.isEmpty ? "Unavailable" : reason, "exclamationmark.triangle", .warning, true)
        }
    }

    private func detail(_ harness: AgentHarness, _ readiness: HarnessReadiness) -> String {
        if readiness == .missing {
            return "Not found on this Mac. Install it, then reopen Settings."
        }
        switch harness {
        case .claudeCode: return "Signs in with your Claude account."
        case .codex: return "Signs in with your ChatGPT account."
        case .pi: return "Signs in per provider with pi's /login."
        }
    }

    var body: some View {
        ForEach(AgentHarness.allCases, id: \.self) { harness in
            let readiness = model.readiness(of: harness)
            let (status, symbol, tone, canSignIn) = describe(readiness)
            StatusRow(title: harness.rawValue, status: status, symbol: symbol, tone: tone,
                      detail: detail(harness, readiness),
                      actionTitle: canSignIn && model.onSignIn != nil ? "Sign In…" : nil,
                      action: { model.onSignIn?(harness) })
                .settingsAnchor("harness.\(harness.rawValue)", model: model)
        }
    }
}

// MARK: - Sounds

private struct SettingsSoundRows: View {
    let model: SettingsModel
    @State private var renameTarget: AgentSoundManifestEntry?
    @State private var renameText = ""

    var body: some View {
        let _ = model.revision
        Toggle(isOn: Binding(get: { model.soundsEnabled }, set: { model.soundsEnabled = $0 })) {
            SettingsRowLabel(title: "Play agent sounds", help: "Each sound below plays only when this is on.")
        }
        .toggleStyle(.switch)
        .settingsAnchor("sounds.master", model: model)

        LabeledContent {
            HStack(spacing: 10) {
                Slider(value: Binding(get: { model.soundVolume }, set: { model.soundVolume = $0 }), in: 0...1) { editing in
                    if !editing { model.playSample() }
                }
                .frame(minWidth: 160, maxWidth: 240)
                Text(SettingsValueFormat.percent.string(for: model.soundVolume))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        } label: {
            SettingsRowLabel(title: "Volume", help: nil)
        }
        .disabled(!model.soundsEnabled)
        .settingsAnchor("sounds.volume", model: model)

        ForEach(AgentSignalKind.allCases.sorted(by: { $0.priority > $1.priority }), id: \.self) { kind in
            soundRuleRow(kind)
                .settingsAnchor("sounds.kind.\(kind.rawValue)", model: model)
        }

        LabeledContent {
            HStack {
                Button("Import…") { model.importSounds() }
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                SettingsRowLabel(title: "Custom sounds", help: model.importedSounds.isEmpty ? "Add your own audio files to choose them above." : nil)
                ForEach(model.importedSounds) { entry in
                    HStack(spacing: 8) {
                        Text(entry.name)
                        Spacer(minLength: 8)
                        Button("Rename…") { renameTarget = entry; renameText = entry.name }
                            .buttonStyle(.link)
                        Button("Remove") { model.removeSound(entry.id) }
                            .buttonStyle(.link)
                    }
                    .font(.callout)
                }
            }
        }
        .settingsAnchor("sounds.library", model: model)
        .alert("Rename sound", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let target = renameTarget { model.renameSound(target.id, to: renameText) }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    private func soundRuleRow(_ kind: AgentSignalKind) -> some View {
        let rule = model.soundRule(kind)
        return LabeledContent {
            HStack(spacing: 8) {
                Picker("", selection: Binding(get: { rule.sound.rawValue }, set: { model.setSound(AgentSoundReference(rawValue: $0), for: kind) })) {
                    ForEach(model.soundEntries) { entry in
                        Text(entry.name).tag(entry.id.rawValue)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 160)
                Button {
                    model.playSample(rule.sound)
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Play \(kind.displayName) sound")
                Toggle("", isOn: Binding(get: { rule.enabled }, set: { model.setSoundEnabled($0, for: kind) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel("Play a sound when \(kind.displayName.lowercased())")
            }
        } label: {
            SettingsRowLabel(title: kind.displayName, help: nil)
        }
        .disabled(!model.soundsEnabled)
    }
}

// MARK: - Keyboard shortcuts

private struct SettingsShortcutSections: View {
    let model: SettingsModel

    var body: some View {
        ForEach(model.shortcutGroups) { group in
            Section(group.title) {
                ForEach(group.entries, id: \.id) { entry in
                    SettingsShortcutRow(model: model, entry: entry)
                        .settingsAnchor("shortcut.\(entry.id)", model: model)
                }
            }
        }
    }
}

private struct SettingsShortcutRow: View {
    let model: SettingsModel
    let entry: ShortcutCatalogEntry

    var body: some View {
        let recording = model.recordingEntryID == entry.id
        LabeledContent {
            HStack(spacing: 8) {
                if recording {
                    ChordCaptureRepresentable(model: model, entryID: entry.id)
                        .frame(width: 250, height: 22)
                } else {
                    Text(entry.chordDisplay.isEmpty ? "None" : entry.chordDisplay)
                        .font(.body.monospaced())
                        .foregroundStyle(entry.chordDisplay.isEmpty ? .tertiary : .secondary)
                }
                if entry.configurable, entry.editTarget != nil {
                    Button(recording ? "Cancel" : "Record") {
                        recording ? model.cancelRecording() : model.beginRecording(entry.id)
                    }
                    .controlSize(.small)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.label)
                if let message = model.captureMessages[entry.id] {
                    Text(message).font(.callout).foregroundStyle(.red)
                }
            }
        }
        .contextMenu {
            if entry.configurable, entry.editTarget != nil {
                Button("Reset to Default") { model.resetShortcut(entry.id) }
                if model.canUnassign(entry) {
                    Button("Remove Shortcut") { model.unassignShortcut(entry.id) }
                }
            }
        }
    }
}

/// The existing AppKit chord capture, hosted in the row while recording.
private struct ChordCaptureRepresentable: NSViewRepresentable {
    let model: SettingsModel
    let entryID: String

    func makeNSView(context: Context) -> ChordCaptureView {
        let view = ChordCaptureView()
        view.onCapture = { keyCode, modifiers, character in
            model.finishCapture(entryID: entryID, keyCode: keyCode, modifiers: modifiers, character: character)
            if let message = model.captureMessages[entryID] { view.showValidationError(message) }
        }
        view.onCancel = { model.cancelRecording() }
        DispatchQueue.main.async { view.beginCapture() }
        return view
    }

    func updateNSView(_ nsView: ChordCaptureView, context: Context) {}
}
