import Foundation
import Observation

/// What the app knows of the house: the last of each line `dmain` sent. Nothing
/// is cleared when the link goes; it greys instead, because stale must look stale.
@MainActor @Observable
public final class House {
    public private(set) var link: LinkStatus?
    public private(set) var attention: Attention?
    /// Each whole-class screen, by its `screen` name.
    public private(set) var tables: [String: Section] = [:]
    /// Every device either network lists, by name; empty until the link reports them.
    public private(set) var devices: [DeviceInfo] = []
    /// `rooms.json`'s rooms; nil until the stream says.
    public private(set) var rooms: RoomsState?
    /// hub's network; nil until the stream says.
    public private(set) var zigbee: ZigbeeState?
    /// Newest first.
    public private(set) var log: [Event] = []
    /// nil until the link has reported them.
    public private(set) var services: [ServiceRow]?
    public private(set) var config: ConfigState?
    public private(set) var console: ConsoleFeed?
    /// How to start dmain, once connected: requests use it too.
    public private(set) var command: DmainCommand?
    /// Why the stream stopped, once it has.
    public private(set) var ended: String?
    /// A line this build couldn't read.
    public private(set) var unreadable: String?
    /// When the link last changed state, to say how long it has been down.
    public private(set) var since: Date?
    /// When the app will try again after the stream ended, while it's waiting to.
    public private(set) var reconnectAt: Date?
    private var running: RunningStream?
    private var reconnecting: Task<Void, Never>?
    /// Tries since the link was last up, which sets how long the next waits.
    private var attempts = 0

    /// Seconds before each try again: quick at first, then once a minute, so a
    /// server that's down isn't asked every moment.
    static let backoff: [Double] = [2, 5, 15, 30, 60]

    public init() {}

    /// What's shown is history: the link isn't up, or dmain has stopped.
    public var isStale: Bool { ended != nil || link?.state != .up }

    public func connect(_ command: DmainCommand) {
        disconnect()
        self.command = command
        ended = nil
        unreadable = nil
        do {
            let r = try RunningStream(command)
            running = r
            Task { [weak self] in
                // A stream that's been replaced may still be ending: what it says
                // is about a link this app no longer holds.
                for await event in r.events {
                    guard let self, self.running === r else { return }
                    self.apply(event)
                }
            }
        } catch {
            apply(.ended("couldn't start \(command.executable.path): \(error.localizedDescription)"))
        }
    }

    /// One device on every screen that has it, in the screens' order: the
    /// inspector. Only regroups rows dmain sent.
    public func device(_ dev: String) -> [(Section, Row)] {
        ["power_on", "firmware", "battery", "heard"].compactMap { screen in
            guard let t = tables[screen], let row = t.rows.first(where: { $0.dev == dev }) else { return nil }
            return (t, row)
        }
    }

    /// Runs one request. An `apply` changes what the stream's dry runs said, and
    /// only a fresh stream checks again, so the stream restarts when one ends:
    /// what's shown greys while it reconnects rather than claim the old result.
    public func request(_ words: [String], then: (@MainActor (Request) -> Void)? = nil) -> Request? {
        guard let command else { return nil }
        return Request(command, words) { [weak self] r in
            if r.words.first == "apply" { self?.connect(command) }
            then?(r)
        }
    }

    /// Stops the stream and any try again that's waiting. What's shown stays.
    public func disconnect() {
        reconnecting?.cancel()
        reconnecting = nil
        reconnectAt = nil
        let r = running
        running = nil
        r?.stop()
    }

    /// Starts a stream again after a wait, as a link that closes has nothing to
    /// come back on: the server's agent has gone.
    private func scheduleReconnect(from now: Date) {
        guard let command else { return }
        let wait = Self.backoff[min(attempts, Self.backoff.count - 1)]
        attempts += 1
        reconnectAt = now.addingTimeInterval(wait)
        reconnecting = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.connect(command)
        }
    }

    public func apply(_ event: StreamEvent, at now: Date = Date()) {
        switch event {
        case let .line(.link(l)):
            if link?.state != l.state { since = now }
            link = l
            if l.state == .up { attempts = 0 }
        case let .line(.attention(a)):
            attention = a
        case let .line(.devices(d)):
            devices = d
        case let .line(.rooms(r)):
            rooms = r
        case let .line(.zigbee(z)):
            zigbee = z
        case let .line(.table(t)):
            tables[t.screen] = t
        case let .line(.log(events)):
            log = events
        case let .line(.services(list)):
            services = list
        case let .line(.config(c)):
            config = c
        case let .line(.console(c)):
            console = c
        case .line(.output), .line(.phase), .line(.done), .line(.history), .line(.scenes), .line(.bridge):
            break
        case let .unreadable(text):
            unreadable = text
        case let .ended(why):
            // A link that closed has said why, which says more than dmain's exit.
            ended = link?.state == .closed ? (link?.why ?? why) : why
            since = now
            running = nil
            scheduleReconnect(from: now)
        }
    }
}
