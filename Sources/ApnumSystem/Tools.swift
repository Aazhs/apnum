import ApnumCore
import Foundation

/// Posts a plain (non-ringing) notification. Implemented by `MacRinger`.
public protocol Notifying: Sendable {
    func notify(title: String, body: String) async throws
}

/// Builds all Mac-integration tools.
public struct SystemService: Sendable {
    public let control: any SystemControlling
    public let shortcuts: any ShortcutRunning
    public let notifier: any Notifying

    public init(control: any SystemControlling, shortcuts: any ShortcutRunning, notifier: any Notifying) {
        self.control = control
        self.shortcuts = shortcuts
        self.notifier = notifier
    }

    /// Real OS control and the `shortcuts` CLI.
    public static func live(notifier: any Notifying) -> SystemService {
        SystemService(control: LiveSystemControl(), shortcuts: ShortcutsCLI(), notifier: notifier)
    }

    public func makeTools() -> [AnyTool] { makeSystemTools(control: control, shortcuts: shortcuts, notifier: notifier) }
}

public func makeSystemTools(control: any SystemControlling, shortcuts: any ShortcutRunning, notifier: any Notifying) -> [AnyTool] {
    [
        AnyTool(VolumeGetTool(control: control)),
        AnyTool(VolumeSetTool(control: control)),
        AnyTool(MediaControlTool(control: control)),
        AnyTool(ClipboardGetTool(control: control)),
        AnyTool(ClipboardSetTool(control: control)),
        AnyTool(DisplaySleepTool(control: control)),
        AnyTool(SleepTool(control: control)),
        AnyTool(LockTool(control: control)),
        AnyTool(BatteryTool(control: control)),
        AnyTool(OpenTool(control: control)),
        AnyTool(NotifyTool(notifier: notifier)),
        AnyTool(FrontmostAppTool(control: control)),
        AnyTool(ShortcutsListTool(shortcuts: shortcuts)),
        AnyTool(ShortcutsRunTool(shortcuts: shortcuts)),
    ]
}

// MARK: - Volume

struct VolumeGetTool: Tool {
    let control: any SystemControlling
    typealias Output = VolumeState
    static let name = "mac.volume.get"
    static let summary = "Get the Mac's output volume (0-100) and whether it is muted."
    static let tier = PermissionTier.read
    static let inputSchema = Schema.empty
    func run(_ input: Empty, context: ToolContext) async throws -> VolumeState { try await control.volume() }
}

struct VolumeSetTool: Tool {
    struct Input: Codable, Sendable, Equatable {
        var volume: Int?
        var muted: Bool?
    }
    let control: any SystemControlling
    static let name = "mac.volume.set"
    static let summary = "Set the Mac's output volume (0-100) and/or mute or unmute it. Provide at least one of volume or muted."
    static let tier = PermissionTier.write
    static let inputSchema = Schema.object([
        "volume": .integer("Output volume, 0 (silent) to 100", minimum: 0, maximum: 100),
        "muted": .boolean("true to mute, false to unmute"),
    ])

    static func validate(_ input: Input) throws {
        guard input.volume != nil || input.muted != nil else {
            throw ToolError.invalidInput("provide volume and/or muted")
        }
        if let v = input.volume, !(0...100).contains(v) {
            throw ToolError.invalidInput("volume must be between 0 and 100")
        }
    }

    func run(_ input: Input, context: ToolContext) async throws -> VolumeState {
        try Self.validate(input)
        try await control.setVolume(input.volume, muted: input.muted)
        return try await control.volume()
    }
}

// MARK: - Media

struct MediaControlTool: Tool {
    struct Input: Codable, Sendable { var action: MediaAction }
    let control: any SystemControlling
    static let name = "mac.media.control"
    static let summary = "Send a media key to whatever app is playing: play_pause, next or previous. Needs Accessibility access."
    static let tier = PermissionTier.write
    static let inputSchema = Schema.object(
        ["action": .string("Which media key to press", enumValues: MediaAction.allCases.map(\.rawValue))], required: ["action"])
    func run(_ input: Input, context: ToolContext) async throws -> Ack {
        try await control.mediaKey(input.action)
        return Ack(message: "Sent \(input.action.rawValue)")
    }
}

// MARK: - Clipboard

struct ClipboardGetTool: Tool {
    struct Output: Codable, Sendable, Equatable { var text: String? }
    let control: any SystemControlling
    static let name = "mac.clipboard.get"
    static let summary = "Read the plain text on the Mac clipboard (text is null if the clipboard holds no text)."
    static let tier = PermissionTier.read
    static let inputSchema = Schema.empty
    func run(_ input: Empty, context: ToolContext) async throws -> Output { Output(text: try await control.clipboardText()) }
}

struct ClipboardSetTool: Tool {
    struct Input: Codable, Sendable { var text: String }
    let control: any SystemControlling
    static let name = "mac.clipboard.set"
    static let summary = "Replace the Mac clipboard contents with plain text."
    static let tier = PermissionTier.write
    static let inputSchema = Schema.object(["text": .string("Text to place on the clipboard")], required: ["text"])
    func run(_ input: Input, context: ToolContext) async throws -> Ack {
        try await control.setClipboardText(input.text)
        return Ack()
    }
}

// MARK: - Power

struct DisplaySleepTool: Tool {
    let control: any SystemControlling
    static let name = "mac.display.sleep"
    static let summary = "Turn the Mac's display off now (the Mac keeps running)."
    static let tier = PermissionTier.write
    static let inputSchema = Schema.empty
    func run(_ input: Empty, context: ToolContext) async throws -> Ack {
        try await control.sleepDisplay()
        return Ack()
    }
}

struct SleepTool: Tool {
    let control: any SystemControlling
    static let name = "mac.sleep"
    static let summary = "Put the whole Mac to sleep now. It cannot be woken remotely; someone must touch it."
    static let tier = PermissionTier.dangerous
    static let inputSchema = Schema.empty
    func run(_ input: Empty, context: ToolContext) async throws -> Ack {
        try await control.sleepMac()
        return Ack()
    }
}

struct LockTool: Tool {
    let control: any SystemControlling
    static let name = "mac.lock"
    static let summary = "Lock the Mac's screen so a password is needed to continue."
    static let tier = PermissionTier.write
    static let inputSchema = Schema.empty
    func run(_ input: Empty, context: ToolContext) async throws -> Ack {
        if try await control.lockScreen() { return Ack(message: "Screen locked") }
        return Ack(message: "Could not lock directly; turned the display off instead (a password may not be required)")
    }
}

struct BatteryTool: Tool {
    let control: any SystemControlling
    typealias Output = BatteryInfo
    static let name = "mac.battery"
    static let summary = "Get battery percent, charging state, power source and minutes remaining (hasBattery is false on desktop Macs)."
    static let tier = PermissionTier.read
    static let inputSchema = Schema.empty
    func run(_ input: Empty, context: ToolContext) async throws -> BatteryInfo { try await control.battery() }
}

// MARK: - Open / notify / apps

enum OpenTarget: Equatable {
    case url(URL)
    case app(String)
}

struct OpenTool: Tool {
    struct Input: Codable, Sendable { var url: String?; var app: String? }
    let control: any SystemControlling
    static let name = "mac.open"
    static let summary = "Open a web/mailto/tel link in its default app, or launch an app by name or bundle id. Provide exactly one of url or app."
    static let tier = PermissionTier.dangerous
    static let inputSchema = Schema.object([
        "url": .string("An http, https, mailto or tel URL"),
        "app": .string("App name (e.g. Safari) or bundle id (e.g. com.apple.Safari)"),
    ])

    static let allowedSchemes: Set<String> = ["http", "https", "mailto", "tel"]

    static func validate(_ input: Input) throws -> OpenTarget {
        let url = input.url?.trimmingCharacters(in: .whitespacesAndNewlines)
        let app = input.app?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (url?.isEmpty == false ? url : nil, app?.isEmpty == false ? app : nil) {
        case (nil, nil): throw ToolError.invalidInput("provide url or app")
        case (.some, .some): throw ToolError.invalidInput("provide only one of url or app")
        case (.some(let u), nil):
            guard let parsed = URL(string: u), let scheme = parsed.scheme?.lowercased() else {
                throw ToolError.invalidInput("not a valid URL")
            }
            guard allowedSchemes.contains(scheme) else {
                throw ToolError.invalidInput("scheme '\(scheme)' is not allowed; use http, https, mailto or tel")
            }
            return .url(parsed)
        case (nil, .some(let a)):
            guard !a.contains("/") else { throw ToolError.invalidInput("app must be a name or bundle id, not a path") }
            return .app(a)
        }
    }

    func run(_ input: Input, context: ToolContext) async throws -> Ack {
        switch try Self.validate(input) {
        case .url(let u): try await control.open(url: u)
        case .app(let a): try await control.openApp(a)
        }
        return Ack()
    }
}

struct NotifyTool: Tool {
    struct Input: Codable, Sendable { var title: String; var body: String? }
    let notifier: any Notifying
    static let name = "mac.notify"
    static let summary = "Show a notification on the Mac with a title and optional body."
    static let tier = PermissionTier.write
    static let inputSchema = Schema.object(
        ["title": .string("Notification title"), "body": .string("Notification text")], required: ["title"])
    func run(_ input: Input, context: ToolContext) async throws -> Ack {
        guard !input.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.invalidInput("title is empty")
        }
        try await notifier.notify(title: input.title, body: input.body ?? "")
        return Ack()
    }
}

struct FrontmostAppTool: Tool {
    let control: any SystemControlling
    typealias Output = FrontmostApp
    static let name = "mac.apps.frontmost"
    static let summary = "Get the name and bundle id of the app currently in front on the Mac."
    static let tier = PermissionTier.read
    static let inputSchema = Schema.empty
    func run(_ input: Empty, context: ToolContext) async throws -> FrontmostApp { try await control.frontmostApp() }
}

// MARK: - Shortcuts

struct ShortcutsListTool: Tool {
    struct Output: Codable, Sendable, Equatable { var shortcuts: [String] }
    let shortcuts: any ShortcutRunning
    static let name = "shortcuts.list"
    static let summary = "List the names of the shortcuts installed in the Shortcuts app."
    static let tier = PermissionTier.read
    static let inputSchema = Schema.empty
    func run(_ input: Empty, context: ToolContext) async throws -> Output { Output(shortcuts: try await shortcuts.list()) }
}

struct ShortcutsRunTool: Tool {
    struct Input: Codable, Sendable { var name: String; var input: String? }
    struct Output: Codable, Sendable, Equatable { var output: String }
    let shortcuts: any ShortcutRunning
    static let name = "shortcuts.run"
    static let summary = "Run a Shortcuts-app shortcut by exact name, optionally with text input, and return its text output. Shortcuts can do anything, so this needs approval."
    static let tier = PermissionTier.dangerous
    static let inputSchema = Schema.object([
        "name": .string("Exact shortcut name, as returned by shortcuts.list"),
        "input": .string("Optional text passed to the shortcut as input"),
    ], required: ["name"])
    func run(_ input: Input, context: ToolContext) async throws -> Output {
        guard !input.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.invalidInput("name is empty")
        }
        let data = try await shortcuts.run(input.name, input: input.input.map { Data($0.utf8) })
        return Output(output: String(decoding: data, as: UTF8.self))
    }
}
