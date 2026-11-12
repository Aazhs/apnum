import Foundation
import Synchronization

// Interfaces that feature modules depend on and the macOS layer implements.
// Keeping them here lets features stay testable without AppKit.

/// Something that needs the user's attention right now: an alarm or a finished timer.
public struct RingRequest: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable { case alarm, timer }

    /// Stable id of the alarm or timer that is ringing.
    public let id: String
    public let kind: Kind
    public let title: String
    public let body: String
    public let canSnooze: Bool
    /// A system sound name (e.g. "Glass"), or nil for the default.
    public let sound: String?

    public init(id: String, kind: Kind, title: String, body: String, canSnooze: Bool, sound: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.canSnooze = canSnooze
        self.sound = sound
    }
}

public enum RingResponse: String, Sendable, Codable { case stop, snooze }

/// Plays the alert for an alarm or timer until it is stopped.
public protocol Ringer: Sendable {
    func start(_ request: RingRequest) async
    func stop(id: String) async
}

/// Does nothing. For tests and headless use.
public struct SilentRinger: Ringer {
    public init() {}
    public func start(_ request: RingRequest) async {}
    public func stop(id: String) async {}
}

/// Records calls. For tests.
public final class RecordingRinger: Ringer {
    private let state = Mutex<(started: [RingRequest], stopped: [String])>(([], []))
    public init() {}
    public var started: [RingRequest] { state.withLock { $0.started } }
    public var stopped: [String] { state.withLock { $0.stopped } }
    public func start(_ request: RingRequest) async { state.withLock { $0.started.append(request) } }
    public func stop(id: String) async { state.withLock { $0.stopped.append(id) } }
}

/// Runs macOS Shortcuts by name. Implemented with `/usr/bin/shortcuts` in ApnumSystem.
public protocol ShortcutRunning: Sendable {
    /// Names of the user's installed shortcuts.
    func list() async throws -> [String]
    /// Runs a shortcut with optional input and returns its output bytes (empty if none).
    func run(_ name: String, input: Data?) async throws -> Data
}

/// Calls a handler about once a second. Services that fire at a time
/// (alarms, timers) expose `tick(now:)` and are driven by this, which keeps
/// them testable with fixed dates.
public final class Ticker: Sendable {
    private let task = Mutex<Task<Void, Never>?>(nil)

    public init() {}

    public func start(interval: Duration = .seconds(1), _ handler: @escaping @Sendable (Date) async -> Void) {
        let newTask = Task {
            while !Task.isCancelled {
                await handler(Date())
                try? await Task.sleep(for: interval)
            }
        }
        task.withLock { $0?.cancel(); $0 = newTask }
    }

    public func stop() { task.withLock { $0?.cancel(); $0 = nil } }

    deinit { task.withLock { $0?.cancel() } }
}
