import Foundation

/// A dotted numeric version such as `0.10.0`. Compares component by component, so 0.10.0 > 0.9.9.
/// A leading `v` and any `-prerelease` or `+build` suffix are ignored; missing components count as 0.
public struct AppVersion: Comparable, Sendable, Hashable, CustomStringConvertible {
    public let components: [Int]

    public init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.first == "v" || s.first == "V" { s.removeFirst() }
        if let cut = s.firstIndex(where: { $0 == "-" || $0 == "+" }) { s = String(s[..<cut]) }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var out: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy(\.isASCII), let n = Int(p), n >= 0 else { return nil }
            out.append(n)
        }
        components = out
    }

    public static let zero = AppVersion("0.0.0")!

    public var description: String { components.map(String.init).joined(separator: ".") }

    private func padded(_ n: Int) -> [Int] { components + Array(repeating: 0, count: max(0, n - components.count)) }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.components.count, b.components.count)
        return a.padded(n).lexicographicallyPrecedes(b.padded(n))
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.components.count, b.components.count)
        return a.padded(n) == b.padded(n)
    }

    public func hash(into hasher: inout Hasher) {
        var c = components
        while c.last == 0 { c.removeLast() }
        hasher.combine(c)
    }
}

/// The parts of a GitHub release apnum cares about.
public struct Release: Sendable, Equatable {
    public struct Asset: Sendable, Equatable {
        public let name: String
        public let url: URL
        public init(name: String, url: URL) {
            self.name = name
            self.url = url
        }
    }

    public let tag: String
    public let version: AppVersion
    public let notes: String
    public let pageURL: URL?
    public let assets: [Asset]

    public init(tag: String, version: AppVersion, notes: String, pageURL: URL?, assets: [Asset]) {
        self.tag = tag
        self.version = version
        self.notes = notes
        self.pageURL = pageURL
        self.assets = assets
    }

    public static let macAssetName = "Apnum-mac.zip"
    public static let androidAssetName = "apnum-android.apk"

    public var macAsset: Asset? { assets.first { $0.name == Self.macAssetName } }

    /// Parses the body of `GET /repos/Aazhs/apnum/releases/latest`.
    public static func parse(_ data: Data) throws -> Release {
        struct Payload: Decodable {
            struct A: Decodable {
                let name: String
                let browser_download_url: String
            }
            let tag_name: String
            let body: String?
            let html_url: String?
            let assets: [A]?
        }
        let p: Payload
        do { p = try JSONDecoder().decode(Payload.self, from: data) } catch { throw UpdateError.badResponse }
        guard let version = AppVersion(p.tag_name) else { throw UpdateError.badResponse }
        let assets = (p.assets ?? []).compactMap { a in
            URL(string: a.browser_download_url).map { Asset(name: a.name, url: $0) }
        }
        return Release(
            tag: p.tag_name, version: version, notes: p.body ?? "",
            pageURL: p.html_url.flatMap(URL.init(string:)), assets: assets)
    }
}

public enum UpdateError: Error, Equatable, LocalizedError {
    case network(String)
    case badResponse
    case noMacAsset
    case notAnAppBundle
    case notWritable(String)
    case download(String)
    case unzip(String)
    case wrongIdentifier(String?)
    case wrongVersion(expected: String, found: String?)
    case signatureInvalid(String)
    case adHocRunningApp
    case replace(String)

    public var errorDescription: String? {
        switch self {
        case .network(let s): "Could not reach GitHub: \(s)"
        case .badResponse: "GitHub sent a release apnum could not read."
        case .noMacAsset: "That release has no Mac download (Apnum-mac.zip)."
        case .notAnAppBundle:
            "apnum is not running from an app bundle (for example `swift run`), so it cannot update itself. Build one with scripts/bundle.sh."
        case .notWritable(let p): "apnum cannot replace itself because \(p) is not writable. Move apnum to a folder you own, or update it by hand."
        case .download(let s): "The download failed: \(s)"
        case .unzip(let s): "The download could not be unpacked: \(s)"
        case .wrongIdentifier(let id): "The downloaded app is not apnum (identifier \(id ?? "missing")). Nothing was changed."
        case .wrongVersion(let e, let f): "The downloaded app is version \(f ?? "unknown"), not \(e). Nothing was changed."
        case .signatureInvalid(let s): "The downloaded app failed its signature check (\(s)). Nothing was changed."
        case .adHocRunningApp:
            "This copy of apnum is signed ad hoc, so macOS cannot tell that an update comes from the same builder. Rebuild with APNUM_SIGN_IDENTITY set to a signing identity, or choose Install anyway."
        case .replace(let s): "Could not swap in the new version: \(s). The old version was put back."
        }
    }
}
