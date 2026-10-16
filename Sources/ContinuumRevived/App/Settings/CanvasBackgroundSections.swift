import AppKit
import ContinuumRevivedCore
import SwiftUI

/// Settings ▸ Appearance ▸ Canvas background, drawn with the row kit. Rows that
/// cannot act in the current state are not drawn: the colour picker only when the
/// system colour is off, grid rows only for a grid, image rows only with an image.
/// The preview is its own section, with the spoken summary as its footer.
struct CanvasBackgroundSections: View {
    let editor: CanvasBackgroundEditor
    let model: SettingsModel

    private typealias E = CanvasBackgroundEditor

    private func label(_ identifier: String) -> SettingsRowLabel {
        SettingsRowLabel(title: E.control(identifier).label, help: nil)
    }

    /// Rows present in every state are census anchors (search can land on them);
    /// conditional rows only report their frame.
    @ViewBuilder
    private func anchored<Content: View>(_ identifier: String, @ViewBuilder _ content: () -> Content) -> some View {
        let always = [E.scopeIdentifier, E.patternIdentifier, E.baseSystemIdentifier, E.imageIdentifier, E.resetIdentifier]
        if always.contains(identifier) {
            content()
                .accessibilityHint(E.control(identifier).help)
                .settingsAnchor(identifier, model: model)
        } else {
            content()
                .accessibilityHint(E.control(identifier).help)
                .settingsFrame(identifier)
        }
    }

    private func colorBinding(_ source: CanvasBackgroundColorSource, fallback: CanvasBackgroundRGBA,
                              set: @escaping (NSColor) -> Void) -> Binding<Color> {
        Binding(
            get: { Color(cgColor: (source.customColor ?? fallback).cgColor) },
            set: { set(NSColor($0)) })
    }

    var body: some View {
        let _ = editor.revision
        let config = editor.configuration
        Section {
            anchored(E.scopeIdentifier) {
                LabeledContent {
                    Picker("", selection: Binding(get: { editor.scope }, set: { editor.selectScope($0) })) {
                        ForEach(E.Scope.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!editor.environment.hasWorkspace)
                } label: {
                    SettingsRowLabel(title: "Edit for",
                                     help: editor.environment.hasWorkspace ? nil : "Open a workspace to give it its own background.")
                }
            }
            if editor.isPresent(E.inheritIdentifier) {
                anchored(E.inheritIdentifier) {
                    Toggle(isOn: Binding(get: { editor.inheritsGlobal }, set: { editor.setInheritsGlobal($0) })) {
                        SettingsRowLabel(title: E.control(E.inheritIdentifier).label,
                                         help: "Turn off to give this workspace its own background.")
                    }
                    .toggleStyle(.switch)
                }
            }
            anchored(E.patternIdentifier) {
                Picker(selection: Binding(get: { config.pattern }, set: { editor.selectPattern($0) })) {
                    ForEach(CanvasBackgroundPattern.allCases, id: \.self) { Text($0.displayName).tag($0) }
                } label: { label(E.patternIdentifier) }
                .pickerStyle(.menu)
            }
            anchored(E.baseSystemIdentifier) {
                Toggle(isOn: Binding(get: { editor.usesSystemBase }, set: { editor.setUsesSystemBase($0) })) {
                    SettingsRowLabel(title: E.control(E.baseSystemIdentifier).label,
                                     help: "Follows Light and Dark. Turn off to choose an exact colour.")
                }
                .toggleStyle(.switch)
            }
            if editor.isPresent(E.baseColorIdentifier) {
                anchored(E.baseColorIdentifier) {
                    ColorPicker(selection: colorBinding(config.base, fallback: .opaque(0.11, 0.12, 0.14), set: editor.setBaseColor),
                                supportsOpacity: false) { label(E.baseColorIdentifier) }
                }
            }
            if editor.isPresent(E.patternColorIdentifier) {
                anchored(E.patternColorIdentifier) {
                    ColorPicker(selection: colorBinding(config.patternColor, fallback: CanvasBackgroundConfiguration.defaultPatternColor,
                                                        set: editor.setPatternColor),
                                supportsOpacity: true) { label(E.patternColorIdentifier) }
                }
            }
            if editor.isPresent(E.spacingIdentifier) {
                anchored(E.spacingIdentifier) {
                    LabeledContent {
                        HStack(spacing: 10) {
                            Slider(value: Binding(get: { config.spacing }, set: { editor.setSpacing($0) }),
                                   in: CanvasBackgroundConfiguration.spacingRange)
                                .frame(minWidth: 160, maxWidth: 240)
                            Text(SettingsValueFormat.number(decimals: 0, unit: "pt").string(for: config.spacing))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .trailing)
                        }
                    } label: { label(E.spacingIdentifier) }
                }
            }
            anchored(E.imageIdentifier) {
                LabeledContent {
                    HStack(spacing: 8) {
                        if config.image != nil {
                            Button("Remove") { editor.removeImage() }
                        }
                        Button(config.image == nil ? "Choose Image…" : "Replace…") { editor.chooseImage() }
                    }
                } label: {
                    SettingsRowLabel(title: E.control(E.imageIdentifier).label,
                                     help: editor.lastImportError ?? (config.image == nil ? "None" : nil))
                }
            }
            if editor.isPresent(E.opacityIdentifier) {
                anchored(E.opacityIdentifier) {
                    Picker(selection: Binding(get: { config.image?.opacity ?? .full }, set: { editor.setOpacity($0) })) {
                        ForEach(CanvasBackgroundImageOpacity.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    } label: { label(E.opacityIdentifier) }
                    .pickerStyle(.menu)
                }
            }
            if editor.isPresent(E.modeIdentifier) {
                anchored(E.modeIdentifier) {
                    Picker(selection: Binding(get: { config.image?.mode ?? .fill }, set: { editor.setMode($0) })) {
                        ForEach(CanvasBackgroundImageMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    } label: { label(E.modeIdentifier) }
                    .pickerStyle(.segmented)
                }
            }
        } header: {
            Text("Canvas background")
        }

        Section {
            CanvasBackgroundPreview(configuration: config)
                .frame(height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
                .settingsFrame(E.previewIdentifier)
            anchored(E.resetIdentifier) {
                ButtonRow(title: E.control(E.resetIdentifier).label, buttonTitle: "Reset") { editor.reset() }
            }
        } header: {
            Text("Preview")
        } footer: {
            // The preview's spoken equivalent; it states the effective scope.
            Text(editor.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Effective background: \(editor.summary)")
        }
    }
}

/// The live renderer the canvas itself uses, as decoration: the summary is what
/// a screen reader gets.
struct CanvasBackgroundPreview: NSViewRepresentable {
    let configuration: CanvasBackgroundConfiguration

    func makeNSView(context: Context) -> CanvasBackgroundRendererView {
        let view = CanvasBackgroundRendererView(
            imageCache: CanvasBackgroundImageCache(store: CanvasBackgroundAssetStore()))
        view.setAccessibilityElement(false)
        view.identifier = NSUserInterfaceItemIdentifier(CanvasBackgroundEditor.previewIdentifier)
        return view
    }

    func updateNSView(_ view: CanvasBackgroundRendererView, context: Context) {
        if view.currentConfiguration != configuration { view.setConfiguration(configuration) }
        view.updateCamera(viewport: CanvasViewport(x: 0, y: 0, zoom: 1))
    }
}
