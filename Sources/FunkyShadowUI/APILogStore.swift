import Foundation
import ShadowAPI

/// Ring buffer behind the API Log window. Entries arrive already redacted.
final class APILogStore: ObservableObject, APILogSink, @unchecked Sendable {
    static let capacity = 1000

    @Published private(set) var entries: [APILogEntry] = []

    func record(_ entry: APILogEntry) {
        DispatchQueue.main.async {
            self.entries.append(entry)
            if self.entries.count > Self.capacity { self.entries.removeFirst(self.entries.count - Self.capacity) }
        }
    }

    func clear() { entries.removeAll() }
}
