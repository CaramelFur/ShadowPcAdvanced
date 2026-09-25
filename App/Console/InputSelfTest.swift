import AppKit
import Carbon.HIToolbox
import ShadowAPI

/// `ShadowPcAdvanced --selftest-input ws://127.0.0.1:8766/` against
/// `Scripts/fake-spice-inputs.py 8766` (diagnostics): each native engine
/// connects to the fake server, then the same scripted keystrokes and a click
/// are fed to its console view as synthetic NSEvents with real timing — macOS
/// repeats at this Mac's own InitialKeyRepeat/KeyRepeat — and the server prints
/// what arrived for each. Add `-console.inputTrace YES` to see the trace too.
@MainActor
enum InputSelfTest {
    /// Must match SCENARIOS in Scripts/fake-spice-inputs.py.
    static let scenarios = [
        "tap A (70 ms)",
        "hold A 350 ms (macOS repeats after InitialKeyRepeat)",
        "hold D 900 ms (a deliberate hold, e.g. Backspace)",
        "Shift+S, Shift let go before S",
        "rollover: Q down, W down, Q up, W up",
        "left click",
        "⌘ tap (→ Windows key)",
        "⌘K with no menu item (AppKit never delivers K's key-up)",
    ]

    private final class Box { var ready = false }

    static func run(url: String) async -> Bool {
        let initial = 0.015 * Double(setting("InitialKeyRepeat", default: 25))
        let interval = 0.015 * Double(setting("KeyRepeat", default: 6))
        print(String(format: "macOS key repeat here: first after %.0f ms, then every %.0f ms", initial * 1000, interval * 1000))
        print("repeat hold-off \(GuestKeySender.repeatDelay.map { "\(InputTrace.milliseconds($0)) ms" } ?? "never"), press delay \(InputTrace.milliseconds(GuestKeySender.pressDelay)) ms")
        var ok = true
        for name in ["classic", "metal"] {
            let engine: ConsoleEngine = name == "classic" ? NativeSpiceEngine() : CocoaSpiceEngine()
            ok = await exercise(engine, name: name, url: url, initial: initial, interval: interval) && ok
        }
        print(ok ? "selftest-input: ok" : "selftest-input: FAILED")
        return ok
    }

    private static func setting(_ key: String, default value: Int) -> Int {
        UserDefaults.standard.object(forKey: key) == nil ? value : max(UserDefaults.standard.integer(forKey: key), 1)
    }

    private static func exercise(_ engine: ConsoleEngine, name: String, url: String, initial: TimeInterval, interval: TimeInterval) async -> Bool {
        print("== \(name) engine")
        engine.ticketProvider = { _ in
            SpiceTicket(uri: url, secret: "selftest", clientID: "", proxy: ProxyContext(base: URL(string: "https://127.0.0.1")!, token: ""))
        }
        let box = Box()
        let collector = Task {
            for await event in engine.events {
                switch event {
                case .log(let line): print("  [\(name)] \(line)")
                case .inputsReady: box.ready = true
                default: break
                }
            }
        }
        defer { collector.cancel() }
        await engine.connect(fresh: false)
        for _ in 0..<100 where !box.ready { await sleep(0.05) }
        guard box.ready else {
            print("  [\(name)] FAILED: the inputs channel never came up")
            await engine.disconnect()
            return false
        }
        await sleep(1) // the inputs channel's link

        let view = engine.view
        for (index, scenario) in scenarios.enumerated() {
            print("  [\(name)] --- \(index + 1). \(scenario)")
            marker(engine, index)
            await sleep(0.2)
            await play(steps(index, view: view, initial: initial, interval: interval))
            await sleep(0.6)
        }
        await engine.disconnect()
        await sleep(0.5)
        return true
    }

    /// Scenario boundaries for the server: a pointer position no display has.
    private static func marker(_ engine: ConsoleEngine, _ index: Int) {
        if let classic = engine as? NativeSpiceEngine {
            classic.mousePosition(x: 9000 + index, y: 0, buttons: 0)
        } else if let metal = engine as? CocoaSpiceEngine {
            metal.metalView.spiceInput?.sendMousePosition([], absolutePoint: CGPoint(x: 9000 + index, y: 0))
        }
    }

    private typealias Step = (at: TimeInterval, run: (TimeInterval) -> Void)

    private static func steps(_ index: Int, view: NSView, initial: TimeInterval, interval: TimeInterval) -> [Step] {
        func down(_ keyCode: Int, _ flags: NSEvent.ModifierFlags = []) -> (TimeInterval) -> Void {
            { t in view.keyDown(with: key(.keyDown, keyCode, flags, t, isRepeat: false)) }
        }
        func again(_ keyCode: Int) -> (TimeInterval) -> Void {
            { t in view.keyDown(with: key(.keyDown, keyCode, [], t, isRepeat: true)) }
        }
        func up(_ keyCode: Int) -> (TimeInterval) -> Void {
            { t in view.keyUp(with: key(.keyUp, keyCode, [], t, isRepeat: false)) }
        }
        func flags(_ keyCode: Int, _ flags: NSEvent.ModifierFlags) -> (TimeInterval) -> Void {
            { t in view.flagsChanged(with: key(.flagsChanged, keyCode, flags, t, isRepeat: false)) }
        }
        /// A key held for `duration` with the auto-repeats macOS would send meanwhile.
        func hold(_ keyCode: Int, _ duration: TimeInterval) -> [Step] {
            var out: [Step] = [(0, down(keyCode))]
            var t = initial
            while t < duration - 0.001 {
                out.append((t, again(keyCode)))
                t += interval
            }
            out.append((duration, up(keyCode)))
            return out
        }
        let shift = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x2)
        let command = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x8)
        switch index {
        case 0: return [(0, down(kVK_ANSI_A)), (0.07, up(kVK_ANSI_A))]
        case 1: return hold(kVK_ANSI_A, 0.35)
        case 2: return hold(kVK_ANSI_D, 0.9)
        case 3: return [(0, flags(kVK_Shift, shift)), (0.04, down(kVK_ANSI_S, shift)), (0.09, flags(kVK_Shift, [])), (0.12, up(kVK_ANSI_S))]
        case 4: return [(0, down(kVK_ANSI_Q)), (0.03, down(kVK_ANSI_W)), (0.06, up(kVK_ANSI_Q)), (0.11, up(kVK_ANSI_W))]
        case 5: return [(0, { t in view.mouseDown(with: mouse(.leftMouseDown, t)) }), (0.08, { t in view.mouseUp(with: mouse(.leftMouseUp, t)) })]
        case 6: return [(0, flags(kVK_Command, command)), (0.08, flags(kVK_Command, []))]
        case 7: return [(0, flags(kVK_Command, command)), (0.04, down(kVK_ANSI_K, command)), (0.15, flags(kVK_Command, []))]
        default: return []
        }
    }

    private static func key(_ type: NSEvent.EventType, _ keyCode: Int, _ flags: NSEvent.ModifierFlags, _ time: TimeInterval, isRepeat: Bool) -> NSEvent {
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags, timestamp: time, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: isRepeat, keyCode: UInt16(keyCode)
        )!
    }

    private static func mouse(_ type: NSEvent.EventType, _ time: TimeInterval) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: time, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    /// Runs each step at its offset from now, stamping events with that time.
    private static func play(_ steps: [Step]) async {
        let start = ProcessInfo.processInfo.systemUptime
        for step in steps.sorted(by: { $0.at < $1.at }) {
            let wait = start + step.at - ProcessInfo.processInfo.systemUptime
            if wait > 0 { await sleep(wait) }
            step.run(start + step.at)
        }
    }

    private static func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
