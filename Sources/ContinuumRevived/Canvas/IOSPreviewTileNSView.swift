import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

@MainActor
final class IOSPreviewTileNSView: TileNSView {
    let runtime: IOSPreviewRuntime
    let screen = IOSPreviewScreenView()
    private let body = FlippedContainerView()
    private let devices = ChoiceButton(title: "Choose simulator")
    private let actions = ChoiceButton(title: "Preview")
    private let connectButton: ComposerActionButton
    private let status = NSTextField(labelWithString: "")
    var buildProjectRoot: URL?
    private let builder = IOSPreviewBuild()
    private var buildTask: Task<Void, Never>?
    var isBuilding: Bool { buildTask != nil }
    private var buildMessage: String?
    private var buildGeneration = 0
    var qaStatusText: String { status.stringValue }
    private var buildChoices: [IOSPreviewBuildChoice] = []
    private(set) var buildDirectory: URL?
    var onDeviceSelection: ((String?) -> Void)?
    var reservedShortcutHandler: ((NSEvent) -> Bool)?
    private var deviceTask: Task<Void, Never>?
    private var visibilityTimer: Timer?
    private var windowVisible = true
    private var retired = false
    override var surfaceIsAnimating: Bool { runtime.state == .connected }

    init(tile: Tile, runtime: IOSPreviewRuntime) {
        self.runtime = runtime
        connectButton = ComposerActionButton(presentation: Self.buttonPresentation(title: "Connect", symbol: "play.fill"))
        super.init(tile: tile)
        body.wantsLayer = true
        screen.owner = self
        status.font = .token(.caption)
        status.maximumNumberOfLines = 2
        status.lineBreakMode = .byWordWrapping
        devices.items = [ChoiceItem(id: "refresh", title: "Find simulators…", detail: "Devices installed with Xcode")]
        if let id = tile.metadata.iosPreviewDeviceID {
            devices.items.insert(ChoiceItem(id: id, title: "Saved simulator", detail: "Refresh to check availability"), at: 0)
            devices.selectedID = id
        } else { devices.setPresentationTitle("Choose simulator") }
        devices.onSelection = { [weak self] item in
            guard let self else { return }
            if item.id == "refresh" { self.refreshDevices(); return }
            self.selectDevice(id: item.id, name: item.title)
        }
        connectButton.target = self; connectButton.action = #selector(toggleConnection)
        actions.popoverPresentation = .commands
        actions.items = [
            ChoiceItem(id: "home", title: "Home"),
            ChoiceItem(id: "rotate", title: "Rotate"),
            ChoiceItem(id: "refresh", title: "Refresh simulators…"),
        ]
        actions.keepsSelectionForItem = { _ in false }
        actions.setPresentationTitle("Preview")
        actions.onSelection = { [weak self] item in
            guard let self else { return }
            if ["home", "rotate"].contains(item.id) { self.recordHumanInput() }
            switch item.id {
            case "stop-agent": self.recordHumanInput(); self.screen.releaseInput()
            case "allow-agent": self.runtime.allowAutomationHandover()
            case "home": self.runtime.home()
            case "rotate": self.runtime.rotate()
            case "build": self.findBuildChoices()
            case "cancel-build": self.cancelBuild(); self.refresh()
            case "build-log":
                if let directory = self.buildDirectory { NSWorkspace.shared.open(directory) }
            case let id where id.hasPrefix("build-choice-"):
                if let index = Int(id.dropFirst(13)), self.buildChoices.indices.contains(index) {
                    self.startBuild(self.buildChoices[index])
                }
            default: self.refreshDevices()
            }
        }
        for view in [screen, devices, actions, connectButton, status] { body.addSubview(view) }
        setContentView(body)
        runtime.onChange = { [weak self] in self?.refresh() }
        runtime.onFrame = { [weak self] image in
            guard let self, !self.retired else { return }
            self.screen.image = image
            self.startVisibilityTimer()
        }
        refresh(); applyTokens()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    func recordHumanInput() {
        if tile.metadata.iosPreviewAutomationOwnership != nil, let deviceID = runtime.deviceID {
            IOSPreviewAutomationSessions.shared.reclaim(deviceID: deviceID, tileID: tile.id)
        }
        runtime.humanInputBegan()
    }
    func selectDevice(id: String, name: String) {
        cancelBuild()
        if !devices.items.contains(where: { $0.id == id }) {
            devices.items.insert(ChoiceItem(id: id, title: name), at: 0)
        }
        devices.selectedID = id
        if tile.metadata.iosPreviewAutomationOwnership != nil {
            recordHumanInput()
            IOSPreviewAutomationSessions.shared.reclaim(deviceID: id, tileID: tile.id)
        }
        runtime.select(id); screen.image = nil
        refresh(); onDeviceSelection?(id)
    }
    private static func buttonPresentation(title: String, symbol: String) -> AgentComposerPresentation {
        .init(primaryAction: .send, title: title, symbolName: symbol, accessibilityLabel: title,
              isEnabled: true, isLoading: false, secondaryActions: [])
    }
    override func layout() {
        super.layout()
        let top = max(12, 28 / max(0.01, CGFloat(canvas?.viewport.zoom ?? 1)) - 24 + 12)
        let width = body.bounds.width
        // Geometry only: panning/zooming must not remeasure button text or
        // invalidate unchanged child frames on every canvas display cycle.
        func place(_ view: NSView, _ frame: NSRect) { if view.frame != frame { view.frame = frame } }
        let connectWidth: CGFloat = 116
        place(actions, NSRect(x: width - 112, y: top, width: 100, height: 32))
        place(connectButton, NSRect(x: actions.frame.minX - 8 - connectWidth, y: top, width: connectWidth, height: 32))
        place(devices, NSRect(x: 12, y: top, width: max(40, connectButton.frame.minX - 20), height: 32))
        place(status, NSRect(x: 16, y: top + 40, width: max(0, width - 32), height: 38))
        place(screen, NSRect(x: 12, y: top + 82, width: max(0, width - 24), height: max(0, body.bounds.height - top - 94)))
    }
    @objc func toggleConnection() {
        recordHumanInput()
        if runtime.state == .connected || runtime.state == .connecting { cancelBuild(); runtime.disconnect() }
        else { runtime.connect(); startVisibilityTimer() }
    }
    override func acquireFocus(reason: FocusRequest) -> Bool {
        canvas?.bringToFront(tileId: tile.id)
        promoteForIncomingFocus()
        return window?.makeFirstResponder(runtime.state == .connected ? screen : devices) ?? false
    }
    func refreshDevices() {
        guard deviceTask == nil else { return }
        status.stringValue = "Finding simulators…"
        deviceTask = Task { [weak self] in
            defer { self?.deviceTask = nil }
            do {
                let available = try await IOSPreviewTools.devices()
                guard let self, !self.retired else { return }
                self.devices.items = available.map {
                    ChoiceItem(id: $0.id, title: $0.name, detail: ($0.isBooted ? "Running · " : "Stopped · ") + $0.runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: ""))
                } + [ChoiceItem(id: "refresh", title: "Refresh simulators…")]
                if let id = self.runtime.deviceID, available.contains(where: { $0.id == id }) {
                    self.devices.selectedID = id
                } else { self.devices.setPresentationTitle("Choose simulator") }
                self.refresh()
                if available.isEmpty { self.status.stringValue = "Install an iOS runtime in Xcode to add a simulator." }
                else if self.window != nil { self.devices.presentPopover() }
            } catch { self?.status.stringValue = "Open Xcode and install an iOS runtime, then refresh simulators." }
        }
    }
    private func refresh() {
        if runtime.state != .connected { screen.releaseInput() }
        // Visibility suspends streaming, not an explicitly requested build.
        // User disconnect, selection, parking and removal cancel at their seams.
        if case .failed = runtime.state, buildTask != nil { cancelBuild() }
        if let id = runtime.deviceID, devices.items.contains(where: { $0.id == id }) { devices.selectedID = id }
        else { devices.setPresentationTitle("Choose simulator") }
        status.stringValue = Self.statusText(state: runtime.state, buildMessage: buildMessage, controllerName: runtime.automationController)
        let connected = runtime.state == .connected || runtime.state == .connecting
        connectButton.presentation = Self.buttonPresentation(title: connected ? "Disconnect" : "Connect", symbol: connected ? "pause.fill" : "play.fill")
        var presentation = connectButton.presentation
        presentation.isEnabled = runtime.deviceID != nil
        connectButton.presentation = presentation
        actions.items = [ChoiceItem(id: "home", title: "Home", enabled: runtime.state == .connected),
                         ChoiceItem(id: "rotate", title: "Rotate", enabled: runtime.state == .connected),
                         ChoiceItem(id: "refresh", title: "Refresh simulators…")]
        actions.items += [ChoiceItem(id: "build", title: "Build & Run…", enabled: runtime.state == .connected && buildTask == nil && buildProjectRoot != nil)]
        if buildTask != nil { actions.items.append(ChoiceItem(id: "cancel-build", title: "Cancel Build")) }
        if buildDirectory != nil { actions.items.append(ChoiceItem(id: "build-log", title: "Show Build Files…")) }
        if runtime.automationController != nil { actions.items.insert(ChoiceItem(id: "stop-agent", title: "Take Control"), at: 0) }
        if IOSPreviewAutomationSessions.shared.isReclaimed(deviceID: runtime.deviceID) {
            actions.items.insert(ChoiceItem(id: "allow-agent", title: "Allow Agent Control"), at: 0)
        }
        actions.setPresentationTitle("Preview")
        screen.orientation = runtime.orientation
        screen.needsDisplay = true
    }
    static func statusText(state: IOSPreviewRuntime.State, buildMessage: String?, controllerName: String? = nil) -> String {
        switch state {
        case .disconnected: return "Choose a simulator and Connect. Closing the preview leaves it running."
        case .connecting: return "Connecting to simulator…"
        case .connected: return buildMessage ?? controllerName.map { "Live · \($0) controls this simulator. Click to take control." } ?? "Live · Click the screen to interact. Escape returns to the canvas."
        case .failed(let message): return message
        }
    }
    private func setBuildMessage(_ message: String, generation: Int) {
        guard generation == buildGeneration else { return }
        buildMessage = message
    }
    private func findBuildChoices() {
        guard buildTask == nil, runtime.state == .connected, let root = buildProjectRoot else { return }
        buildChoices = []
        let generation = buildGeneration
        buildMessage = "Finding Xcode schemes…"
        buildTask = Task { [weak self] in
            guard let self else { return }
            defer { self.buildTask = nil; self.refresh() }
            do {
                let choices = try await self.builder.choices(in: root)
                try Task.checkCancellation()
                guard generation == self.buildGeneration else { return }
                self.buildChoices = choices
                self.buildMessage = choices.isEmpty ? "No shared Xcode schemes found in this project or its ios folder." : "Choose a scheme from Preview to build and run."
            } catch is CancellationError { self.setBuildMessage("Build cancelled.", generation: generation) }
            catch { self.setBuildMessage(error.localizedDescription, generation: generation) }
            // Present after defer resets the ordinary menu.
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, generation == self.buildGeneration, !self.retired, self.runtime.state == .connected, !self.buildChoices.isEmpty else { return }
                self.actions.items = self.buildChoices.enumerated().map {
                    ChoiceItem(id: "build-choice-\($0.offset)", title: $0.element.title, detail: $0.element.container.path)
                }
                self.actions.presentPopover()
            }
        }
        refresh()
    }
    func startBuild(_ choice: IOSPreviewBuildChoice) {
        guard buildTask == nil, runtime.state == .connected, let deviceID = runtime.deviceID else { return }
        recordHumanInput()
        let directory = IOSPreviewBuild.newDirectory()
        let generation = buildGeneration
        buildDirectory = directory
        buildMessage = "Preparing build…"
        builder.onProgress = { [weak self] message in self?.setBuildMessage(message, generation: generation); self?.refresh() }
        buildTask = Task { [weak self] in
            guard let self else { return }
            defer { self.buildTask = nil; self.refresh() }
            do {
                _ = try await self.builder.run(choice: choice, deviceID: deviceID, directory: directory)
                try Task.checkCancellation()
                self.setBuildMessage("Running \(choice.scheme). Build files are available in Preview.", generation: generation)
            } catch is CancellationError { self.setBuildMessage("Build cancelled. See Preview for build files.", generation: generation) }
            catch { self.setBuildMessage("\(error.localizedDescription) See Preview for build files.", generation: generation) }
            await IOSPreviewBuild.releaseDerivedData(in: directory)
        }
        refresh()
    }
    private func cancelBuild() {
        buildTask?.cancel(); buildChoices = []
        buildGeneration &+= 1
        buildMessage = nil
    }
    func showPersistenceError() { status.stringValue = "Could not save the simulator selection. Try again." }
    var qaTokenPaintedLayers: [(label: String, layer: CALayer)] {
        body.layer.map { [("body", $0)] } ?? []
    }
    private func startVisibilityTimer() {
        guard visibilityTimer == nil, !retired else { return }
        visibilityTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.window != nil && self.windowVisible && !self.visibleRect.isEmpty { self.runtime.resume() }
                else { self.screen.releaseInput(); self.runtime.suspend() }
            }
        }
    }
    override func windowOcclusionChanged(visible: Bool) {
        windowVisible = visible
        if visible { runtime.resume() } else { screen.releaseInput(); runtime.suspend() }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { screen.releaseInput(); runtime.suspend() }
        else { runtime.resume() }
    }
    override func prepareForParking() {
        cancelBuild()
        screen.releaseInput(); runtime.suspend()
    }
    override func prepareForRemovalFromScene() {
        cancelBuild()
        retired = true; deviceTask?.cancel(); deviceTask = nil
        visibilityTimer?.invalidate(); visibilityTimer = nil
        screen.releaseInput(); runtime.retireViewer()
    }
    override func applyTokens() {
        super.applyTokens()
        body.layer?.backgroundColor = SurfaceToken.tileBody.color.cgColor(in: self)
        status.textColor = TextToken.textSecondary.color.nsColor(in: self)
        screen.needsDisplay = true
    }
}

@MainActor
final class IOSPreviewScreenView: NSView {
    weak var owner: IOSPreviewTileNSView?
    var image: CGImage? { didSet { needsDisplay = true } }
    var orientation = 1
    private var contact: CGPoint?
    private var modifiers: Set<Int> = []
    private var heldKeys: Set<Int> = []
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        releaseInput()
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        center.removeObserver(self, name: NSApplication.didResignActiveNotification, object: nil)
        guard let window else { return }
        // A visible window keeps its first responder when another application
        // becomes active. resignFirstResponder alone cannot release its HID state.
        center.addObserver(self, selector: #selector(inputFocusLost(_:)), name: NSWindow.didResignKeyNotification, object: window)
        center.addObserver(self, selector: #selector(inputFocusLost(_:)), name: NSApplication.didResignActiveNotification, object: nil)
    }
    @objc private func inputFocusLost(_ notification: Notification) { releaseInput() }
    var screenRect: CGRect {
        let raw = CGSize(width: image?.width ?? 402, height: image?.height ?? 874)
        let size = [3, 4].contains(orientation) ? CGSize(width: raw.height, height: raw.width) : raw
        let available = bounds.insetBy(dx: 8, dy: 8)
        let scale = min(available.width / size.width, available.height / size.height)
        return CGRect(x: bounds.midX - size.width * scale / 2, y: bounds.midY - size.height * scale / 2,
                      width: size.width * scale, height: size.height * scale)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let rect = screenRect
        SurfaceToken.tileChrome.color.nsColor(in: self).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: -5, dy: -5), xRadius: 22, yRadius: 22).fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18).addClip()
        let transform = NSAffineTransform()
        transform.translateX(by: rect.midX, yBy: rect.midY)
        let angle: CGFloat = orientation == 3 ? -90 : orientation == 4 ? 90 : orientation == 2 ? 180 : 0
        transform.rotate(byDegrees: angle); transform.concat()
        let rotated = [3, 4].contains(orientation)
        let size = rotated ? CGSize(width: rect.height, height: rect.width) : rect.size
        NSImage(cgImage: image, size: .zero).draw(in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height),
            from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
    func rawPoint(_ point: CGPoint, clamp: Bool) -> CGPoint? {
        let rect = screenRect
        guard rect.width > 0, rect.height > 0, clamp || rect.contains(point) else { return nil }
        let x = min(1, max(0, (point.x - rect.minX) / rect.width))
        let y = min(1, max(0, (point.y - rect.minY) / rect.height))
        return IOSPreviewImageGeometry.rawPoint(x: Double(x), y: Double(y), orientation: orientation)
    }
    private func pointer(_ phase: String, event: NSEvent) {
        guard phase == "begin" || contact != nil,
              let point = rawPoint(convert(event.locationInWindow, from: nil), clamp: phase != "begin") else { return }
        contact = phase == "end" ? nil : point
        owner?.runtime.send(tag: 3, payload: ["type": phase, "x": point.x, "y": point.y])
    }
    override func mouseDown(with event: NSEvent) {
        owner?.recordHumanInput()
        window?.makeFirstResponder(self)
        if let owner { owner.canvas?.focusBroker?.acceptExistingFocus(.tile(owner.tile.id), reason: .userClick) }
        pointer("begin", event: event)
    }
    override func mouseDragged(with event: NSEvent) { pointer("move", event: event) }
    override func mouseUp(with event: NSEvent) { pointer("end", event: event) }
    func releaseInput() {
        if let contact { owner?.runtime.send(tag: 3, payload: ["type": "end", "x": contact.x, "y": contact.y]) }
        for usage in heldKeys { owner?.runtime.send(tag: 6, payload: ["type": "up", "usage": usage]) }
        for usage in modifiers { owner?.runtime.send(tag: 6, payload: ["type": "up", "usage": usage]) }
        contact = nil; heldKeys.removeAll(); modifiers.removeAll()
    }
    override func resignFirstResponder() -> Bool { releaseInput(); return true }
    override func keyDown(with event: NSEvent) {
        owner?.recordHumanInput()
        if event.keyCode == 53 { releaseInput(); window?.makeFirstResponder(owner?.canvas); return }
        if owner?.reservedShortcutHandler?(event) == true { releaseInput(); return }
        // Modifiers may have been pressed before this surface gained focus,
        // so their flagsChanged event belonged to the previous responder.
        synchronizeModifiers(event.modifierFlags)
        if event.modifierFlags.contains(.command), event.keyCode == 9 {
            if let text = NSPasteboard.general.string(forType: .string) { owner?.runtime.paste(text) }; return
        }
        key(event, phase: "down")
    }
    override func keyUp(with event: NSEvent) { key(event, phase: "up") }
    override func flagsChanged(with event: NSEvent) { owner?.recordHumanInput(); synchronizeModifiers(event.modifierFlags) }
    private func synchronizeModifiers(_ flags: NSEvent.ModifierFlags) {
        guard owner?.runtime.state == .connected else { modifiers.removeAll(); return }
        let values: [(NSEvent.ModifierFlags, Int)] = [(.shift, 225), (.control, 224), (.option, 226), (.command, 227)]
        let next = Set(values.filter { flags.contains($0.0) }.map(\.1))
        for usage in modifiers.subtracting(next) { owner?.runtime.send(tag: 6, payload: ["type": "up", "usage": usage]) }
        for usage in next.subtracting(modifiers) { owner?.runtime.send(tag: 6, payload: ["type": "down", "usage": usage]) }
        modifiers = next
    }
    private func key(_ event: NSEvent, phase: String) {
        let usages: [UInt16: Int] = [0:4, 1:22, 2:7, 3:9, 4:11, 5:10, 6:29, 7:27, 8:6, 9:25, 11:5,
            12:20, 13:26, 14:8, 15:21, 16:28, 17:23, 18:30, 19:31, 20:32, 21:33, 22:35, 23:34,
            24:46, 25:38, 26:36, 27:45, 28:37, 29:39, 30:48, 31:18, 32:24, 33:47, 34:12,
            35:19, 36:40, 37:15, 38:13, 39:52, 40:14, 41:51, 42:49, 43:54, 44:56, 45:17,
            46:16, 47:55, 48:43, 49:44, 50:53, 51:42, 117:76, 123:80, 124:79, 125:81, 126:82]
        guard owner?.runtime.state == .connected, let usage = usages[event.keyCode] else { return }
        if phase == "down" { heldKeys.insert(usage) }
        else if heldKeys.remove(usage) == nil { return }
        owner?.runtime.send(tag: 6, payload: ["type": phase, "usage": usage])
    }
}
