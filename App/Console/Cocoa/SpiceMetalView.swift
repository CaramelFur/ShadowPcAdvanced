import AppKit
import Carbon.HIToolbox
import MetalKit

/// The guest screen in an MTKView (drawn by CocoaSpice's CSMetalRenderer) and
/// the Mac's keyboard and mouse turned into SPICE input.
///
/// Input capture follows UTM's VMMetalView (Apache-2.0, © osy): "captured"
/// means the pointer is pinned and hidden, the system's hot keys are switched
/// off so ⌘Tab, ⌘Space and friends reach the guest, and every key goes to the
/// guest. ⌃⌥ toggles it; losing focus always ends it.
///
/// Not captured: keys still reach the guest while this view has focus, but ⌘
/// stays with the Mac, and the pointer only drives the guest in client
/// (absolute) mouse mode.
final class SpiceMetalView: MTKView {
    /// Set by the engine as channels come and go.
    weak var spiceInput: CSInput? { didSet { if spiceInput == nil { letGo() } else { syncCapsLock() } } }
    weak var spiceDisplay: CSDisplay? { didSet { needsLayout = true } }
    var renderer: CSMetalRenderer?
    var onCaptureChanged: ((Bool) -> Void)?
    /// Fullscreen drops the margin around the display.
    var bare = false { didSet { needsLayout = true } }

    private(set) var isCaptured = false
    private var pressedKeys = Set<UInt32>()
    /// Modifier key codes currently down *in the guest*.
    private var pressedModifiers = Set<Int>()
    private var commandTapPending = false
    private var captureChordArmed = true
    private var buttons = CSInputButton()
    /// Captured + client mouse mode: the Mac pointer is pinned, so the guest
    /// position is integrated from deltas.
    private var virtualPointer = CGPoint.zero
    private var cursorHidden = false
    private var mouseInside = false
    private var keyMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        preferredFramesPerSecond = 60
        autoResizeDrawable = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if isCaptured {
            CGAssociateMouseAndMouseCursorPosition(1)
            CGSSetGlobalHotKeyOperatingMode(CGSMainConnectionID(), .enable)
        }
        if cursorHidden { NSCursor.unhide() }
    }

    override var acceptsFirstResponder: Bool { true }
    /// The click that activates the window also lands in the guest.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return letGo() }
        let center = NotificationCenter.default
        // Key-up events stop arriving once the window or app loses focus, so
        // nothing may stay held or captured past that point.
        for name in [NSWindow.didResignKeyNotification, NSWindow.didResignMainNotification, NSWindow.willBeginSheetNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.letGo() })
        }
        for name in [NSApplication.didResignActiveNotification, NSApplication.willTerminateNotification, NSApplication.didHideNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.letGo() })
        }
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            self?.syncCapsLock()
            self?.updateCursorVisibility()
        })
        // The view is never paused: CocoaSpice's SPICE thread waits for draw
        // callbacks (the renderer skips the GPU work when nothing changed).
    }

    /// Release every held key, the pointer and the keyboard grab.
    func letGo() {
        releaseAllKeys()
        release()
        updateCursorVisibility()
    }

    // MARK: - geometry

    private var guestSize: CGSize { spiceDisplay?.displaySize ?? .zero }

    /// Where the guest screen sits inside the view, in points.
    private var screenRect: CGRect {
        let guest = guestSize
        guard guest.width > 0, guest.height > 0 else { return .zero }
        let inset: CGFloat = bare ? 0 : 12
        let avail = bounds.insetBy(dx: inset, dy: inset)
        guard avail.width > 0, avail.height > 0 else { return .zero }
        let scale = min(avail.width / guest.width, avail.height / guest.height)
        let size = CGSize(width: guest.width * scale, height: guest.height * scale)
        return CGRect(x: avail.midX - size.width / 2, y: avail.midY - size.height / 2, width: size.width, height: size.height)
    }

    override func layout() {
        super.layout()
        updateViewport()
    }

    /// The renderer centres the guest at `viewportScale` drawable pixels per guest pixel.
    func updateViewport() {
        let guest = guestSize
        guard guest.width > 0, let renderer else { return }
        let backing = window?.backingScaleFactor ?? 1
        renderer.viewportOrigin = .zero
        renderer.viewportScale = screenRect.width * backing / guest.width
        updateCursorVisibility()
    }

    private func guestPoint(_ event: NSEvent) -> CGPoint? {
        let rect = screenRect, guest = guestSize
        guard rect.width > 0 else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let x = (p.x - rect.minX) / rect.width * guest.width
        let y = (rect.maxY - p.y) / rect.height * guest.height
        return CGPoint(x: min(max(x, 0), guest.width - 1), y: min(max(y, 0), guest.height - 1))
    }

    // MARK: - capture

    func toggleCapture() { if isCaptured { release() } else { capture() } }

    func capture() {
        guard !isCaptured, spiceInput != nil, let window, window.isKeyWindow, window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        window.makeFirstResponder(self)
        isCaptured = true
        virtualPointer = lastGuestPoint ?? CGPoint(x: guestSize.width / 2, y: guestSize.height / 2)
        CGAssociateMouseAndMouseCursorPosition(0)
        if let centre = screenCentre { CGWarpMouseCursorPosition(centre) }
        CGSSetGlobalHotKeyOperatingMode(CGSMainConnectionID(), .disable)
        // While captured every key belongs to the guest, including the ⌘
        // combinations AppKit would turn into menu commands and the ⌘ key-ups
        // it never delivers to views.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, self.isCaptured, event.window === self.window else { return event }
            switch event.type {
            case .keyDown: self.keyDown(with: event)
            case .keyUp: self.keyUp(with: event)
            default: self.flagsChanged(with: event) // ⌃⌥ must get through whoever has focus
            }
            return nil
        }
        showHint("Keyboard and mouse captured — press ⌃⌥ to release")
        updateCursorVisibility()
        syncCapsLock()
        onCaptureChanged?(true)
    }

    func release() {
        guard isCaptured else { return }
        isCaptured = false
        CGAssociateMouseAndMouseCursorPosition(1)
        CGSSetGlobalHotKeyOperatingMode(CGSMainConnectionID(), .enable)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        releaseButtons()
        // ⌘ was the guest's while captured; it must not stay down there.
        releaseAllKeys()
        updateCursorVisibility()
        onCaptureChanged?(false)
    }

    /// Centre of the view in CoreGraphics' global (top-left) coordinates.
    private var screenCentre: CGPoint? {
        guard let window, let primary = NSScreen.screens.first else { return nil }
        let inWindow = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil)
        let onScreen = window.convertPoint(toScreen: inWindow)
        return CGPoint(x: onScreen.x, y: primary.frame.maxY - onScreen.y)
    }

    // MARK: - hint

    private var hintLabel: NSTextField?
    private var hintGeneration = 0

    /// A short-lived banner; in fullscreen there is no toolbar to say it.
    private func showHint(_ text: String) {
        hintLabel?.removeFromSuperview()
        let label = NSTextField(labelWithString: "  \(text)  ")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        label.layer?.cornerRadius = 8
        label.sizeToFit()
        label.frame.size.height += 10
        label.frame.origin = CGPoint(x: bounds.midX - label.frame.width / 2, y: bounds.maxY - label.frame.height - 24)
        label.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        addSubview(label)
        hintLabel = label
        hintGeneration += 1
        let generation = hintGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.hintGeneration == generation else { return }
            self.hintLabel?.removeFromSuperview()
            self.hintLabel = nil
        }
    }

    // MARK: - cursor

    private var lastGuestPoint: CGPoint?

    /// The guest draws its own pointer (in the Metal renderer); the Mac's is
    /// hidden whenever that one is what the user should be looking at.
    private func updateCursorVisibility() {
        let guestCursorShown = spiceDisplay?.cursor?.isVisible ?? false
        let hide = isCaptured || (mouseInside && window?.isKeyWindow == true && guestCursorShown && spiceInput?.serverModeCursor == false)
        if hide, !cursorHidden {
            NSCursor.hide()
            cursorHidden = true
        } else if !hide, cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        mouseInside = true
        updateCursorVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        mouseInside = false
        updateCursorVisibility()
    }

    // MARK: - keyboard

    /// On ISO keyboards macOS swaps these two key codes (as Chromium and UTM handle it).
    private func layoutKeyCode(_ keyCode: UInt16) -> UInt16 {
        guard KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO else { return keyCode }
        switch Int(keyCode) {
        case kVK_ISO_Section: return UInt16(kVK_ANSI_Grave)
        case kVK_ANSI_Grave: return UInt16(kVK_ISO_Section)
        default: return keyCode
        }
    }

    private func send(_ scancode: UInt32, down: Bool) {
        spiceInput?.send(down ? .press : .release, code: Int32(scancode))
    }

    override func keyDown(with event: NSEvent) {
        commandTapPending = false
        guard let code = MacKeyMap.scancode(forKeyCode: layoutKeyCode(event.keyCode)) else { return }
        // Auto-repeat is passed on as repeated presses, like a PS/2 keyboard does.
        pressedKeys.insert(code)
        send(code, down: true)
    }

    override func keyUp(with event: NSEvent) {
        guard let code = MacKeyMap.scancode(forKeyCode: layoutKeyCode(event.keyCode)), pressedKeys.remove(code) != nil else { return }
        send(code, down: false)
    }

    /// Per-key (left/right) modifier bits, from IOLLEvent.h.
    private static let deviceMasks: [(keyCode: Int, mask: UInt)] = [
        (kVK_Control, 0x0001), (kVK_Shift, 0x0002), (kVK_RightShift, 0x0004), (kVK_Command, 0x0008), (kVK_RightCommand, 0x0010),
        (kVK_Option, 0x0020), (kVK_RightOption, 0x0040), (kVK_RightControl, 0x2000),
    ]

    override func flagsChanged(with event: NSEvent) {
        let flags = event.modifierFlags

        // ⌃⌥ together toggles the capture (they still reach the guest). Armed
        // again only once one of them is up, so holding them toggles once.
        let chord = flags.contains(.control) && flags.contains(.option)
        if chord, captureChordArmed {
            captureChordArmed = false
            toggleCapture()
        } else if !chord {
            captureChordArmed = true
        }

        if Int(event.keyCode) == kVK_CapsLock { syncCapsLock(flags, force: true) }

        // The whole modifier state is compared with what the guest holds, not
        // just the key in this event: a missed event heals on the next one.
        for (keyCode, mask) in Self.deviceMasks {
            let down = flags.rawValue & mask != 0
            let isCommand = keyCode == kVK_Command || keyCode == kVK_RightCommand
            guard let code = MacKeyMap.scancode(forKeyCode: UInt16(keyCode)) else { continue }

            if isCommand, !isCaptured {
                // ⌘ stays with the Mac (⌘Tab, ⌘Q, ⌘W…). Only a clean tap becomes a Windows-key tap.
                if pressedModifiers.remove(keyCode) != nil { send(code, down: false) }
                guard Int(event.keyCode) == keyCode else { continue }
                if down {
                    commandTapPending = true
                } else if commandTapPending {
                    commandTapPending = false
                    send(code, down: true)
                    send(code, down: false)
                }
                continue
            }
            guard down != pressedModifiers.contains(keyCode) else { continue }
            if !isCommand { commandTapPending = false }
            if down { pressedModifiers.insert(keyCode) } else { pressedModifiers.remove(keyCode) }
            send(code, down: down)
        }
    }

    /// Not captured: ⌘-shortcuts stay with the Mac (menus, ⌃⌘F to leave
    /// fullscreen). Captured: the key monitor has already taken them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        commandTapPending = false
        if event.modifierFlags.contains(.command) { return super.performKeyEquivalent(with: event) }
        return false
    }

    /// The guest's Caps Lock follows the Mac's instead of being toggled blindly.
    /// `force`: the key itself was pressed. A guest that never reports its
    /// LEDs (firmware screens) then still sees one toggle per press, and is not
    /// "corrected" again on every other modifier event.
    private func syncCapsLock(_ flags: NSEvent.ModifierFlags? = nil, force: Bool = false) {
        guard let spiceInput else { return }
        let on = (flags ?? NSEvent.modifierFlags).contains(.capsLock)
        var locks = spiceInput.keyLock
        guard force || locks.contains(.caps) != on else { return }
        if on { locks.insert(.caps) } else { locks.remove(.caps) }
        spiceInput.keyLock = locks
    }

    /// Never leave a key stuck down in the guest.
    func releaseAllKeys() {
        commandTapPending = false
        for code in pressedKeys { send(code, down: false) }
        pressedKeys.removeAll()
        for keyCode in pressedModifiers {
            if let code = MacKeyMap.scancode(forKeyCode: UInt16(keyCode)) { send(code, down: false) }
        }
        pressedModifiers.removeAll()
        // …including anything sent from elsewhere (toolbar, paste).
        spiceInput?.releaseKeys()
    }

    override func becomeFirstResponder() -> Bool {
        // Modifiers already held when focus arrives would otherwise be missed;
        // the next flagsChanged brings the guest in line.
        syncCapsLock()
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        letGo()
        return super.resignFirstResponder()
    }

    // MARK: - mouse

    private func releaseButtons() {
        guard let spiceInput, !buttons.isEmpty else { return buttons = [] }
        for button in [CSInputButton.left, .middle, .right, .side, .extra] where buttons.contains(button) {
            buttons.remove(button)
            spiceInput.sendMouseButton(button, mask: buttons, pressed: false)
        }
    }

    private func moved(_ event: NSEvent) {
        guard let spiceInput else { return }
        let server = spiceInput.serverModeCursor
        if isCaptured {
            if server {
                // NSEvent deltas are top-left oriented (deltaY > 0 = down), as SPICE wants.
                if event.deltaX != 0 || event.deltaY != 0 {
                    spiceInput.sendMouseMotion(buttons, relativePoint: CGPoint(x: event.deltaX, y: event.deltaY))
                }
            } else {
                // Same speed as the Mac pointer would have over the scaled screen.
                let rect = screenRect, guest = guestSize
                guard rect.width > 0 else { return }
                let perPoint = guest.width / rect.width
                virtualPointer.x = min(max(virtualPointer.x + event.deltaX * perPoint, 0), guest.width - 1)
                virtualPointer.y = min(max(virtualPointer.y + event.deltaY * perPoint, 0), guest.height - 1)
                position(virtualPointer)
            }
        } else if !server, let p = guestPoint(event) {
            position(p)
        }
        updateCursorVisibility()
    }

    private func position(_ p: CGPoint) {
        lastGuestPoint = p
        spiceInput?.sendMousePosition(buttons, absolutePoint: p)
        spiceDisplay?.cursor?.move(to: p) // the renderer draws the guest cursor there
    }

    private func button(_ event: NSEvent, _ button: CSInputButton, down: Bool) {
        guard let spiceInput else { return }
        if down {
            window?.makeFirstResponder(self)
            if spiceInput.serverModeCursor, !isCaptured {
                // Relative mode needs the pointer pinned: the first click only captures.
                capture()
                return
            }
        }
        // A release without its press (e.g. the capturing click) is not the guest's business.
        if !down, !buttons.contains(button) { return }
        moved(event)
        if down { buttons.insert(button) } else { buttons.remove(button) }
        spiceInput.sendMouseButton(button, mask: buttons, pressed: down)
    }

    private func otherButton(_ event: NSEvent) -> CSInputButton? {
        switch event.buttonNumber {
        case 2: return .middle
        case 3: return .side
        case 4: return .extra
        default: return nil
        }
    }

    override func mouseMoved(with event: NSEvent) { moved(event) }
    override func mouseDragged(with event: NSEvent) { moved(event) }
    override func rightMouseDragged(with event: NSEvent) { moved(event) }
    override func otherMouseDragged(with event: NSEvent) { moved(event) }
    override func mouseDown(with event: NSEvent) { button(event, .left, down: true) }
    override func mouseUp(with event: NSEvent) { button(event, .left, down: false) }
    override func rightMouseDown(with event: NSEvent) { button(event, .right, down: true) }
    override func rightMouseUp(with event: NSEvent) { button(event, .right, down: false) }
    override func otherMouseDown(with event: NSEvent) { if let b = otherButton(event) { button(event, b, down: true) } }
    override func otherMouseUp(with event: NSEvent) { if let b = otherButton(event) { button(event, b, down: false) } }

    private var scrollAccumulator: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        guard let spiceInput, event.scrollingDeltaY != 0, !spiceInput.serverModeCursor || isCaptured else { return }
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
        for _ in 0..<min(abs(clicks), 5) {
            spiceInput.sendMouseScroll(clicks > 0 ? .up : .down, buttonMask: buttons, dy: 0)
        }
    }
}
