import ApnumCore
import Foundation

public extension ChangeTopic {
    /// Link status changed (connected, disconnected, paired, unpaired, settings).
    static let link: ChangeTopic = "link"
    /// The cached phone state changed (battery, messages, notifications, call, code).
    static let phone: ChangeTopic = "phone"
}

public enum LinkStatus: Sendable, Equatable {
    case off
    case notPaired
    case waitingForPhone
    case connected(device: PairedDevice, since: Date)
}

/// What the Mac shows while pairing: a QR code (the uri), a typed code and an expiry.
public struct PairingOffer: Sendable, Equatable {
    public let uri: String
    public let code: String
    public let expiresAt: Date
    /// This Mac's key fingerprint, e.g. "4F2A 91C0 7B3E 55D1".
    public let fingerprint: String
    public let host: String
    public let port: UInt16

    public init(uri: String, code: String, expiresAt: Date, fingerprint: String, host: String = "", port: UInt16 = 0) {
        self.uri = uri
        self.code = code
        self.expiresAt = expiresAt
        self.fingerprint = fingerprint
        self.host = host
        self.port = port
    }
}

public struct PhoneSMS: Sendable, Equatable, Identifiable, Codable {
    public var id: String
    public var address: String
    public var contactName: String?
    public var body: String
    public var date: Date
    public var incoming: Bool

    public var title: String { (contactName?.isEmpty == false ? contactName : nil) ?? address }

    public init(id: String, address: String, contactName: String? = nil, body: String, date: Date, incoming: Bool = true) {
        self.id = id
        self.address = address
        self.contactName = contactName
        self.body = body
        self.date = date
        self.incoming = incoming
    }
}

public struct PhoneNotification: Sendable, Equatable, Identifiable {
    public var key: String
    public var app: String
    public var title: String
    public var text: String
    public var posted: Date
    public var id: String { key }

    public init(key: String, app: String, title: String, text: String, posted: Date) {
        self.key = key
        self.app = app
        self.title = title
        self.text = text
        self.posted = posted
    }
}

public struct PhoneCall: Sendable, Equatable {
    /// `idle`, `ringing` or `offhook`.
    public var state: String = "idle"
    public var number: String?
    public var contactName: String?

    public init(state: String = "idle", number: String? = nil, contactName: String? = nil) {
        self.state = state
        self.number = number
        self.contactName = contactName
    }
}

public struct PhoneCode: Sendable, Equatable {
    public var code: String
    public var from: String
    public var date: Date

    public init(code: String, from: String, date: Date) {
        self.code = code
        self.from = from
        self.date = date
    }
}

/// What the Mac knows about the connected phone, kept current from its events.
public struct PhoneState: Sendable, Equatable {
    public var battery: Int?
    public var charging: Bool?
    /// The last `phone.info` output.
    public var info: JSONValue?
    /// Newest first, at most 50.
    public var messages: [PhoneSMS] = []
    public var notifications: [PhoneNotification] = []
    public var call = PhoneCall()
    public var latestCode: PhoneCode?

    public init() {}

    /// The phone model from `phone.info`, if it reported one.
    public var model: String? { Self.text(info, ["model", "deviceModel"]) }
    /// The Wi-Fi or mobile network name from `phone.info`.
    public var network: String? { Self.text(info, ["network", "networkName", "ssid", "wifi"]) }

    private static func text(_ info: JSONValue?, _ keys: [String]) -> String? {
        guard let info else { return nil }
        for key in keys {
            if let s = LinkJSON.string(info[key]), !s.isEmpty { return s }
            if let inner = info[key], let s = LinkJSON.string(inner["name"]) ?? LinkJSON.string(inner["ssid"]), !s.isEmpty { return s }
        }
        return nil
    }
}

enum LinkJSON {
    static func string(_ v: JSONValue?) -> String? { if case .string(let s)? = v { return s } else { return nil } }
    static func number(_ v: JSONValue?) -> Double? { if case .number(let n)? = v { return n } else { return nil } }
    static func bool(_ v: JSONValue?) -> Bool? { if case .bool(let b)? = v { return b } else { return nil } }
    static func date(ms v: JSONValue?) -> Date? { number(v).map { Date(timeIntervalSince1970: $0 / 1000) } }

    static func encode(_ value: JSONValue) -> Data { (try? JSONCoding.encoder.encode(value)) ?? Data("{}".utf8) }
    static func decode(_ data: Data) -> JSONValue? { try? JSONCoding.decoder.decode(JSONValue.self, from: data) }

    static func errorCode(_ error: any Error) -> (String, String) {
        switch error as? ToolError {
        case .notFound(let m)?: ("notFound", m)
        case .invalidInput(let m)?: ("invalidInput", m)
        case .denied(let m)?: ("denied", m)
        case .unavailable(let m)?: ("unavailable", m)
        case .failed(let m)?: ("failed", m)
        case nil: ("failed", error.localizedDescription)
        }
    }

    static func toolError(code: String, message: String) -> ToolError {
        switch code {
        case "notFound": .notFound(message)
        case "invalidInput": .invalidInput(message)
        case "denied": .denied(message)
        case "unavailable": .unavailable(message)
        default: .failed(message)
        }
    }
}
