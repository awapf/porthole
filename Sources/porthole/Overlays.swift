import AppKit
import PortholeCore

/// Full-bleed status card shown while the session is being brought up, and
/// again if it fails. Keeping it inside the window means the user sees progress
/// from the first moment rather than a blank screen or a bouncing dock icon.
final class StatusOverlay: NSView {
    private let card = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        card.material = .hudWindow
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.isHidden = true
        detail.maximumNumberOfLines = 8
        detail.lineBreakMode = .byWordWrapping
        detail.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [label, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(spinner)
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 620),

            spinner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            spinner.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),

            stack.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ message: String) {
        isHidden = false
        label.stringValue = message
        detail.isHidden = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
    }

    func showError(_ message: String) {
        isHidden = false
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        label.stringValue = "Connection failed"
        detail.stringValue = message + "\n\nPress ⌃⌥⌘Q to quit."
        detail.isHidden = false
    }

    func hide() {
        spinner.stopAnimation(nil)
        isHidden = true
    }

    /// The overlay is chrome, not content: never take clicks from the session.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Corner readout for encoding, frame cost and bandwidth. Off by default,
/// toggled with ^⌥⌘I — useful for deciding between --quality and --lossless on
/// a given link.
final class StatsHUD: NSView {
    private let label = NSTextField(labelWithString: "")
    private var lastSampleAt = Date()
    private var lastBytes: UInt64 = 0
    private var throughput: Double = 0

    init() {
        super.init(frame: NSRect(x: 12, y: 12, width: 300, height: 54))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = 6
        autoresizingMask = [.maxXMargin, .maxYMargin]

        label.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        label.textColor = .white
        label.maximumNumberOfLines = 3
        label.frame = NSRect(x: 8, y: 6, width: 284, height: 42)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(stats: SessionStats, size: (Int, Int)) {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSampleAt)
        if elapsed >= 0.5 {
            let delta = Double(stats.bytesReceived &- lastBytes)
            throughput = delta / elapsed
            lastBytes = stats.bytesReceived
            lastSampleAt = now
        }
        label.stringValue = String(
            format: "%d×%d  %@\n%.1f ms/frame   %@/s\n%llu frames   %@ total",
            size.0, size.1, stats.encodingName,
            stats.lastFrameMilliseconds,
            ByteCountFormatter.string(fromByteCount: Int64(throughput), countStyle: .binary),
            stats.framesDecoded,
            ByteCountFormatter.string(fromByteCount: Int64(stats.bytesReceived), countStyle: .binary))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
