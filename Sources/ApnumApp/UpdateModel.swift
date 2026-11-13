import AppKit
import ApnumUpdate
import Foundation
import Observation

/// Owns update state for the Settings screen, the sidebar hint and the `app.update.*` tools.
/// Checks at launch and then at most once a day with a single sleeping task (no polling); never downloads on its own.
@MainActor @Observable
final class UpdateModel: UpdateControlling {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading(Double)
        case installing
        case failed(String)
    }

    static let autoKey = "checkForUpdatesAutomatically"
    private static let lastCheckKey = "lastUpdateCheck"
    private static let day: TimeInterval = 86_400

    private(set) var phase: Phase = .idle
    private(set) var status: UpdateStatus?
    /// Set when the failure was the ad-hoc refusal, so the UI can offer "Install anyway".
    private(set) var canInstallAnyway = false

    @ObservationIgnored private var release: Release?
    @ObservationIgnored private var autoTask: Task<Void, Never>?
    @ObservationIgnored private let checker: UpdateChecker
    @ObservationIgnored private let updater: Updater
    @ObservationIgnored private let defaults: UserDefaults

    var updateAvailable: Bool { status?.available == true }
    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing: true
        default: false
        }
    }

    var currentVersionText: String {
        checker.isDevelopmentBuild ? "development build" : checker.currentVersion.description
    }

    init(defaults: UserDefaults = .standard) {
        let text = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        checker = UpdateChecker(currentVersionText: text)
        updater = Updater()
        self.defaults = defaults
    }

    var automaticChecks: Bool { defaults.object(forKey: Self.autoKey) as? Bool ?? true }

    /// Call once at launch, and again when the setting changes.
    func scheduleAutomaticChecks() {
        autoTask?.cancel()
        autoTask = nil
        guard automaticChecks, Bundle.main.bundleURL.pathExtension == "app" else { return }
        autoTask = Task { [weak self] in
            while !Task.isCancelled, let self {
                let last = self.defaults.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
                let due = last.addingTimeInterval(Self.day)
                if due > .now { try? await Task.sleep(for: .seconds(due.timeIntervalSinceNow)) }
                guard !Task.isCancelled, self.automaticChecks else { return }
                await self.check(quiet: true)
                // A failed check still counts, so a flaky network does not retry in a loop.
                self.defaults.set(Date.now, forKey: Self.lastCheckKey)
            }
        }
    }

    /// Checks GitHub. A quiet check (automatic) leaves the screen unchanged when it fails.
    func check(quiet: Bool = false) async {
        guard !isBusy else { return }
        let before = phase
        phase = .checking
        do {
            let result = try await checker.check()
            status = result.status
            release = result.release
            phase = result.status.available ? .available : .upToDate
            defaults.set(Date.now, forKey: Self.lastCheckKey)
        } catch {
            phase = quiet ? before : .failed(Self.message(error))
        }
    }

    func install(allowAdHoc: Bool = false) async {
        guard let release, !isBusy else { return }
        canInstallAnyway = false
        phase = .downloading(0)
        do {
            try updater.checkInstallable()
            let bundle = try await updater.install(release, allowAdHoc: allowAdHoc) { [weak self] fraction in
                Task { @MainActor in self?.phase = .downloading(fraction) }
            }
            phase = .installing
            Updater.relaunch(bundle)
            try? await Task.sleep(for: .milliseconds(300))
            NSApp.terminate(nil)
        } catch {
            canInstallAnyway = (error as? UpdateError) == .adHocRunningApp
            phase = .failed(Self.message(error))
        }
    }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: UpdateControlling (for the tools)

    func checkForUpdate() async throws -> UpdateStatus {
        await check()
        if case .failed(let message) = phase { throw ToolFailure(message: message) }
        guard let status else { throw ToolFailure(message: "No update information.") }
        return status
    }

    func installUpdate() async throws {
        if release == nil { _ = try await checkForUpdate() }
        guard status?.available == true else { throw ToolFailure(message: "apnum is already up to date.") }
        await install(allowAdHoc: false)
        if case .failed(let message) = phase { throw ToolFailure(message: message) }
    }

    private struct ToolFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
