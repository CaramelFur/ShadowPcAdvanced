import AppKit
import Carbon.HIToolbox

@MainActor
protocol SpiceDisplayInput: AnyObject {
    func key(_ scancode: UInt32, down: Bool)
    func mousePosition(x: Int, y: Int, buttons: Int)
    func mouseMotion(dx: Int, dy: Int, buttons: Int)
    func mouseButton(_ button: Int, down: Bool, buttons: Int)
    /// The pointer was captured for / released from relative-motion mode.
    func mouseGrabChanged(_ grabbed: Bool)
}

/// Shows the guest framebuffer (aspect-fit) and turns AppKit events into SPICE
/// input.
///
/// Input rules, so the Mac never ends up fighting the guest:
/// - Keys reach the guest only while this view is first responder of the key
///   window; everything held is released the moment that stops being true.
/// - ⌘ belongs to the Mac. ⌘-shortcuts never reach the guest; a lone ⌘ tap is
///   sent as one Windows-key tap on release.
/// - The pointer is captured only in server (relative) mouse mode, on click,
///   and let go with ⌃⌥, on focus loss, or when the mode changes.
final class SpiceDisplayView: NSView {
    weak var input: SpiceDisplayInput?

    private let screenLayer = CALayer()
    private let cursorLayer = CALayer()
    private var guestSize = CGSize.zero
    private var guestCursor: NSCursor?
    private var cursorHotspot = CGPoint.zero
    private var cursorPosition = CGPoint.zero
    /// Server mode: the guest moves its own pointer from relative motion.
    var serverMouseMode = false {
        didSet {
            if !serverMouseMode { releaseMouse() }
            updateCursorPresentation()
        }
    }
    /// Fullscreen drops the margin around the display.
    var bare = false { didSet { needsLayout = true } }

    private var pressedKeys = Set<UInt32>()
    /// Modifier key codes currently down *in the guest*.
    private var pressedModifiers = Set<UInt16>()
    private var commandTapPending = false
    private var buttonMask = 0
    private(set) var mouseGrabbed = false
    private var observers: [NSObjectProtocol] = []

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

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if mouseGrabbed {
            CGAssociateMouseAndMouseCursorPosition(1)
            NSCursor.unhide()
        }
    }

    override var acceptsFirstResponder: Bool { true }
    /// The click that activates the window also lands in the guest.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // Deliberately not flipped: layer geometry stays bottom-left and the guest's
    // top-left coordinates are converted by hand below.

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return letGo() }
        let center = NotificationCenter.default
        // Key-up events stop arriving once the window or app loses focus, so
        // nothing may stay held (or captured) past that point.
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.letGo() })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.letGo() })
    }

    /// Release every held key and the pointer.
    func letGo() {
        releaseAllKeys()
        releaseMouse()
    }

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
        commandTapPending = false
        guard let code = MacKeyMap.scancode(forKeyCode: event.keyCode) else { return }
        pressedKeys.insert(code)
        input?.key(code, down: true)
    }

    override func keyUp(with event: NSEvent) {
        guard let code = MacKeyMap.scancode(forKeyCode: event.keyCode), pressedKeys.remove(code) != nil else { return }
        input?.key(code, down: false)
    }

    /// Per-key (left/right) modifier bits, from IOLLEvent.h. Reading the real
    /// state beats toggling: a missed event can't invert a key for good.
    private static let deviceMasks: [Int: UInt] = [
        kVK_Control: 0x0001, kVK_Shift: 0x0002, kVK_RightShift: 0x0004, kVK_Command: 0x0008, kVK_RightCommand: 0x0010,
        kVK_Option: 0x0020, kVK_RightOption: 0x0040, kVK_RightControl: 0x2000,
    ]

    override func flagsChanged(with event: NSEvent) {
        let keyCode = Int(event.keyCode)
        let flags = event.modifierFlags

        // ⌃⌥ together lets the pointer go (they still reach the guest).
        if mouseGrabbed, flags.contains(.control), flags.contains(.option) { releaseMouse() }

        if keyCode == kVK_CapsLock {
            // One event per toggle; the guest wants a full press.
            guard let code = MacKeyMap.scancode(forKeyCode: event.keyCode) else { return }
            input?.key(code, down: true)
            input?.key(code, down: false)
            return
        }
        guard let mask = Self.deviceMasks[keyCode], let code = MacKeyMap.scancode(forKeyCode: event.keyCode) else { return }
        let down = flags.rawValue & mask != 0

        if keyCode == kVK_Command || keyCode == kVK_RightCommand {
            // ⌘ stays with the Mac (⌘Tab, ⌘Q, ⌘W…). Only a clean tap becomes a Windows-key tap.
            if down {
                commandTapPending = true
            } else if commandTapPending {
                commandTapPending = false
                input?.key(code, down: true)
                input?.key(code, down: false)
            }
            return
        }
        commandTapPending = false
        guard down != pressedModifiers.contains(event.keyCode) else { return }
        if down { pressedModifiers.insert(event.keyCode) } else { pressedModifiers.remove(event.keyCode) }
        input?.key(code, down: down)
    }

    /// ⌘-shortcuts stay with the Mac (menus, ⌃⌘F to leave fullscreen).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        commandTapPending = false
        if event.modifierFlags.contains(.command) { return super.performKeyEquivalent(with: event) }
        return false
    }

    /// Never leave a key stuck down in the guest.
    func releaseAllKeys() {
        commandTapPending = false
        for code in pressedKeys { input?.key(code, down: false) }
        pressedKeys.removeAll()
        for keyCode in pressedModifiers {
            if let code = MacKeyMap.scancode(forKeyCode: keyCode) { input?.key(code, down: false) }
        }
        pressedModifiers.removeAll()
    }

    override func becomeFirstResponder() -> Bool {
        // Modifiers already held when focus arrives would otherwise be missed.
        pressedModifiers.removeAll()
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        letGo()
        return super.resignFirstResponder()
    }

    // MARK: - mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    /// Server mode needs relative motion, which only works with the Mac pointer
    /// pinned in place.
    private func grabMouse() {
        guard serverMouseMode, !mouseGrabbed, window?.isKeyWindow == true else { return }
        mouseGrabbed = true
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
        input?.mouseGrabChanged(true)
    }

    func releaseMouse() {
        guard mouseGrabbed else { return }
        mouseGrabbed = false
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        if buttonMask != 0 {
            for (button, mask) in [(1, 1), (2, 2), (3, 4)] where buttonMask & mask != 0 {
                buttonMask &= ~mask
                input?.mouseButton(button, down: false, buttons: buttonMask)
            }
        }
        input?.mouseGrabChanged(false)
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
            // Only while captured; otherwise the Mac pointer is just passing over.
            guard mouseGrabbed else { return }
            // NSEvent deltas are already top-left oriented (deltaY > 0 = down).
            let dx = Int(event.deltaX.rounded()), dy = Int(event.deltaY.rounded())
            if dx != 0 || dy != 0 { input?.mouseMotion(dx: dx, dy: dy, buttons: buttonMask) }
        } else if let p = guestPoint(event) {
            input?.mousePosition(x: p.x, y: p.y, buttons: buttonMask)
        }
    }

    private func button(_ event: NSEvent, _ button: Int, mask: Int, down: Bool) {
        if down {
            window?.makeFirstResponder(self)
            if serverMouseMode, !mouseGrabbed {
                // The first click only captures the pointer.
                grabMouse()
                return
            }
        }
        // A release without its press (e.g. the capturing click) is not the guest's business.
        if !down, buttonMask & mask == 0 { return }
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

    private var scrollAccumulator: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaY != 0, !serverMouseMode || mouseGrabbed else { return }
        // A trackpad reports a stream of small pixel deltas; turn every ~12 pt
        // into one wheel click instead of one click per event.
        var clicks = 0
        if event.hasPreciseScrollingDeltas {
            scrollAccumulator += event.scrollingDeltaY
            clicks = Int(scrollAccumulator / 12)
            scrollAccumulator -= CGFloat(clicks) * 12
        } else {
            clicks = event.scrollingDeltaY > 0 ? 1 : -1
        }
        let wheel = clicks > 0 ? 4 : 5 // up : down
        for _ in 0..<min(abs(clicks), 5) {
            input?.mouseButton(wheel, down: true, buttons: buttonMask)
            input?.mouseButton(wheel, down: false, buttons: buttonMask)
        }
    }
}
