import Foundation
import Security

/// Everything the updater needs to know about a bundle on disk. The live version uses the Security framework.
public protocol BundleInspecting: Sendable {
    func identifier(at url: URL) -> String?
    func version(at url: URL) -> String?
    /// True when the running app is signed ad hoc (no stable identity to compare against).
    func runningAppIsAdHoc() -> Bool
    /// Throws unless the bundle's signature is valid. With `againstRunningApp`, it must also satisfy the running app's designated requirement.
    func checkSignature(at url: URL, againstRunningApp: Bool) throws
}

/// Decides whether a downloaded bundle may replace the running one.
public struct UpdateVerifier: Sendable {
    public static let bundleIdentifier = "dev.apnum.mac"
    public let inspector: any BundleInspecting
    public init(inspector: any BundleInspecting = LiveBundleInspector()) { self.inspector = inspector }

    public func verify(candidate: URL, expectedVersion: AppVersion, allowAdHoc: Bool) throws {
        guard inspector.identifier(at: candidate) == Self.bundleIdentifier else {
            throw UpdateError.wrongIdentifier(inspector.identifier(at: candidate))
        }
        let found = inspector.version(at: candidate)
        guard let found, AppVersion(found) == expectedVersion else {
            throw UpdateError.wrongVersion(expected: expectedVersion.description, found: found)
        }
        let adHoc = inspector.runningAppIsAdHoc()
        if adHoc && !allowAdHoc { throw UpdateError.adHocRunningApp }
        try inspector.checkSignature(at: candidate, againstRunningApp: !adHoc)
    }
}

public struct LiveBundleInspector: BundleInspecting {
    public init() {}

    public func identifier(at url: URL) -> String? { Bundle(url: url)?.bundleIdentifier }
    public func version(at url: URL) -> String? {
        Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    private func runningStaticCode() -> SecStaticCode? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var code: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &code) == errSecSuccess else { return nil }
        return code
    }

    public func runningAppIsAdHoc() -> Bool {
        guard let code = runningStaticCode() else { return true }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
            let dict = info as? [String: Any]
        else { return true }
        let flags = (dict[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        let hasCertificates = dict[kSecCodeInfoCertificates as String] != nil
        return flags & SecCodeSignatureFlags.adhoc.rawValue != 0 || !hasCertificates
    }

    public func checkSignature(at url: URL, againstRunningApp: Bool) throws {
        var candidate: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &candidate) == errSecSuccess, let candidate else {
            throw UpdateError.signatureInvalid("cannot read the code signature")
        }
        var requirement: SecRequirement?
        if againstRunningApp {
            guard let me = runningStaticCode(),
                SecCodeCopyDesignatedRequirement(me, [], &requirement) == errSecSuccess
            else { throw UpdateError.signatureInvalid("the running app has no designated requirement") }
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(candidate, flags, requirement)
        guard status == errSecSuccess else {
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            throw UpdateError.signatureInvalid(text)
        }
    }
}

/// Streams a file to disk, reporting 0...1.
public protocol Downloading: Sendable {
    func download(_ url: URL, to file: URL, progress: @escaping @Sendable (Double) -> Void) async throws
}

public struct URLSessionDownloader: Downloading {
    public init() {}
    public func download(_ url: URL, to file: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard url.scheme == "https" else { throw UpdateError.download("the link is not https") }
        var request = URLRequest(url: url)
        request.setValue("apnum", forHTTPHeaderField: "User-Agent")
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw UpdateError.download("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            let total = response.expectedContentLength
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            var buffer = Data()
            var received: Int64 = 0
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 256 * 1024 {
                    try handle.write(contentsOf: buffer)
                    received += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    if total > 0 { progress(min(1, Double(received) / Double(total))) }
                }
            }
            try handle.write(contentsOf: buffer)
            progress(1)
        } catch let e as UpdateError {
            throw e
        } catch {
            throw UpdateError.download(error.localizedDescription)
        }
    }
}

/// Moves a new bundle over the old one, putting the old one back on any failure.
public enum BundleReplacer {
    public static func replace(running: URL, with new: URL, backupDirectory: URL, fileManager fm: FileManager = .default) throws {
        let backup = backupDirectory.appendingPathComponent("previous.app")
        try? fm.removeItem(at: backup)
        do { try fm.moveItem(at: running, to: backup) } catch { throw UpdateError.replace(error.localizedDescription) }
        do {
            try fm.moveItem(at: new, to: running)
        } catch {
            try? fm.removeItem(at: running)
            try? fm.moveItem(at: backup, to: running)
            throw UpdateError.replace(error.localizedDescription)
        }
        try? fm.removeItem(at: backup)
    }
}

public struct Updater: Sendable {
    public let verifier: UpdateVerifier
    public let downloader: any Downloading
    public let runningBundle: URL
    /// Unpacks a zip into a folder. Defaults to `/usr/bin/ditto -x -k`.
    public let unzip: @Sendable (_ zip: URL, _ into: URL) throws -> Void

    public init(
        verifier: UpdateVerifier = UpdateVerifier(), downloader: any Downloading = URLSessionDownloader(),
        runningBundle: URL = Bundle.main.bundleURL,
        unzip: @escaping @Sendable (URL, URL) throws -> Void = Updater.dittoUnzip
    ) {
        self.verifier = verifier
        self.downloader = downloader
        self.runningBundle = runningBundle
        self.unzip = unzip
    }

    /// Fails early, before any download, when the running app cannot be replaced.
    public func checkInstallable() throws {
        guard runningBundle.pathExtension == "app" else { throw UpdateError.notAnAppBundle }
        let parent = runningBundle.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else { throw UpdateError.notWritable(parent.path) }
    }

    /// Downloads, verifies and swaps in the release. Returns the bundle to relaunch. Does not relaunch.
    public func install(_ release: Release, allowAdHoc: Bool, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try checkInstallable()
        guard let asset = release.macAsset else { throw UpdateError.noMacAsset }
        let fm = FileManager.default
        // Same volume as the app, so the swap is a rename.
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: runningBundle, create: true)
        defer { try? fm.removeItem(at: work) }
        let zip = work.appendingPathComponent("Apnum-mac.zip")
        let extracted = work.appendingPathComponent("extracted", isDirectory: true)
        try fm.createDirectory(at: extracted, withIntermediateDirectories: true)

        try await downloader.download(asset.url, to: zip, progress: progress)
        do {
            try unzip(zip, extracted)
        } catch let e as UpdateError {
            throw e
        } catch {
            throw UpdateError.unzip(error.localizedDescription)
        }
        let apps = ((try? fm.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "app" }
        guard apps.count == 1, let candidate = apps.first else { throw UpdateError.unzip("expected exactly one app in the archive") }

        try verifier.verify(candidate: candidate, expectedVersion: release.version, allowAdHoc: allowAdHoc)
        try BundleReplacer.replace(running: runningBundle, with: candidate, backupDirectory: work, fileManager: fm)
        return runningBundle
    }

    /// Starts a detached shell that reopens the app a moment after this process exits.
    public static func relaunch(_ bundle: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; exec /usr/bin/open -n \"$1\"", "sh", bundle.path]
        try? p.run()
    }

    public static let dittoUnzip: @Sendable (URL, URL) throws -> Void = { zip, folder in
        let p = Process()
        let err = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, folder.path]
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw UpdateError.unzip(text.isEmpty ? "ditto exited with \(p.terminationStatus)" : text)
        }
    }
}
