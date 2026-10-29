// Disposable UIKit app for observing real simulator input. No Array connectivity.
import UIKit

@main
final class WitnessApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = WitnessController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

final class WitnessController: UIViewController {
    private let field = UITextField()
    private let button = UIButton(type: .system)
    private let countLabel = UILabel()
    private var taps = 0
    private var timer: Timer?
    private let latencyMarker = UIView()
    private let activityMarker = UIView()
    private var displayLink: CADisplayLink?
    private var animationTick = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        latencyMarker.backgroundColor = .red
        latencyMarker.isUserInteractionEnabled = false
        activityMarker.isUserInteractionEnabled = false
        view.addSubview(latencyMarker)
        view.addSubview(activityMarker)
        if ProcessInfo.processInfo.arguments.contains("--performance-animation") {
            let link = CADisplayLink(target: self, selector: #selector(animateProof))
            link.preferredFramesPerSecond = 60
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        let title = UILabel()
        title.text = "Array · Live iOS Proof"
        title.font = .systemFont(ofSize: 26, weight: .semibold)
        let description = UILabel()
        description.text = "Running in a real iOS Simulator"
        description.font = .systemFont(ofSize: 16)
        description.textColor = .secondaryLabel
        button.setTitle("Tap through the native preview", for: .normal)
        button.configuration = .filled()
        button.addTarget(self, action: #selector(tapped), for: .touchUpInside)
        countLabel.text = "Touches received: 0"
        countLabel.font = .monospacedSystemFont(ofSize: 18, weight: .medium)
        field.placeholder = "Type through the preview"
        field.borderStyle = .roundedRect
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.addTarget(self, action: #selector(changed), for: .editingChanged)
        let footer = UILabel()
        footer.text = "Disposable input witness · no project or account data"
        footer.numberOfLines = 0
        footer.textColor = .secondaryLabel
        footer.font = .systemFont(ofSize: 14)
        let stack = UIStackView(arrangedSubviews: [title, description, button, countLabel, field, footer])
        stack.axis = .vertical
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 32),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            button.heightAnchor.constraint(equalToConstant: 68),
            field.heightAnchor.constraint(equalToConstant: 48),
        ])
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.record() }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        latencyMarker.frame = CGRect(x: view.bounds.width - 38, y: view.safeAreaInsets.top + 4, width: 24, height: 24)
        activityMarker.frame = CGRect(x: view.bounds.width - 68, y: view.safeAreaInsets.top + 4, width: 24, height: 24)
    }
    @objc private func animateProof() {
        animationTick += 1
        activityMarker.backgroundColor = UIColor(hue: CGFloat(animationTick % 60) / 60, saturation: 1, brightness: 1, alpha: 1)
    }
    @objc private func tapped() {
        taps += 1
        latencyMarker.backgroundColor = taps % 2 == 0 ? .red : .blue
        countLabel.text = "Touches received: \(taps)"
        record()
    }
    @objc private func changed() { record() }
    private func record() {
        guard let window = view.window else { return }
        func rect(_ child: UIView) -> [String: Double] {
            let r = child.convert(child.bounds, to: window)
            return ["x": r.midX / window.bounds.width, "y": r.midY / window.bounds.height]
        }
        let state: [String: Any] = [
            "taps": taps, "text": field.text ?? "", "fieldFocused": field.isFirstResponder,
            "button": rect(button), "field": rect(field), "latencyMarker": rect(latencyMarker),
            "performanceAnimation": displayLink != nil,
            "width": window.bounds.width, "height": window.bounds.height,
            "orientation": window.windowScene?.interfaceOrientation.rawValue ?? 0,
        ]
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("proof-state.json")
        try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]).write(to: url, options: .atomic)
    }
}
