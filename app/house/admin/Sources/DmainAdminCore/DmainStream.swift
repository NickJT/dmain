import Foundation

/// How to start `dmain`: the binary, the checkout it reads wanted files from, and
/// the house server.
public struct DmainCommand: Equatable, Sendable {
    public var executable: URL
    /// `app/house/dmain` in the git checkout: dmain dry-runs the wanted files there.
    public var checkout: URL
    public var host: String

    public init(executable: URL, checkout: URL, host: String) {
        self.executable = executable
        self.checkout = checkout
        self.host = host
    }

    /// The `dmain` that `bundle.sh` put in the app, or else the checkout's own build.
    public static func resolve(checkout path: String, host: String, bundle: Bundle = .main) -> DmainCommand {
        let checkout = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        let executable = bundle.url(forAuxiliaryExecutable: "dmain")
            ?? checkout.appending(path: "zig-out/bin/dmain")
        return DmainCommand(executable: executable, checkout: checkout, host: host)
    }
}

public enum StreamEvent: Equatable, Sendable {
    case line(StreamLine)
    /// A line that wouldn't decode: the two halves come from different builds.
    case unreadable(String)
    /// dmain has exited, and the last thing it said on stderr, if anything.
    case ended(String)
}

/// A running `dmain admin H …`: the stream (`--json`), or one request. Its
/// stdin is held open and carries nothing; closing it is how dmain is told to stop.
public final class RunningStream: @unchecked Sendable {
    public let events: AsyncStream<StreamEvent>
    private let process: Process
    private let stdin: Pipe

    /// `request` is the words after the host, such as `["restart", "hub"]`; none is the stream.
    public init(_ command: DmainCommand, request: [String] = []) throws {
        let process = Process()
        process.executableURL = command.executable
        process.arguments = ["admin", command.host] + (request.isEmpty ? ["--json"] : request)
        process.currentDirectoryURL = command.checkout
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let (events, continuation) = AsyncStream.makeStream(of: StreamEvent.self)
        self.events = events
        self.process = process
        self.stdin = stdin
        try process.run()

        let out = Handle(stdout.fileHandleForReading), err = Handle(stderr.fileHandleForReading)
        let proc = Handle(process)
        Task.detached {
            do {
                for try await line in out.value.bytes.lines {
                    do {
                        if let decoded = try StreamLine.decode(Data(line.utf8)) { continuation.yield(.line(decoded)) }
                    } catch {
                        continuation.yield(.unreadable(String(line.prefix(120))))
                    }
                }
            } catch {}
            proc.value.waitUntilExit()
            let said = String(decoding: err.value.readDataToEndOfFile(), as: UTF8.self)
                .split(separator: "\n").last.map(String.init) ?? ""
            let how = proc.value.terminationReason == .uncaughtSignal
                ? "dmain was stopped by signal \(proc.value.terminationStatus)"
                : "dmain exited with status \(proc.value.terminationStatus)"
            continuation.yield(.ended(said.isEmpty ? how : said))
            continuation.finish()
        }
    }

    public func stop() {
        try? stdin.fileHandleForWriting.close()
    }
}

/// Moves a Foundation object into the reading task, which is the only place it's used.
private struct Handle<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
