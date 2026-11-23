import Foundation
import Observation

/// One request the app makes, as a command of its own: its output as it comes,
/// and how it ended. The stream shows the house afterwards; this only says what
/// the request did.
@MainActor @Observable
public final class Request {
    public let words: [String]
    public private(set) var lines: [String] = []
    public private(set) var phase: String?
    /// nil while it runs.
    public private(set) var outcome: (ok: Bool, why: String?)?
    /// What a `history` request folded.
    public private(set) var history: History?
    /// What a `scenes` request read.
    public private(set) var scenes: [RoomScenes]?
    /// What a `bridge` request read.
    public private(set) var bridge: BridgeInfo?
    private var running: RunningStream?
    private let finished: (@MainActor (Request) -> Void)?

    public var isRunning: Bool { outcome == nil }

    /// Starts it at once. `finished` runs when it ends, however it ends.
    public init(_ command: DmainCommand, _ words: [String], finished: (@MainActor (Request) -> Void)? = nil) {
        self.words = words
        self.finished = finished
        do {
            let r = try RunningStream(command, request: words)
            running = r
            Task { [weak self] in
                for await event in r.events { self?.apply(event) }
            }
        } catch {
            apply(.ended("couldn't start dmain: \(error.localizedDescription)"))
        }
    }

    /// For previews and tests: a request that has already said these things.
    public init(words: [String], events: [StreamEvent]) {
        self.words = words
        finished = nil
        for e in events { apply(e) }
    }

    /// Ends a request that runs until told, such as a journal.
    public func stop() {
        running?.stop()
    }

    func apply(_ event: StreamEvent) {
        switch event {
        case let .line(.output(text)): lines.append(text)
        case let .line(.phase(p)): phase = p
        case let .line(.done(ok, why)):
            if outcome == nil { outcome = (ok, why) }
        case let .line(.history(h)): history = h
        case let .line(.scenes(list)): scenes = list
        case let .line(.bridge(b)): bridge = b
        case .line: break
        case let .unreadable(text): lines.append("unreadable: \(text)")
        case let .ended(why):
            // A request that ends without saying how is a failure, with dmain's last word.
            if outcome == nil { outcome = (false, why) }
            running = nil
            finished?(self)
        }
    }
}
