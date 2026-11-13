import ApnumCore
import Foundation

/// Implemented by the app so tools and the Settings UI share one state.
public protocol UpdateControlling: Sendable {
    func checkForUpdate() async throws -> UpdateStatus
    /// Installs the latest release and relaunches. Never installs over an ad-hoc signed app.
    func installUpdate() async throws
}

public func makeUpdateTools(controller: any UpdateControlling) -> [AnyTool] {
    [AnyTool(UpdateCheckTool(controller: controller)), AnyTool(UpdateInstallTool(controller: controller))]
}

struct UpdateCheckTool: Tool {
    let controller: any UpdateControlling
    static let name = "app.update.check"
    static let summary = "Check GitHub for a newer apnum release; returns current, latest, available, notes and url."
    static let tier = PermissionTier.read
    static let inputSchema = Schema.empty
    func run(_ input: Empty, context: ToolContext) async throws -> UpdateStatus {
        do { return try await controller.checkForUpdate() } catch { throw ToolError.failed(error.localizedDescription) }
    }
}

struct UpdateInstallTool: Tool {
    let controller: any UpdateControlling
    static let name = "app.update.install"
    static let summary = "Download the latest apnum release, replace this app with it and relaunch. The app restarts."
    static let tier = PermissionTier.dangerous
    static let inputSchema = Schema.empty
    func run(_ input: Empty, context: ToolContext) async throws -> Ack {
        do {
            try await controller.installUpdate()
            return Ack(ok: true, message: "Installed. apnum is restarting.")
        } catch { throw ToolError.failed(error.localizedDescription) }
    }
}
