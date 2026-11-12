import ApnumCore
import AppKit
import ApplicationServices
import Foundation
import IOKit.ps

public struct VolumeState: Codable, Sendable, Equatable {
    /// 0-100, or nil when the current output device has no software volume (some HDMI/DisplayPort outputs).
    public var volume: Int?
    public var muted: Bool?
    public init(volume: Int?, muted: Bool?) {
        self.volume = volume
        self.muted = muted
    }

    /// Parses the output of `osascript -e 'get volume settings'`
    /// (`output volume:50, input volume:75, alert volume:100, output muted:false`)
    /// or a bare number such as `50` / `missing value`.
    public static func parse(osascript text: String) -> VolumeState {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let n = Int(s) { return VolumeState(volume: min(100, max(0, n)), muted: nil) }
        var volume: Int?
        var muted: Bool?
        for part in s.split(separator: ",") {
            let kv = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "output volume": volume = Int(kv[1]).map { min(100, max(0, $0)) }
            case "output muted": muted = kv[1] == "true" ? true : (kv[1] == "false" ? false : nil)
            default: break
            }
        }
        return VolumeState(volume: volume, muted: muted)
    }
}

public enum MediaAction: String, Codable, Sendable, CaseIterable {
    case play_pause, next, previous
}

public struct BatteryInfo: Codable, Sendable, Equatable {
    /// False on Macs without an internal battery; all other fields are then nil.
    public var hasBattery: Bool
    public var percent: Int?
    public var charging: Bool?
    /// "AC Power", "Battery Power" or "UPS Power".
    public var powerSource: String?
    /// Minutes until empty (on battery) or full (charging), when macOS knows.
    public var minutesRemaining: Int?

    public init(hasBattery: Bool, percent: Int? = nil, charging: Bool? = nil, powerSource: String? = nil, minutesRemaining: Int? = nil) {
        self.hasBattery = hasBattery
        self.percent = percent
        self.charging = charging
        self.powerSource = powerSource
        self.minutesRemaining = minutesRemaining
    }

    /// Builds from IOKit power source description dictionaries.
    public static func parse(sources: [[String: Any]]) -> BatteryInfo {
        guard let b = sources.first(where: { ($0["Type"] as? String) == "InternalBattery" }) else {
            return BatteryInfo(hasBattery: false)
        }
        var percent: Int?
        if let cur = b["Current Capacity"] as? Int, let max = b["Max Capacity"] as? Int, max > 0 {
            percent = Swift.min(100, Int((Double(cur) / Double(max) * 100).rounded()))
        }
        let charging = b["Is Charging"] as? Bool
        let key = charging == true ? "Time to Full Charge" : "Time to Empty"
        var minutes = b[key] as? Int
        if let m = minutes, m < 0 { minutes = nil }
        // While on AC and full, "Time to Empty" is meaningless.
        if charging == false, (b["Power Source State"] as? String) == "AC Power" { minutes = nil }
        return BatteryInfo(
            hasBattery: true, percent: percent, charging: charging,
            powerSource: b["Power Source State"] as? String, minutesRemaining: minutes)
    }
}

public struct FrontmostApp: Codable, Sendable, Equatable {
    public var name: String?
    public var bundleId: String?
    public init(name: String?, bundleId: String?) {
        self.name = name
        self.bundleId = bundleId
    }
}

/// Everything that touches the OS. Faked in tests.
public protocol SystemControlling: Sendable {
    func volume() async throws -> VolumeState
    func setVolume(_ volume: Int?, muted: Bool?) async throws
    func mediaKey(_ action: MediaAction) async throws
    func clipboardText() async throws -> String?
    func setClipboardText(_ text: String) async throws
    func sleepDisplay() async throws
    func sleepMac() async throws
    /// Returns true if the screen was locked, false if it fell back to sleeping the display.
    func lockScreen() async throws -> Bool
    func battery() async throws -> BatteryInfo
    func open(url: URL) async throws
    func openApp(_ nameOrBundleID: String) async throws
    func frontmostApp() async throws -> FrontmostApp
}

/// The real implementation.
public struct LiveSystemControl: SystemControlling {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = CommandRunner()) { self.runner = runner }

    private func osascript(_ script: String) async throws -> String {
        let r: CommandResult
        do {
            r = try await runner.run(URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", script], stdin: nil)
        } catch {
            throw ToolError.unavailable("osascript could not be launched: \(error.localizedDescription)")
        }
        guard r.succeeded else {
            throw ToolError.failed(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return r.stdout
    }

    private func pmset(_ arg: String) async throws {
        let r = try await runner.run(URL(fileURLWithPath: "/usr/bin/pmset"), arguments: [arg], stdin: nil)
        guard r.succeeded else { throw ToolError.failed(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    public func volume() async throws -> VolumeState {
        VolumeState.parse(osascript: try await osascript("get volume settings"))
    }

    public func setVolume(_ volume: Int?, muted: Bool?) async throws {
        if let volume { _ = try await osascript("set volume output volume \(min(100, max(0, volume)))") }
        if let muted { _ = try await osascript("set volume output muted \(muted ? "true" : "false")") }
    }

    public func mediaKey(_ action: MediaAction) async throws {
        guard AXIsProcessTrusted() else {
            throw ToolError.unavailable(
                "Posting media keys needs Accessibility access. Enable Apnum in System Settings > Privacy & Security > Accessibility, then try again.")
        }
        let key: Int = switch action {
        case .play_pause: 16  // NX_KEYTYPE_PLAY
        case .next: 17  // NX_KEYTYPE_NEXT
        case .previous: 18  // NX_KEYTYPE_PREVIOUS
        }
        for down in [true, false] {
            let flags = down ? 0xa00 : 0xb00
            let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                data1: (key << 16) | flags, data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    public func clipboardText() async throws -> String? {
        await MainActor.run { NSPasteboard.general.string(forType: .string) }
    }

    public func setClipboardText(_ text: String) async throws {
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    public func sleepDisplay() async throws { try await pmset("displaysleepnow") }
    public func sleepMac() async throws { try await pmset("sleepnow") }

    public func lockScreen() async throws -> Bool {
        typealias LockFn = @convention(c) () -> Int32
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY),
            let symbol = dlsym(handle, "SACLockScreenImmediate")
        {
            _ = unsafeBitCast(symbol, to: LockFn.self)()
            return true
        }
        try await sleepDisplay()
        return false
    }

    public func battery() async throws -> BatteryInfo {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return BatteryInfo(hasBattery: false) }
        let sources = list.compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
        return BatteryInfo.parse(sources: sources)
    }

    public func open(url: URL) async throws {
        let ok = await MainActor.run { NSWorkspace.shared.open(url) }
        if !ok { throw ToolError.failed("macOS could not open \(url.scheme ?? "the") URL") }
    }

    public func openApp(_ nameOrBundleID: String) async throws {
        let target = nameOrBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let appURL: URL? = await MainActor.run {
            if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target) { return u }
            let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
            let name = target.hasSuffix(".app") ? target : target + ".app"
            return dirs.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        }
        guard let appURL else { throw ToolError.notFound("No app named or with bundle id '\(target)'") }
        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            throw ToolError.failed("Could not open \(target): \(error.localizedDescription)")
        }
    }

    public func frontmostApp() async throws -> FrontmostApp {
        await MainActor.run {
            let app = NSWorkspace.shared.frontmostApplication
            return FrontmostApp(name: app?.localizedName, bundleId: app?.bundleIdentifier)
        }
    }
}
