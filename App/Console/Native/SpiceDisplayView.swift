import AppKit
import Carbon.HIToolbox

@MainActor
protocol SpiceDisplayInput: AnyObject {
    func key(_ scancode: UInt32, down: Bool)
    func mousePosition(x: Int, y: Int, buttons: Int)
    func mouseMotion(dx: Int, dy: Int, buttons: Int)
    func mouseButton(_ button: Int, down: Bool, buttons: Int)
}

/// Shows the guest framebuffer (aspect-fit) and turns AppKit events into SPICE
/// input.
final class SpiceDisplayView: NSView {
    weak var input: SpiceDisplayInput?

    private let screenLayer = CALayer()
    private let cursorLayer = CALayer()
    private var guestSize = CGSize.zero
    private var guestCursor: NSCursor?
    private var cursorHotspot = CGPoint.zero
    private var cursorPosition = CGPoint.zero
    /// Server mode: the guest moves its own pointer from relative motion.
    var serverMouseMode = false { didSet { updateCursorPresentation() } }
    /// Fullscreen drops the margin around the display.
    var bare = false { didSet { needsLayout = true } }

    private var pressedKeys = Set<UInt32>()
    private var pressedModifiers = Set<UInt16>()
    private var buttonMask = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        screenLayer.contentsGravity = .resize
        screenLayer.isOpaque = true
        screenLayer.minificationFilter = .trilinear
        screenLayer.magnificationFilter = .linear
        screenLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        cursorLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        cursorLayer.isHidden = true
        layer?.addSublayer(screenLayer)
        screenLayer.addSublayer(cursorLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    // Deliberately not flipped: layer geometry stays bottom-left and the guest's
    // top-left coordinates are converted by hand below.

    // MARK: - display

    func present(surface: IOSurface?, size: CGSize) {
        if size != guestSize {
            guestSize = size
            needsLayout = true
        }
        // Re-assigning makes Core Animation pick up the surface's new pixels.
        screenLayer.contents = nil
        screenLayer.contents = surface
    }

    /// Where the guest screen sits inside the view.
    private var screenRect: CGRect {
        guard guestSize.width > 0, guestSize.height > 0 else { return .zero }
        let inset: CGFloat = bare ? 0 : 12
        let avail = bounds.insetBy(dx: inset, dy: inset)
        let scale = min(avail.width / guestSize.width, avail.height / guestSize.height)
        let size = CGSize(width: guestSize.width * scale, height: guestSize.height * scale)
        return CGRect(x: avail.midX - size.width / 2, y: avail.midY - size.height / 2, width: size.width, height: size.height)
    }

    override func layout() {
        super.layout()
        screenLayer.frame = screenRect
        layoutCursorLayer()
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - cursor

    /// Straight RGBA from the cursor channel; nil hides the pointer.
    func setGuestCursor(rgba: Data?, width: Int, height: Int, hotX: Int, hotY: Int) {
        guard let rgba, width > 0, height > 0, rgba.count >= width * height * 4,
              let provider = CGDataProvider(data: rgba as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              )
        else {
            guestCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)
            cursorLayer.contents = nil
            updateCursorPresentation()
            return
        }
        cursorHotspot = CGPoint(x: hotX, y: hotY)
        guestCursor = NSCursor(image: NSImage(cgImage: image, size: NSSize(width: width, height: height)), hotSpot: cursorHotspot)
        cursorLayer.contents = image
        cursorLayer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        updateCursorPresentation()
    }

    func moveGuestCursor(x: Int, y: Int) {
        cursorPosition = CGPoint(x: x, y: y)
        layoutCursorLayer()
    }

    private func layoutCursorLayer() {
        guard guestSize.width > 0 else { return }
        let scale = screenRect.width / guestSize.width
        // Anchor at the image's top-left; guest y grows downwards.
        cursorLayer.anchorPoint = CGPoint(x: 0, y: 1)
        cursorLayer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        cursorLayer.position = CGPoint(
            x: (cursorPosition.x - cursorHotspot.x) * scale,
            y: screenRect.height - (cursorPosition.y - cursorHotspot.y) * scale
        )
    }

    private func updateCursorPresentation() {
        // Client mode: the Mac pointer wears the guest's cursor image.
        // Server mode: the guest reports where its pointer is; draw it there.
        cursorLayer.isHidden = !serverMouseMode || cursorLayer.contents == nil
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        guard !serverMouseMode, let guestCursor else { return }
        addCursorRect(screenRect, cursor: guestCursor)
    }

    // MARK: - keyboard

    override func keyDown(with event: NSEvent) {
        guard let code = MacKeyMap.scancode(forKeyCode: event.keyCode) else { return }
        pressedKeys.insert(code)
        input?.key(code, down: true)
    }

    override func keyUp(with event: NSEvent) {
        guard let code = MacKeyMap.scancode(forKeyCode: event.keyCode) else { return }
        pressedKeys.remove(code)
        input?.key(code, down: false)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let code = MacKeyMap.scancode(forKeyCode: event.keyCode) else { return }
        if Int(event.keyCode) == kVK_CapsLock {
            // One event per toggle; the guest wants a full press.
            input?.key(code, down: true)
            input?.key(code, down: false)
            return
        }
        let flag: NSEvent.ModifierFlags
        switch Int(event.keyCode) {
        case kVK_Shift, kVK_RightShift: flag = .shift
        case kVK_Control, kVK_RightControl: flag = .control
        case kVK_Option, kVK_RightOption: flag = .option
        case kVK_Command, kVK_RightCommand: flag = .command
        default: return
        }
        // With both sides of a pair held the flag alone is ambiguous, so track per key.
        let down = event.modifierFlags.contains(flag) && !pressedModifiers.contains(event.keyCode)
        if down { pressedModifiers.insert(event.keyCode) } else { pressedModifiers.remove(event.keyCode) }
        input?.key(code, down: down)
    }

    /// ⌘-shortcuts stay with the Mac (menus, ⌃⌘F to leave fullscreen).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) { return super.performKeyEquivalent(with: event) }
        return false
    }

    /// Never leave a key stuck down in the guest.
    func releaseAllKeys() {
        for code in pressedKeys { input?.key(code, down: false) }
        pressedKeys.removeAll()
        for keyCode in pressedModifiers {
            if let code = MacKeyMap.scancode(forKeyCode: keyCode) { input?.key(code, down: false) }
        }
        pressedModifiers.removeAll()
    }

    override func resignFirstResponder() -> Bool {
        releaseAllKeys()
        return super.resignFirstResponder()
    }

    // MARK: - mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    private func guestPoint(_ event: NSEvent) -> (x: Int, y: Int)? {
        let rect = screenRect
        guard rect.width > 0 else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let x = (p.x - rect.minX) / rect.width * guestSize.width
        let y = (rect.maxY - p.y) / rect.height * guestSize.height
        return (Int(min(max(x, 0), guestSize.width - 1)), Int(min(max(y, 0), guestSize.height - 1)))
    }

    private func moved(_ event: NSEvent) {
        if serverMouseMode {
            // NSEvent deltas are already top-left oriented (deltaY > 0 = down).
            let dx = Int(event.deltaX.rounded()), dy = Int(event.deltaY.rounded())
            if dx != 0 || dy != 0 { input?.mouseMotion(dx: dx, dy: dy, buttons: buttonMask) }
        } else if let p = guestPoint(event) {
            input?.mousePosition(x: p.x, y: p.y, buttons: buttonMask)
        }
    }

    private func button(_ event: NSEvent, _ button: Int, mask: Int, down: Bool) {
        if down { window?.makeFirstResponder(self) }
        moved(event)
        if down { buttonMask |= mask } else { buttonMask &= ~mask }
        input?.mouseButton(button, down: down, buttons: buttonMask)
    }

    override func mouseMoved(with event: NSEvent) { moved(event) }
    override func mouseDragged(with event: NSEvent) { moved(event) }
    override func rightMouseDragged(with event: NSEvent) { moved(event) }
    override func otherMouseDragged(with event: NSEvent) { moved(event) }
    override func mouseDown(with event: NSEvent) { button(event, 1, mask: 1, down: true) }
    override func mouseUp(with event: NSEvent) { button(event, 1, mask: 1, down: false) }
    override func rightMouseDown(with event: NSEvent) { button(event, 3, mask: 4, down: true) }
    override func rightMouseUp(with event: NSEvent) { button(event, 3, mask: 4, down: false) }
    override func otherMouseDown(with event: NSEvent) { button(event, 2, mask: 2, down: true) }
    override func otherMouseUp(with event: NSEvent) { button(event, 2, mask: 2, down: false) }

    override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaY != 0 else { return }
        let wheel = event.scrollingDeltaY > 0 ? 4 : 5 // up : down
        input?.mouseButton(wheel, down: true, buttons: buttonMask)
        input?.mouseButton(wheel, down: false, buttons: buttonMask)
    }
}
