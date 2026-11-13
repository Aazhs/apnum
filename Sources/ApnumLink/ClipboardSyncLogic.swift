import Foundation

/// The decisions behind clipboard sync, with no pasteboard in it so they can be tested: what to send when the Mac
/// pasteboard changes, what to apply from the phone, and how to avoid echoing a copy back to where it came from.
public struct ClipboardSyncLogic: Sendable {
    public static let maxLength = 100_000
    /// Pasteboard types password managers use to mark an item as secret or short-lived.
    public static let privateTypes: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]

    private var lastChangeCount: Int
    /// The last text we sent to or received from the phone; a pasteboard holding it is not a new copy.
    private var lastExchanged: String?

    public init(changeCount: Int = 0) { lastChangeCount = changeCount }

    /// The change count already accounted for.
    public var baseline: Int { lastChangeCount }

    /// Call when the pasteboard's change count moved. Returns the text to send, or nil to stay quiet.
    public mutating func observe(changeCount: Int, types: [String], text: String?) -> String? {
        guard changeCount != lastChangeCount else { return nil }
        lastChangeCount = changeCount
        return candidate(types: types, text: text)
    }

    /// For a manual "Send now": same filters, but ignores whether the pasteboard changed or was already sent.
    public mutating func forced(types: [String], text: String?) -> String? {
        guard let text = candidate(types: types, text: text, allowRepeat: true) else { return nil }
        return text
    }

    /// Call with text from the phone. Returns the text to put on the pasteboard, or nil when it is an echo or unusable.
    public mutating func receive(_ text: String) -> String? {
        guard !text.isEmpty, text.count <= Self.maxLength, text != lastExchanged else { return nil }
        lastExchanged = text
        return text
    }

    /// Call right after writing received text to the pasteboard, so that write is not mistaken for a local copy.
    public mutating func didWrite(changeCount: Int) { lastChangeCount = changeCount }

    /// Forgets the baseline (when sync starts again after being off), so what was copied meanwhile is not sent.
    public mutating func reset(changeCount: Int) {
        lastChangeCount = changeCount
        lastExchanged = nil
    }

    private mutating func candidate(types: [String], text: String?, allowRepeat: Bool = false) -> String? {
        guard Self.privateTypes.isDisjoint(with: types) else { return nil }
        guard let text, !text.isEmpty, text.count <= Self.maxLength else { return nil }
        if !allowRepeat, text == lastExchanged { return nil }
        lastExchanged = text
        return text
    }
}
