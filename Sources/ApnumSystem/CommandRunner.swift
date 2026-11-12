import Foundation
import Synchronization

public struct CommandResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
    public var succeeded: Bool { exitCode == 0 }
}

/// Runs an external process. A protocol so tests can fake it.
public protocol CommandRunning: Sendable {
    func run(_ executable: URL, arguments: [String], stdin: Data?) async throws -> CommandResult
}

public extension CommandRunning {
    func run(_ executable: URL, arguments: [String]) async throws -> CommandResult {
        try await run(executable, arguments: arguments, stdin: nil)
    }
}

/// Runs processes without blocking a thread: the pipes are drained by
/// readability handlers and completion is signalled by the termination handler.
public struct CommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: URL, arguments: [String], stdin: Data?) async throws -> CommandResult {
        let collector = Collector()
        return try await withCheckedThrowingContinuation { continuation in
            collector.setContinuation(continuation)
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe

            func drain(_ pipe: Pipe, isOut: Bool) {
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                        collector.streamEnded(isOut: isOut)
                    } else {
                        collector.append(chunk, isOut: isOut)
                    }
                }
            }
            drain(outPipe, isOut: true)
            drain(errPipe, isOut: false)
            process.terminationHandler = { p in collector.exited(code: p.terminationStatus) }

            do {
                try process.run()
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                collector.fail(error)
                return
            }
            if let stdin {
                // Write off the cooperative pool; a large write can block until the child reads.
                DispatchQueue.global().async {
                    let handle = inPipe.fileHandleForWriting
                    try? handle.write(contentsOf: stdin)
                    try? handle.close()
                }
            }
        }
    }
}

private final class Collector: Sendable {
    struct State {
        var out = Data(), err = Data()
        var outDone = false, errDone = false, exited = false
        var code: Int32 = 0
        var continuation: CheckedContinuation<CommandResult, any Error>?
    }
    private let state = Mutex(State())

    func setContinuation(_ c: CheckedContinuation<CommandResult, any Error>) { state.withLock { $0.continuation = c } }
    func append(_ d: Data, isOut: Bool) { state.withLock { if isOut { $0.out.append(d) } else { $0.err.append(d) } } }
    func streamEnded(isOut: Bool) { finish { if isOut { $0.outDone = true } else { $0.errDone = true } } }
    func exited(code: Int32) { finish { $0.exited = true; $0.code = code } }

    func fail(_ error: any Error) {
        let c = state.withLock { s -> CheckedContinuation<CommandResult, any Error>? in
            defer { s.continuation = nil }
            return s.continuation
        }
        c?.resume(throwing: error)
    }

    private func finish(_ mutate: (inout State) -> Void) {
        let ready = state.withLock { s -> (CheckedContinuation<CommandResult, any Error>, CommandResult)? in
            mutate(&s)
            guard s.outDone, s.errDone, s.exited, let c = s.continuation else { return nil }
            s.continuation = nil
            return (c, CommandResult(
                exitCode: s.code,
                stdout: String(decoding: s.out, as: UTF8.self),
                stderr: String(decoding: s.err, as: UTF8.self)))
        }
        if let (c, result) = ready { c.resume(returning: result) }
    }
}
