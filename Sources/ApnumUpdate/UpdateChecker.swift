import ApnumCore
import Foundation

/// Fetches the raw JSON of the latest release. Behind a protocol so tests never touch the network.
public protocol ReleaseFetching: Sendable {
    func latestReleaseJSON() async throws -> Data
}

/// Reads `https://api.github.com/repos/Aazhs/apnum/releases/latest` with no token and a generic User-Agent.
public struct GitHubReleaseFetcher: ReleaseFetching {
    public static let url = URL(string: "https://api.github.com/repos/Aazhs/apnum/releases/latest")!
    public init() {}

    public func latestReleaseJSON() async throws -> Data {
        var request = URLRequest(url: Self.url, timeoutInterval: 20)
        request.setValue("apnum", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw UpdateError.badResponse }
            guard http.statusCode == 200 else {
                throw UpdateError.network(http.statusCode == 404 ? "no release has been published yet" : "HTTP \(http.statusCode)")
            }
            return data
        } catch let e as UpdateError {
            throw e
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }
    }
}

/// What a check found. This is also the output of `app.update.check`.
public struct UpdateStatus: Codable, Sendable, Equatable {
    public var current: String
    public var latest: String
    public var available: Bool
    public var developmentBuild: Bool
    public var notes: String
    public var url: String?

    public init(current: String, latest: String, available: Bool, developmentBuild: Bool, notes: String, url: String?) {
        self.current = current
        self.latest = latest
        self.available = available
        self.developmentBuild = developmentBuild
        self.notes = notes
        self.url = url
    }
}

public struct UpdateChecker: Sendable {
    public let fetcher: any ReleaseFetching
    /// `CFBundleShortVersionString` of the running app; nil or "dev" means a development build.
    public let currentVersionText: String?

    public init(fetcher: any ReleaseFetching = GitHubReleaseFetcher(), currentVersionText: String?) {
        self.fetcher = fetcher
        self.currentVersionText = currentVersionText
    }

    public var currentVersion: AppVersion { currentVersionText.flatMap(AppVersion.init) ?? .zero }
    public var isDevelopmentBuild: Bool { currentVersionText.flatMap(AppVersion.init) == nil }

    public func check() async throws -> (status: UpdateStatus, release: Release) {
        let release = try Release.parse(try await fetcher.latestReleaseJSON())
        let dev = isDevelopmentBuild
        let status = UpdateStatus(
            current: dev ? "development build" : currentVersion.description,
            latest: release.version.description,
            available: release.version > currentVersion,
            developmentBuild: dev,
            notes: release.notes,
            url: release.pageURL?.absoluteString)
        return (status, release)
    }
}
