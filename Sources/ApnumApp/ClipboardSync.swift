import AppKit
import ApnumLink

/// Keeps the Mac pasteboard and the phone clipboard in step. NSPasteboard has no change notification, so while a phone
/// is connected and the setting is on it checks `changeCount` once a second; otherwise nothing runs. The decisions
/// (what to send, echo prevention, concealed types) live in `ClipboardSyncLogic`. Contents are never logged.
@MainActor
final class ClipboardSync {
    private var logic: ClipboardSyncLogic
    private var timer: Timer?
    /// Sends a `clipboard` event to the phone.
    var send: (@MainActor (String) async -> Void)?

    init() { logic = ClipboardSyncLogic(changeCount: NSPasteboard.general.changeCount) }

    var isRunning: Bool { timer != nil }

    /// Starts or stops the watcher. Starting takes the current pasteboard as the baseline, so nothing copied earlier is sent.
    func setActive(_ on: Bool) {
        if on, timer == nil {
            logic.reset(changeCount: NSPasteboard.general.changeCount)
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
            t.tolerance = 0.5
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !on, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }

    private func poll() {
        let pb = NSPasteboard.general
        let count = pb.changeCount
        let types = pb.types?.map(\.rawValue) ?? []
        // Reading the string is the costly part, so only do it when the pasteboard changed.
        guard count != logic.baseline else { return }
        let text = pb.string(forType: .string)
        if let text = logic.observe(changeCount: count, types: types, text: text) { deliver(text) }
    }

    /// The "Send now" fallback: sends whatever plain text is on the pasteboard.
    func sendNow() {
        let pb = NSPasteboard.general
        let types = pb.types?.map(\.rawValue) ?? []
        if let text = logic.forced(types: types, text: pb.string(forType: .string)) { deliver(text) }
    }

    /// Text arrived from the phone: put it on the pasteboard without sending it back.
    func receive(_ text: String) {
        guard let text = logic.receive(text) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        logic.didWrite(changeCount: pb.changeCount)
    }

    private func deliver(_ text: String) {
        guard let send else { return }
        Task { await send(text) }
    }
}
