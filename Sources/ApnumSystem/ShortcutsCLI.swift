import ApnumCore
import Foundation

/// Runs macOS Shortcuts through `/usr/bin/shortcuts`.
public struct ShortcutsCLI: ShortcutRunning {
    private let runner: any CommandRunning
    private let executable: URL

    public init(runner: any CommandRunning = CommandRunner(), executable: URL = URL(fileURLWithPath: "/usr/bin/shortcuts")) {
        self.runner = runner
        self.executable = executable
    }

    public func list() async throws -> [String] {
        let result = try await exec(["list"])
        return result.stdout.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public func run(_ name: String, input: Data?) async throws -> Data {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ToolError.invalidInput("shortcut name is empty") }
        guard !trimmed.hasPrefix("-") else { throw ToolError.invalidInput("shortcut name must not start with '-'") }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apnum-shortcut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }

        let outURL = dir.appendingPathComponent("output")
        var args = ["run", trimmed]
        if let input {
            let inURL = dir.appendingPathComponent("input")
            try input.write(to: inURL)
            args += ["--input-path", inURL.path]
        }
        args += ["--output-path", outURL.path]
        _ = try await exec(args)
        return (try? Data(contentsOf: outURL)) ?? Data()
    }

    private func exec(_ args: [String]) async throws -> CommandResult {
        let result: CommandResult
        do {
            result = try await runner.run(executable, arguments: args, stdin: nil)
        } catch {
            throw ToolError.unavailable("Could not launch the shortcuts tool: \(error.localizedDescription)")
        }
        guard result.succeeded else {
            let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ToolError.failed(text.isEmpty ? "shortcuts exited with status \(result.exitCode)" : text)
        }
        return result
    }
}
