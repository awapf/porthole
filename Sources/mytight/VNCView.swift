import AppKit
import Metal
import QuartzCore
import MyTightCore

/// Renders the remote framebuffer with Metal and forwards input.
///
/// Dirty rectangles go straight into a single BGRA texture, which a fullscreen
/// triangle samples — the remote pixels never get repacked between the socket
/// and the screen.
final class VNCView: NSView {
    weak var client: RFBClient?
    var commandMapping: CommandKeyMapping = .superKey
    /// Scale the remote to fill the window rather than mapping 1:1.
    var scaleToFit = true
    var onClipboardFromRemote: ((String) -> Void)?
    /// Returns true when the event was a client hotkey and must not reach the
    /// remote. Needed because Command is forwarded as Super, so the escape
    /// hatches have to live on a chord sway will never claim.
    var hotkeyHandler: ((NSEvent) -> Bool)?

    private var renderer: FramebufferRenderer!
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    /// Mirrors the renderer's texture size, for input coordinate mapping.
    private var remoteSize: (width: Int, height: Int)?

    private var pendingRects: [RFBRect] = []
    private var needsPresent = false
    private var displayLink: CADisplayLink?

    private var buttonMask: PointerButtons = []
    private var lastModifiers: NSEvent.ModifierFlags = []
    private var pressedKeysyms: [UInt16: UInt32] = [:]
    private var remoteCursor: NSCursor?
    private var cursorHidden = false
    private var lastPointer: (x: Int, y: Int, mask: UInt8)?
    private var scrollAccumulatorY: CGFloat = 0
    private var scrollAccumulatorX: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupMetal()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        // Present as soon as a frame is ready rather than waiting for vsync to
        // queue it; this is the difference between a session that feels remote
        // and one that feels local.
        layer.displaySyncEnabled = true
        return layer
    }

    private func setupMetal() {
        do {
            renderer = try FramebufferRenderer()
        } catch {
            fatalError("\(describe(error))")
        }
        renderer.scaleToFit = scaleToFit
        metalLayer.device = renderer.device
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            displayLink?.invalidate()
            displayLink = nil
            return
        }
        updateDrawableSize()
        // Coalescing uploads onto the display refresh keeps a burst of small
        // updates from turning into a burst of presents.
        let link = displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        addTrackingArea()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
        addTrackingArea()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        needsPresent = true
    }

    // MARK: - Framebuffer uploads

    func framebufferDidResize() {
        renderer.invalidateTexture()
        remoteSize = nil
        pendingRects.removeAll()
        needsPresent = true
    }

    func enqueue(dirty rects: [RFBRect]) {
        pendingRects.append(contentsOf: rects)
        needsPresent = true
    }

    @objc private func tick() {
        guard needsPresent else { return }
        needsPresent = false
        uploadPending()
        render()
    }

    private func uploadPending() {
        guard let client else { return }
        renderer.scaleToFit = scaleToFit
        renderer.upload(from: client.framebuffer, rects: pendingRects)
        pendingRects.removeAll(keepingCapacity: true)
        if let texture = renderer.texture {
            remoteSize = (texture.width, texture.height)
        }
    }

    private func render() {
        guard metalLayer.drawableSize.width > 0, let drawable = metalLayer.nextDrawable() else { return }
        renderer.render(to: drawable.texture, present: drawable)
    }

    /// The rect, in view points, that the remote image actually occupies.
    private var contentRect: NSRect {
        guard let remoteSize else { return bounds }
        guard scaleToFit else {
            let scale = window?.backingScaleFactor ?? 2
            return NSRect(x: 0, y: 0,
                          width: CGFloat(remoteSize.width) / scale,
                          height: CGFloat(remoteSize.height) / scale)
        }
        let scale = min(bounds.width / CGFloat(remoteSize.width),
                        bounds.height / CGFloat(remoteSize.height))
        let width = CGFloat(remoteSize.width) * scale
        let height = CGFloat(remoteSize.height) * scale
        return NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2,
                      width: width, height: height)
    }

    // MARK: - Cursor

    func applyRemoteCursor(_ cursor: CursorImage?) {
        guard let cursor, cursor.width > 0, cursor.height > 0 else {
            remoteCursor = nil
            window?.invalidateCursorRects(for: self)
            return
        }
        var pixels = cursor.pixels
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = pixels.withUnsafeMutableBytes({ raw in
            CGContext(data: raw.baseAddress, width: cursor.width, height: cursor.height,
                      bitsPerComponent: 8, bytesPerRow: cursor.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo)
        }), let image = context.makeImage() else { return }

        let size = NSSize(width: cursor.width, height: cursor.height)
        let nsImage = NSImage(cgImage: image, size: size)
        remoteCursor = NSCursor(image: nsImage,
                                hotSpot: NSPoint(x: cursor.hotX, y: cursor.hotY))
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        if let remoteCursor {
            addCursorRect(bounds, cursor: remoteCursor)
        } else {
            super.resetCursorRects()
        }
    }

    // MARK: - Input plumbing

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func addTrackingArea() {
        trackingAreas.forEach(removeTrackingArea)
        // No .mouseMoved here: the window has acceptsMouseMovedEvents set, and
        // having both delivers every motion twice. The tracking area is kept
        // only for enter/exit, which drives cursor management.
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    /// View point to remote pixel. AppKit's origin is bottom-left; the
    /// framebuffer's is top-left.
    private func remotePoint(_ event: NSEvent) -> (Int, Int)? {
        guard let remoteSize else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let content = contentRect
        guard content.width > 0, content.height > 0 else { return nil }
        let normalisedX = (point.x - content.minX) / content.width
        let normalisedY = (point.y - content.minY) / content.height
        let x = Int((normalisedX * CGFloat(remoteSize.width)).rounded())
        let y = Int(((1 - normalisedY) * CGFloat(remoteSize.height)).rounded())
        return (min(max(x, 0), remoteSize.width - 1), min(max(y, 0), remoteSize.height - 1))
    }

    private func sendPointer(_ event: NSEvent) {
        guard let (x, y) = remotePoint(event) else { return }
        // Repeated identical positions carry no information; several AppKit
        // events can map to the same remote pixel, especially on a Retina
        // display driving a lower-resolution desktop.
        let state = (x: x, y: y, mask: buttonMask.rawValue)
        if let last = lastPointer, last == state { return }
        lastPointer = state
        client?.sendPointer(x: x, y: y, buttonMask: buttonMask.rawValue)
    }

    override func mouseDown(with event: NSEvent) { buttonMask.insert(.left); sendPointer(event) }
    override func mouseUp(with event: NSEvent) { buttonMask.remove(.left); sendPointer(event) }
    override func rightMouseDown(with event: NSEvent) { buttonMask.insert(.right); sendPointer(event) }
    override func rightMouseUp(with event: NSEvent) { buttonMask.remove(.right); sendPointer(event) }
    override func otherMouseDown(with event: NSEvent) { buttonMask.insert(.middle); sendPointer(event) }
    override func otherMouseUp(with event: NSEvent) { buttonMask.remove(.middle); sendPointer(event) }
    override func mouseMoved(with event: NSEvent) { sendPointer(event) }
    override func mouseDragged(with event: NSEvent) { sendPointer(event) }
    override func rightMouseDragged(with event: NSEvent) { sendPointer(event) }
    override func otherMouseDragged(with event: NSEvent) { sendPointer(event) }

    /// RFB has no scroll axis: wheel motion is a click of buttons 4-7. Trackpad
    /// deltas are accumulated so one notch of remote scroll needs one notch of
    /// physical scroll rather than firing on every pixel of momentum.
    override func scrollWheel(with event: NSEvent) {
        guard let (x, y) = remotePoint(event) else { return }
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 12 : 1
        scrollAccumulatorY += event.scrollingDeltaY
        scrollAccumulatorX += event.scrollingDeltaX

        while abs(scrollAccumulatorY) >= step {
            let up = scrollAccumulatorY > 0
            scrollAccumulatorY -= up ? step : -step
            click(up ? .scrollUp : .scrollDown, at: (x, y))
        }
        while abs(scrollAccumulatorX) >= step {
            let left = scrollAccumulatorX > 0
            scrollAccumulatorX -= left ? step : -step
            click(left ? .scrollLeft : .scrollRight, at: (x, y))
        }
    }

    private func click(_ button: PointerButtons, at point: (Int, Int)) {
        client?.sendPointer(x: point.0, y: point.1, buttonMask: buttonMask.union(button).rawValue)
        client?.sendPointer(x: point.0, y: point.1, buttonMask: buttonMask.rawValue)
    }

    override func keyDown(with event: NSEvent) {
        if hotkeyHandler?(event) == true { return }
        guard let keysym = keysym(for: event) else { return }
        pressedKeysyms[event.keyCode] = keysym
        client?.sendKey(keysym: keysym, down: true)
    }

    override func keyUp(with event: NSEvent) {
        // Release the keysym we pressed, not the one the current modifier state
        // implies — otherwise releasing Shift before a letter strands it down.
        let keysym = pressedKeysyms.removeValue(forKey: event.keyCode) ?? keysym(for: event)
        guard let keysym else { return }
        client?.sendKey(keysym: keysym, down: false)
    }

    private func keysym(for event: NSEvent) -> UInt32? {
        if let special = MacKeyCode.specialKeysym(for: event.keyCode) { return special }
        // charactersIgnoringModifiers keeps Ctrl-C as 'c' rather than U+0003,
        // which is what the remote's own xkb layer expects.
        let source = event.modifierFlags.contains(.shift)
            ? (event.charactersIgnoringModifiers ?? "")
            : (event.charactersIgnoringModifiers?.lowercased() ?? "")
        guard let scalar = source.unicodeScalars.first else { return nil }
        return Keysym.fromUnicode(scalar)
    }

    /// Modifier presses arrive as state changes, not key events, so diff the
    /// flags and synthesise the transitions.
    override func flagsChanged(with event: NSEvent) {
        guard let keysym = MacKeyCode.modifierKeysym(for: event.keyCode, commandMapping: commandMapping)
        else { return }
        let flag: NSEvent.ModifierFlags
        switch event.keyCode {
        case 0x38, 0x3C: flag = .shift
        case 0x3B, 0x3E: flag = .control
        case 0x3A, 0x3D: flag = .option
        case 0x37, 0x36: flag = .command
        case 0x39: flag = .capsLock
        default: return
        }
        let isDown = event.modifierFlags.contains(flag) && !lastModifiers.contains(flag)
        let isUp = !event.modifierFlags.contains(flag) && lastModifiers.contains(flag)
        if isDown { client?.sendKey(keysym: keysym, down: true) }
        if isUp { client?.sendKey(keysym: keysym, down: false) }
        lastModifiers = event.modifierFlags
    }

    /// Releases every key we believe is held. Called when focus leaves, so a
    /// modifier held during a window switch does not stick on the remote.
    func releaseAllKeys() {
        for (_, keysym) in pressedKeysyms { client?.sendKey(keysym: keysym, down: false) }
        pressedKeysyms.removeAll()
        for keysym in [Keysym.shiftL, Keysym.shiftR, Keysym.controlL, Keysym.controlR,
                       Keysym.altL, Keysym.altR, Keysym.superL, Keysym.superR] {
            client?.sendKey(keysym: keysym, down: false)
        }
        lastModifiers = []
        buttonMask = []
        lastPointer = nil
    }
}
