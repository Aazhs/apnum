import ApnumCore
import AppKit
import Foundation
import Synchronization
@preconcurrency import UserNotifications

/// Rings alarms and timers: a time-sensitive notification with Stop/Snooze
/// actions plus a looping system sound. Also posts plain notifications.
///
/// Construct it on the main actor (the app's composition root). Without an app
/// bundle (for example under `swift test`) notifications are skipped, never crashed on.
public final class MacRinger: Ringer, Notifying, Sendable {
    public typealias Responder = @Sendable (RingRequest.Kind, String, RingResponse) async -> Void

    private final class ResponderBox: Sendable {
        let value = Mutex<Responder?>(nil)
    }
    private let responder = ResponderBox()
    private let engine: Engine

    /// - Parameters:
    ///   - playsSound: loop a system sound while ringing.
    ///   - notificationsAvailable: override bundle detection (tests).
    @MainActor
    public init(playsSound: Bool = true, notificationsAvailable: Bool? = nil) {
        let available = notificationsAvailable
            ?? (Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app")
        let box = responder
        engine = Engine(playsSound: playsSound, notificationsAvailable: available, responder: { box.value.withLock { $0 } })
    }

    /// Routes Stop/Snooze taps (and notification dismissal or click, which count as stop) back to the alarm/timer tools.
    public func setResponder(_ handler: @escaping @Sendable (RingRequest.Kind, String, RingResponse) async -> Void) {
        responder.value.withLock { $0 = handler }
    }

    /// Asks macOS for permission to show notifications. False when denied or when running without a bundle.
    public func requestNotificationPermission() async -> Bool {
        await engine.requestPermission()
    }

    public func start(_ request: RingRequest) async { await engine.start(request) }
    public func stop(id: String) async { await engine.stop(id: id) }

    public func notify(title: String, body: String) async throws { try await engine.notify(title: title, body: body) }

    // MARK: Engine

    @MainActor
    private final class Engine: NSObject, UNUserNotificationCenterDelegate {
        struct Ring {
            var sound: NSSound?
            var timeout: Task<Void, Never>
        }

        static let maxRingDuration: Duration = .seconds(600)
        static let snoozeCategory = "apnum.ring.snooze"
        static let stopCategory = "apnum.ring.stop"

        let playsSound: Bool
        let notificationsAvailable: Bool
        let responder: @Sendable () -> Responder?
        var rings: [String: Ring] = [:]

        init(playsSound: Bool, notificationsAvailable: Bool, responder: @escaping @Sendable () -> Responder?) {
            self.playsSound = playsSound
            self.notificationsAvailable = notificationsAvailable
            self.responder = responder
            super.init()
            guard notificationsAvailable else { return }
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            let stop = UNNotificationAction(identifier: "stop", title: "Stop", options: [])
            let snooze = UNNotificationAction(identifier: "snooze", title: "Snooze", options: [])
            center.setNotificationCategories([
                UNNotificationCategory(identifier: Self.snoozeCategory, actions: [stop, snooze], intentIdentifiers: [], options: [.customDismissAction]),
                UNNotificationCategory(identifier: Self.stopCategory, actions: [stop], intentIdentifiers: [], options: [.customDismissAction]),
            ])
        }

        func requestPermission() async -> Bool {
            guard notificationsAvailable else { return false }
            return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        }

        func start(_ request: RingRequest) async {
            stopLocally(id: request.id)  // restart cleanly if already ringing
            let timeout = Task { [weak self] in
                try? await Task.sleep(for: Self.maxRingDuration)
                guard !Task.isCancelled else { return }
                // Treat an unanswered ring as Stop so the alarm/timer state is cleared too.
                await self?.handle(kind: request.kind, id: request.id, response: .stop)
            }
            var sound: NSSound?
            if playsSound {
                sound = NSSound(named: request.sound ?? "Glass") ?? NSSound(named: "Glass") ?? NSSound(named: "Ping")
                sound?.loops = true
                sound?.play()
            }
            rings[request.id] = Ring(sound: sound, timeout: timeout)

            guard notificationsAvailable else { return }
            let content = UNMutableNotificationContent()
            content.title = request.title
            content.body = request.body
            content.categoryIdentifier = request.canSnooze ? Self.snoozeCategory : Self.stopCategory
            content.interruptionLevel = .timeSensitive
            content.userInfo = ["id": request.id, "kind": request.kind.rawValue]
            let notification = UNNotificationRequest(identifier: Self.identifier(request.id), content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(notification)
        }

        func stop(id: String) async {
            stopLocally(id: id)
            guard notificationsAvailable else { return }
            let center = UNUserNotificationCenter.current()
            center.removeDeliveredNotifications(withIdentifiers: [Self.identifier(id)])
            center.removePendingNotificationRequests(withIdentifiers: [Self.identifier(id)])
        }

        private func stopLocally(id: String) {
            guard let ring = rings.removeValue(forKey: id) else { return }
            ring.timeout.cancel()
            ring.sound?.stop()
        }

        static func identifier(_ id: String) -> String { "apnum.ring.\(id)" }

        func notify(title: String, body: String) async throws {
            guard notificationsAvailable else {
                throw ToolError.unavailable("Notifications need the bundled Apnum app (no bundle identifier in this process).")
            }
            let center = UNUserNotificationCenter.current()
            var status = await center.notificationSettings().authorizationStatus
            if status == .notDetermined {
                _ = await requestPermission()
                status = await center.notificationSettings().authorizationStatus
            }
            guard status == .authorized || status == .provisional else {
                throw ToolError.unavailable("Notifications are not allowed for Apnum. Enable them in System Settings > Notifications.")
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            do {
                try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            } catch {
                throw ToolError.failed("Could not post notification: \(error.localizedDescription)")
            }
        }

        // MARK: UNUserNotificationCenterDelegate

        nonisolated func userNotificationCenter(
            _ center: UNUserNotificationCenter, willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            [.banner, .list]
        }

        nonisolated func userNotificationCenter(
            _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
        ) async {
            let info = response.notification.request.content.userInfo
            guard let id = info["id"] as? String, let kindRaw = info["kind"] as? String,
                let kind = RingRequest.Kind(rawValue: kindRaw)
            else { return }
            let answer: RingResponse = response.actionIdentifier == "snooze" ? .snooze : .stop
            await handle(kind: kind, id: id, response: answer)
        }

        func handle(kind: RingRequest.Kind, id: String, response: RingResponse) async {
            await stop(id: id)
            await responder()?(kind, id, response)
        }
    }
}
