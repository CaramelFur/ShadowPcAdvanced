import Foundation

/// The Mac keyboard's way into the guest, shared by both native engines. Two
/// things turn one keystroke into a doubled character on a remote SPICE
/// console, and both are dealt with here:
///
/// 1. **macOS auto-repeat.** A key held past "Delay until repeat" (as little as
///    225 ms, the shortest setting) produces repeat keyDowns. QEMU's PS/2
///    keyboard has no typematic of its own, so a repeated make code *is* a
///    repeat to the guest: a letter held a little long is typed twice. Mac
///    text fields hide this (the press-and-hold accent popup takes the
///    repeats), so it only ever shows in the console. Repeats are therefore
///    passed on only once the key has been down for `repeatDelay` — 500 ms, a
///    PC keyboard's default typematic delay — so holding Backspace or an arrow
///    still repeats in the guest.
/// 2. **Press and release as separate messages.** Over the internet the
///    release can arrive late (jitter, the SPICE thread busy decoding a
///    frame), and a guest that repeats keys by itself (USB keyboard, X11,
///    Wayland) then sees a long hold. Like spice-gtk against a remote server
///    (its `keypress-delay`), a non-modifier press waits up to `pressDelay`
///    (100 ms); released within that, press and release go out as ONE
///    message (SPICE_MSGC_INPUTS_KEY_SCANCODE), which no delay can pull apart.
///    Any other key event sends a waiting press first, so order is kept.
///
/// Both delays can be changed without a rebuild, e.g. to compare behaviours:
/// `defaults write dev.caramelfur.shadowpcadvanced console.keyRepeatDelayMs -int 0`
/// forwards every macOS repeat (the old behaviour), `-1` never forwards one
/// (UTM's choice); `console.keyPressDelayMs 0` sends presses at once.
@MainActor
final class GuestKeySender {
    enum Event {
        case press(UInt32)
        case release(UInt32)
        /// Press and release in one message.
        case tap(UInt32)
    }

    nonisolated static let repeatDelayKey = "console.keyRepeatDelayMs"
    nonisolated static let pressDelayKey = "console.keyPressDelayMs"

    /// How long a key must be down before macOS repeats reach the guest; nil = never.
    nonisolated static var repeatDelay: TimeInterval? {
        let ms = milliseconds(forKey: repeatDelayKey, default: 500)
        return ms < 0 ? nil : TimeInterval(ms) / 1000
    }

    /// How long a non-modifier press may wait for its release.
    nonisolated static var pressDelay: TimeInterval { TimeInterval(max(milliseconds(forKey: pressDelayKey, default: 100), 0)) / 1000 }

    private nonisolated static func milliseconds(forKey key: String, default value: Int) -> Int {
        UserDefaults.standard.object(forKey: key) == nil ? value : UserDefaults.standard.integer(forKey: key)
    }

    /// Hands one event to the guest; false when there is nowhere to send it.
    private let deliver: (Event) -> Bool
    private let trace: InputTrace

    /// Non-modifier keys down in the guest (or waiting in `pending`), with the
    /// time of their press (NSEvent timestamps: seconds since boot).
    private var held: [UInt32: TimeInterval] = [:]
    /// The press being held back.
    private var pending: UInt32?
    private var pendingGeneration = 0

    init(trace: InputTrace, deliver: @escaping (Event) -> Bool) {
        self.trace = trace
        self.deliver = deliver
    }

    func keyDown(_ code: UInt32, isRepeat: Bool, at time: TimeInterval) {
        if let since = held[code] {
            if isRepeat {
                let heldFor = time - since
                guard let delay = Self.repeatDelay, heldFor >= delay else {
                    trace.log("key ↓ \(InputTrace.key(code)) (macOS repeat after \(InputTrace.milliseconds(heldFor)) ms, not sent)")
                    return
                }
                flush()
                emit(.press(code), "key ↓ \(InputTrace.key(code)) (repeat, held \(InputTrace.milliseconds(heldFor)) ms)")
                return
            }
            // A new press of a key whose release never arrived: let go of the old one first.
            keyUp(code, at: time)
        } else if isRepeat {
            // Auto-repeat of a key that was pressed before this view had the keyboard.
            return
        }
        flush()
        held[code] = time
        let delay = Self.pressDelay
        guard delay > 0 else { return emit(.press(code), "key ↓ \(InputTrace.key(code))") }
        pending = code
        pendingGeneration += 1
        let generation = pendingGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.pendingGeneration == generation else { return }
            self.flush()
        }
    }

    func keyUp(_ code: UInt32, at time: TimeInterval) {
        guard let since = held.removeValue(forKey: code) else { return }
        let heldFor = InputTrace.milliseconds(time - since)
        if pending == code {
            pending = nil
            emit(.tap(code), "key ↓↑ \(InputTrace.key(code)) (held \(heldFor) ms, sent as one message)")
        } else {
            flush()
            emit(.release(code), "key ↑ \(InputTrace.key(code)) (held \(heldFor) ms)")
        }
    }

    /// Modifiers are never held back (spice-gtk's rule too). They change what a
    /// waiting key means, so that key goes first.
    func modifier(_ code: UInt32, down: Bool, note: String = "modifier") {
        flush()
        emit(down ? .press(code) : .release(code), "key \(down ? "↓" : "↑") \(InputTrace.key(code)) (\(note))")
    }

    /// A press and release the Mac has no separate events for (a ⌘ tap as the
    /// Windows key, Caps Lock), as one message.
    func tap(_ code: UInt32, note: String) {
        flush()
        emit(.tap(code), "key ↓↑ \(InputTrace.key(code)) (\(note))")
    }

    /// Sends a waiting press now. Called before anything else goes to the guest.
    func flush() {
        guard let code = pending else { return }
        pending = nil
        emit(.press(code), "key ↓ \(InputTrace.key(code))")
    }

    /// Focus is going away: nothing may stay down in the guest.
    func releaseAll() {
        if let code = pending {
            pending = nil
            held[code] = nil
            emit(.tap(code), "key ↓↑ \(InputTrace.key(code)) (focus lost while held)")
        }
        for code in held.keys.sorted() {
            emit(.release(code), "key ↑ \(InputTrace.key(code)) (let go: focus lost)")
        }
        held.removeAll()
    }

    private func emit(_ event: Event, _ line: @autoclosure () -> String) {
        let sent = deliver(event)
        trace.log(sent ? line() : "\(line()) — not sent, no inputs channel")
    }
}
