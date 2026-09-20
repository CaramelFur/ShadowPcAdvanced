import Foundation

/// Which session of a VM a console is bound to. Fed with every observation of
/// the VM (its live address, and whether we are shutting it down), it answers
/// the only two questions a console has: connect now? let go now?
///
/// `.began` comes once per session, so a console connects (with a ticket of
/// that session) exactly once by itself; retrying is the user's Reconnect.
public struct ConsoleSessionTracker: Sendable {
    public enum Change: Equatable, Sendable {
        case none
        /// A session the console isn't bound to yet, first start or restart alike.
        case began(VMAddress)
        /// The bound session is over: its ticket and URL are worthless now.
        case ended
    }

    /// `/shadow/vm/ip` failing once must not kick a live console. A missing
    /// address only counts once it has stayed missing this long, i.e. once the
    /// next regular refresh confirms it. A stop we asked for counts at once.
    public var missingGrace: TimeInterval
    /// Address of the bound session; nil while there is none.
    public private(set) var address: VMAddress?
    private var missingSince: Date?

    public init(missingGrace: TimeInterval = 8) { self.missingGrace = missingGrace }

    public mutating func observe(address live: VMAddress?, stopping: Bool, now: Date = Date()) -> Change {
        if let live, !stopping {
            missingSince = nil
            guard live.sessionKey != address?.sessionKey else { return .none }
            address = live
            return .began(live)
        }
        guard address != nil else { return .none }
        if !stopping {
            let since = missingSince ?? now
            missingSince = since
            if now.timeIntervalSince(since) < missingGrace { return .none }
        }
        end()
        return .ended
    }

    /// Bind to a session learned outside `observe` (Reconnect asks the API
    /// itself), so the observation that follows doesn't count as a new one.
    public mutating func adopt(_ live: VMAddress) {
        address = live
        missingSince = nil
    }

    public mutating func end() {
        address = nil
        missingSince = nil
    }
}
