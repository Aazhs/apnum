import ApnumCore
import Foundation
import Synchronization
import Testing
@testable import ApnumSystem

// MARK: - Fakes

private final class FakeRunner: CommandRunning {
    let calls = Mutex<[[String]]>([])
    let handler: @Sendable ([String]) throws -> CommandResult
    init(_ handler: @escaping @Sendable ([String]) throws -> CommandResult) { self.handler = handler }
    func run(_ executable: URL, arguments: [String], stdin: Data?) async throws -> CommandResult {
        calls.withLock { $0.append(arguments) }
        return try handler(arguments)
    }
}

private final class FakeControl: SystemControlling {
    struct State {
        var volume = VolumeState(volume: 30, muted: false)
        var opened: [URL] = []
        var apps: [String] = []
        var clipboard: String? = "hello"
        var media: [MediaAction] = []
        var lockWorks = true
    }
    let state = Mutex(State())
    func volume() async throws -> VolumeState { state.withLock { $0.volume } }
    func setVolume(_ volume: Int?, muted: Bool?) async throws {
        state.withLock {
            if let volume { $0.volume.volume = volume }
            if let muted { $0.volume.muted = muted }
        }
    }
    func mediaKey(_ action: MediaAction) async throws { state.withLock { $0.media.append(action) } }
    func clipboardText() async throws -> String? { state.withLock { $0.clipboard } }
    func setClipboardText(_ text: String) async throws { state.withLock { $0.clipboard = text } }
    func sleepDisplay() async throws {}
    func sleepMac() async throws {}
    func lockScreen() async throws -> Bool { state.withLock { $0.lockWorks } }
    func battery() async throws -> BatteryInfo { BatteryInfo(hasBattery: false) }
    func open(url: URL) async throws { state.withLock { $0.opened.append(url) } }
    func openApp(_ nameOrBundleID: String) async throws { state.withLock { $0.apps.append(nameOrBundleID) } }
    func frontmostApp() async throws -> FrontmostApp { FrontmostApp(name: "Safari", bundleId: "com.apple.Safari") }
}

private struct FakeShortcuts: ShortcutRunning {
    func list() async throws -> [String] { ["Morning", "Lights Off"] }
    func run(_ name: String, input: Data?) async throws -> Data {
        Data("ran \(name) with \(input.map { String(decoding: $0, as: UTF8.self) } ?? "nothing")".utf8)
    }
}

private final class FakeNotifier: Notifying {
    let sent = Mutex<[String]>([])
    func notify(title: String, body: String) async throws { sent.withLock { $0.append(title + "|" + body) } }
}

private func makeRegistry(control: FakeControl = FakeControl(), notifier: FakeNotifier = FakeNotifier()) -> ToolRegistry {
    ToolRegistry(tools: makeSystemTools(control: control, shortcuts: FakeShortcuts(), notifier: notifier))
}

// MARK: - Tests

@Suite struct SystemTests {
    @Test func parsesVolumeSettings() {
        let v = VolumeState.parse(osascript: "output volume:42, input volume:75, alert volume:100, output muted:true\n")
        #expect(v == VolumeState(volume: 42, muted: true))
        #expect(VolumeState.parse(osascript: "55\n") == VolumeState(volume: 55, muted: nil))
        #expect(VolumeState.parse(osascript: "output volume:missing value, input volume:75, alert volume:100, output muted:false")
            == VolumeState(volume: nil, muted: false))
    }

    @Test func volumeValidation() async throws {
        #expect(throws: ToolError.self) { try VolumeSetTool.validate(.init()) }
        #expect(throws: ToolError.self) { try VolumeSetTool.validate(.init(volume: 101)) }
        #expect(throws: ToolError.self) { try VolumeSetTool.validate(.init(volume: -1)) }
        try VolumeSetTool.validate(.init(volume: 0))
        try VolumeSetTool.validate(.init(muted: true))
    }

    @Test func liveVolumeUsesOsascript() async throws {
        let runner = FakeRunner { args in
            args.last == "get volume settings"
                ? CommandResult(exitCode: 0, stdout: "output volume:10, input volume:1, alert volume:1, output muted:false")
                : CommandResult(exitCode: 0)
        }
        let control = LiveSystemControl(runner: runner)
        #expect(try await control.volume() == VolumeState(volume: 10, muted: false))
        try await control.setVolume(75, muted: true)
        #expect(runner.calls.withLock { $0.suffix(2).map { $0.last! } }
            == ["set volume output volume 75", "set volume output muted true"])
    }

    @Test func shortcutsCLIBuildsArgumentsAndReadsOutput() async throws {
        let runner = FakeRunner { args in
            if args == ["list"] { return CommandResult(exitCode: 0, stdout: "A\n\nB B\n") }
            let outPath = args[args.firstIndex(of: "--output-path")! + 1]
            let inPath = args[args.firstIndex(of: "--input-path")! + 1]
            let input = try String(contentsOfFile: inPath, encoding: .utf8)
            try Data("out:\(input)".utf8).write(to: URL(fileURLWithPath: outPath))
            return CommandResult(exitCode: 0)
        }
        let cli = ShortcutsCLI(runner: runner)
        #expect(try await cli.list() == ["A", "B B"])
        let out = try await cli.run("My Shortcut", input: Data("hi".utf8))
        #expect(String(decoding: out, as: UTF8.self) == "out:hi")
        let args = runner.calls.withLock { $0.last! }
        #expect(args[0] == "run" && args[1] == "My Shortcut")
        #expect(args.contains("--input-path") && args.contains("--output-path"))
        // temp files are cleaned up
        let outPath = args[args.firstIndex(of: "--output-path")! + 1]
        #expect(!FileManager.default.fileExists(atPath: outPath))
    }

    @Test func shortcutsCLIErrors() async throws {
        let failing = ShortcutsCLI(runner: FakeRunner { _ in CommandResult(exitCode: 1, stderr: "Error: Couldn't find shortcut\n") })
        await #expect(throws: ToolError.failed("Error: Couldn't find shortcut")) { _ = try await failing.run("x", input: nil) }
        let missing = ShortcutsCLI(runner: FakeRunner { _ in throw CocoaError(.fileNoSuchFile) })
        await #expect(throws: ToolError.self) { _ = try await missing.list() }
        await #expect(throws: ToolError.self) { _ = try await failing.run("--help", input: nil) }
    }

    @Test func openAllowList() throws {
        #expect(try OpenTool.validate(.init(url: "https://example.com/a?b=1")) == .url(URL(string: "https://example.com/a?b=1")!))
        _ = try OpenTool.validate(.init(url: "HTTP://example.com"))
        _ = try OpenTool.validate(.init(url: "mailto:a@b.com"))
        _ = try OpenTool.validate(.init(url: "tel:+15551234"))
        #expect(try OpenTool.validate(.init(app: "Safari")) == .app("Safari"))
        for bad in ["file:///etc/passwd", "javascript:alert(1)", "ssh://host", "x-apple.systempreferences:", "nonsense"] {
            #expect(throws: ToolError.self) { try OpenTool.validate(.init(url: bad)) }
        }
        #expect(throws: ToolError.self) { try OpenTool.validate(.init()) }
        #expect(throws: ToolError.self) { try OpenTool.validate(.init(url: "https://a.com", app: "Safari")) }
        #expect(throws: ToolError.self) { try OpenTool.validate(.init(app: "/Applications/Evil.app")) }
    }

    @Test func parsesBatteryDictionary() {
        let sources: [[String: Any]] = [[
            "Type": "InternalBattery", "Current Capacity": 80, "Max Capacity": 100,
            "Is Charging": true, "Power Source State": "AC Power",
            "Time to Full Charge": 45, "Time to Empty": 0,
        ]]
        #expect(BatteryInfo.parse(sources: sources)
            == BatteryInfo(hasBattery: true, percent: 80, charging: true, powerSource: "AC Power", minutesRemaining: 45))

        let discharging: [[String: Any]] = [[
            "Type": "InternalBattery", "Current Capacity": 1, "Max Capacity": 3,
            "Is Charging": false, "Power Source State": "Battery Power", "Time to Empty": -1,
        ]]
        let info = BatteryInfo.parse(sources: discharging)
        #expect(info.percent == 33 && info.minutesRemaining == nil && info.charging == false)

        #expect(BatteryInfo.parse(sources: []) == BatteryInfo(hasBattery: false))
    }

    @Test func toolsRoundTripThroughRegistry() async throws {
        let control = FakeControl()
        let notifier = FakeNotifier()
        let registry = makeRegistry(control: control, notifier: notifier)

        let set = try await registry.callJSON("mac.volume.set", input: ["volume": 60, "muted": true], caller: .ui)
        #expect(set == ["volume": 60, "muted": true])
        #expect(try await registry.callJSON("mac.volume.get", caller: .agent("a")) == ["volume": 60, "muted": true])

        _ = try await registry.callJSON("mac.clipboard.set", input: ["text": "copied"], caller: .ui)
        #expect(try await registry.callJSON("mac.clipboard.get", caller: .agent("a")) == ["text": "copied"])

        _ = try await registry.callJSON("mac.media.control", input: ["action": "next"], caller: .ui)
        #expect(control.state.withLock { $0.media } == [.next])

        _ = try await registry.callJSON("mac.notify", input: ["title": "T", "body": "B"], caller: .ui)
        #expect(notifier.sent.withLock { $0 } == ["T|B"])

        _ = try await registry.callJSON("mac.open", input: ["url": "https://example.com"], caller: .ui)
        #expect(control.state.withLock { $0.opened } == [URL(string: "https://example.com")!])

        #expect(try await registry.callJSON("shortcuts.list", caller: .ui) == ["shortcuts": ["Morning", "Lights Off"]])
        #expect(try await registry.callJSON("shortcuts.run", input: ["name": "Morning", "input": "x"], caller: .ui)
            == ["output": "ran Morning with x"])
        #expect(try await registry.callJSON("mac.apps.frontmost", caller: .ui)["bundleId"] == "com.apple.Safari")
    }

    @Test func lockFallbackMessage() async throws {
        let control = FakeControl()
        control.state.withLock { $0.lockWorks = false }
        let out = try await makeRegistry(control: control).callJSON("mac.lock", caller: .ui)
        #expect(out["message"].map { if case .string(let s) = $0 { s.contains("display") } else { false } } == true)
    }

    @Test func invalidInputsAreRejected() async throws {
        let registry = makeRegistry()
        await #expect(throws: ToolError.self) { _ = try await registry.callJSON("mac.volume.set", input: [:], caller: .ui) }
        await #expect(throws: ToolError.self) { _ = try await registry.callJSON("mac.volume.set", input: ["volume": "loud"], caller: .ui) }
        await #expect(throws: ToolError.self) { _ = try await registry.callJSON("mac.media.control", input: ["action": "explode"], caller: .ui) }
        await #expect(throws: ToolError.self) { _ = try await registry.callJSON("mac.open", input: ["url": "file:///etc/hosts"], caller: .ui) }
    }

    @Test func tiersAreHonest() {
        let tiers = Dictionary(uniqueKeysWithValues: makeRegistry().descriptors.map { ($0.name, $0.tier) })
        #expect(tiers.count == 14)
        #expect(tiers["mac.sleep"] == .dangerous && tiers["mac.open"] == .dangerous && tiers["shortcuts.run"] == .dangerous)
        #expect(tiers["mac.volume.get"] == .read && tiers["mac.battery"] == .read && tiers["shortcuts.list"] == .read)
        #expect(tiers["mac.lock"] == .write)
    }

    @Test func commandRunnerCapturesLargeOutputAndStdin() async throws {
        let runner = CommandRunner()
        let big = try await runner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "head -c 500000 /dev/zero; echo err >&2; exit 3"], stdin: nil)
        #expect(big.exitCode == 3 && big.stdout.utf8.count == 500_000 && big.stderr == "err\n")
        let payload = String(repeating: "abcdefghij", count: 50_000)
        let echoed = try await runner.run(URL(fileURLWithPath: "/bin/cat"), arguments: [], stdin: Data(payload.utf8))
        #expect(echoed.stdout == payload)
        await #expect(throws: (any Error).self) {
            _ = try await runner.run(URL(fileURLWithPath: "/nonexistent/tool"), arguments: [], stdin: nil)
        }
    }

    @MainActor
    @Test func ringerWorksWithoutBundle() async {
        let ringer = MacRinger(playsSound: false)
        let request = RingRequest(id: "a1", kind: .alarm, title: "Wake", body: "Up", canSnooze: true)
        await ringer.start(request)
        await ringer.start(RingRequest(id: "t1", kind: .timer, title: "Tea", body: "", canSnooze: false))
        ringer.setResponder { _, _, _ in }
        await ringer.stop(id: "a1")
        await ringer.stop(id: "missing")
        await ringer.stop(id: "t1")
        #expect(await ringer.requestNotificationPermission() == false)
        await #expect(throws: ToolError.self) { try await ringer.notify(title: "x", body: "y") }
    }
}
