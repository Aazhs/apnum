import ApnumCore
import Foundation
import Testing

@testable import ApnumUpdate

private let sampleJSON = """
    {
      "url": "https://api.github.com/repos/Aazhs/apnum/releases/1",
      "html_url": "https://github.com/Aazhs/apnum/releases/tag/v0.10.0",
      "id": 1, "tag_name": "v0.10.0", "name": "apnum 0.10.0", "draft": false, "prerelease": false,
      "body": "## What's changed\\n- Faster alarms",
      "assets": [
        {"name": "apnum-android.apk", "size": 9000000, "browser_download_url": "https://github.com/Aazhs/apnum/releases/download/v0.10.0/apnum-android.apk"},
        {"name": "Apnum-mac.zip", "size": 5000000, "browser_download_url": "https://github.com/Aazhs/apnum/releases/download/v0.10.0/Apnum-mac.zip"}
      ]
    }
    """

private struct FakeFetcher: ReleaseFetching {
    var json: String = sampleJSON
    func latestReleaseJSON() async throws -> Data { Data(json.utf8) }
}

@Test func versionsCompareNumerically() {
    #expect(AppVersion("0.10.0")! > AppVersion("0.9.9")!)
    #expect(AppVersion("v1.0")! == AppVersion("1.0.0")!)
    #expect(AppVersion("1.2.3")! < AppVersion("1.2.4")!)
    #expect(AppVersion("1.0.0-beta")! == AppVersion("1.0.0")!)
    #expect(AppVersion("dev") == nil)
    #expect(AppVersion("1..2") == nil)
}

@Test func parsesGitHubRelease() throws {
    let r = try Release.parse(Data(sampleJSON.utf8))
    #expect(r.tag == "v0.10.0")
    #expect(r.version == AppVersion("0.10.0"))
    #expect(r.notes.contains("Faster alarms"))
    #expect(r.pageURL?.absoluteString == "https://github.com/Aazhs/apnum/releases/tag/v0.10.0")
    #expect(r.assets.count == 2)
    #expect(r.macAsset?.url.lastPathComponent == "Apnum-mac.zip")
    #expect(throws: UpdateError.badResponse) { try Release.parse(Data("{}".utf8)) }
}

@Test func releaseWithoutMacAssetHasNone() throws {
    let r = try Release.parse(Data(#"{"tag_name":"v1.0.0","assets":[]}"#.utf8))
    #expect(r.macAsset == nil)
}

@Test func checkerReportsAvailableAndUpToDate() async throws {
    let newer = try await UpdateChecker(fetcher: FakeFetcher(), currentVersionText: "0.9.9").check()
    #expect(newer.status.available)
    #expect(newer.status.latest == "0.10.0")
    let same = try await UpdateChecker(fetcher: FakeFetcher(), currentVersionText: "0.10.0").check()
    #expect(!same.status.available)
}

@Test func developmentBuildIsTreatedAsZero() async throws {
    for text in [nil, "dev", ""] as [String?] {
        let c = UpdateChecker(fetcher: FakeFetcher(), currentVersionText: text)
        let r = try await c.check()
        #expect(r.status.developmentBuild)
        #expect(r.status.current == "development build")
        #expect(r.status.available)
    }
}

// MARK: Install decisions

private struct FakeInspector: BundleInspecting {
    var id: String? = "dev.apnum.mac"
    var ver: String? = "0.10.0"
    var adHoc = false
    var signatureError: UpdateError?
    func identifier(at url: URL) -> String? { id }
    func version(at url: URL) -> String? { ver }
    func runningAppIsAdHoc() -> Bool { adHoc }
    func checkSignature(at url: URL, againstRunningApp: Bool) throws {
        if let signatureError { throw signatureError }
    }
}

private let expected = AppVersion("0.10.0")!
private let anyURL = URL(fileURLWithPath: "/tmp/x.app")

@Test func verifierAcceptsGoodBundle() throws {
    try UpdateVerifier(inspector: FakeInspector()).verify(candidate: anyURL, expectedVersion: expected, allowAdHoc: false)
}

@Test func verifierRejectsWrongIdentifier() {
    #expect(throws: UpdateError.wrongIdentifier("com.evil.app")) {
        try UpdateVerifier(inspector: FakeInspector(id: "com.evil.app")).verify(candidate: anyURL, expectedVersion: expected, allowAdHoc: false)
    }
}

@Test func verifierRejectsWrongVersion() {
    #expect(throws: UpdateError.wrongVersion(expected: "0.10.0", found: "0.9.0")) {
        try UpdateVerifier(inspector: FakeInspector(ver: "0.9.0")).verify(candidate: anyURL, expectedVersion: expected, allowAdHoc: false)
    }
}

@Test func verifierRejectsFailedSignature() {
    let bad = UpdateError.signatureInvalid("does not satisfy requirement")
    #expect(throws: bad) {
        try UpdateVerifier(inspector: FakeInspector(signatureError: bad)).verify(candidate: anyURL, expectedVersion: expected, allowAdHoc: false)
    }
}

@Test func adHocRunningAppIsRefusedUnlessConfirmed() throws {
    let v = UpdateVerifier(inspector: FakeInspector(adHoc: true))
    #expect(throws: UpdateError.adHocRunningApp) { try v.verify(candidate: anyURL, expectedVersion: expected, allowAdHoc: false) }
    try v.verify(candidate: anyURL, expectedVersion: expected, allowAdHoc: true)
}

@Test func replacerSwapsAndRestoresOnFailure() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("apnum-replace-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let running = root.appendingPathComponent("Apnum.app")
    let new = root.appendingPathComponent("New.app")
    try fm.createDirectory(at: running, withIntermediateDirectories: true)
    try fm.createDirectory(at: new, withIntermediateDirectories: true)
    try "old".write(to: running.appendingPathComponent("v"), atomically: true, encoding: .utf8)
    try "new".write(to: new.appendingPathComponent("v"), atomically: true, encoding: .utf8)

    // A missing replacement must leave the old bundle in place.
    #expect(throws: UpdateError.self) {
        try BundleReplacer.replace(running: running, with: root.appendingPathComponent("Missing.app"), backupDirectory: root)
    }
    #expect(try String(contentsOf: running.appendingPathComponent("v"), encoding: .utf8) == "old")

    try BundleReplacer.replace(running: running, with: new, backupDirectory: root)
    #expect(try String(contentsOf: running.appendingPathComponent("v"), encoding: .utf8) == "new")
    #expect(!fm.fileExists(atPath: root.appendingPathComponent("previous.app").path))
}

@Test func updaterRefusesNonBundle() {
    let u = Updater(runningBundle: URL(fileURLWithPath: "/tmp/.build/debug/Apnum"))
    #expect(throws: UpdateError.notAnAppBundle) { try u.checkInstallable() }
}
