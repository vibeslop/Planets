import AppKit
import PlanetsCore
import Security

@MainActor
final class Updater {
    private(set) var ready: Version?
    var onReady: (() -> Void)?
    var canRestart: () -> Bool = { true }
    var restart: () -> Void = {}

    private var checkTimer: Timer?
    private var restTimer: Timer?
    private var checking = false
    private var enabled = false

    nonisolated private static let latestURL = URL(string: ProcessInfo.processInfo.environment["PLANETS_RELEASES_URL"]
        ?? "https://api.github.com/repos/vibeslop/Planets/releases/latest")!

    private static let obstacle: String? = {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app", Lifecycle.canRelaunch else { return "it doesn't run from its bundle with its watcher" }
        guard signer(of: bundle) == "Planets Release" else { return "it isn't signed with the release certificate" }
        guard access(bundle.deletingLastPathComponent().path, W_OK) == 0 else { return "this account can't change \(bundle.deletingLastPathComponent().path)" }
        return nil
    }()

    func setEnabled(_ enabled: Bool) {
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        checkTimer?.invalidate()
        checkTimer = nil
        guard enabled else { return }
        if let obstacle = Self.obstacle {
            log.info("updates are off: \(obstacle, privacy: .public)")
            return
        }
        if ready == nil { scheduleCheck(after: 60) }
    }

    private func scheduleCheck(after seconds: TimeInterval) {
        checkTimer?.invalidate()
        checkTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        checkTimer?.tolerance = seconds / 10
    }

    private func check() {
        guard enabled, !checking, ready == nil, let current = Version(Bundle.main.shortVersion) else { return }
        checking = true
        let bundle = Bundle.main.bundleURL
        Task.detached(priority: .utility) {
            let result: Result<Version?, Error>
            do { result = .success(try await Self.install(after: current, replacing: bundle)) } catch { result = .failure(error) }
            await self.checked(result)
        }
    }

    private func checked(_ result: Result<Version?, Error>) {
        checking = false
        switch result {
        case .success(nil):
            scheduleCheck(after: 24 * 60 * 60)
        case .success(let version?):
            log.info("Planets \(version.description, privacy: .public) is in place; restarting once you're away")
            ready = version
            onReady?()
            restTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.restartIfAway() }
            }
        case .failure(let error):
            log.error("update failed: \(error.localizedDescription, privacy: .public)")
            scheduleCheck(after: 60 * 60)
        }
    }

    private func restartIfAway() {
        let anyInput = CGEventType(rawValue: ~0)!
        let rested = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        guard rested >= 60, canRestart() else { return }
        restart()
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    nonisolated private static func install(after current: Version, replacing bundle: URL) async throws -> Version? {
        var request = URLRequest(url: latestURL, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (json, _) = try await URLSession.shared.data(for: request)
        guard let update = try JSONDecoder().decode(Release.self, from: json).update(after: current) else { return nil }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("planets-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let (download, _) = try await URLSession.shared.download(for: URLRequest(url: update.archive, timeoutInterval: 300))
        let archive = work.appendingPathComponent("Planets.zip")
        try FileManager.default.moveItem(at: download, to: archive)
        try run("/usr/bin/ditto", "-x", "-k", archive.path, work.path)
        let app = work.appendingPathComponent("Planets.app")
        try verify(app)
        let found = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
        guard found.flatMap(Version.init) == update.version else {
            throw Failure("the download of Planets \(update.version) holds version \(found ?? "none")")
        }

        let folder = bundle.deletingLastPathComponent()
        let staged = folder.appendingPathComponent(".Planets.app.new")
        let previous = folder.appendingPathComponent(".Planets.app.old")
        try? FileManager.default.removeItem(at: staged)
        try? FileManager.default.removeItem(at: previous)
        try run("/usr/bin/ditto", app.path, staged.path)
        do {
            try FileManager.default.moveItem(at: bundle, to: previous)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        do {
            try FileManager.default.moveItem(at: staged, to: bundle)
        } catch {
            try? FileManager.default.moveItem(at: previous, to: bundle)
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        try? FileManager.default.removeItem(at: previous)
        return update.version
    }

    // SAFETY: Verifies nested code signature against the running binary's designated requirement before replacing the bundle.
    nonisolated private static func verify(_ app: URL) throws {
        var running: SecCode?
        var own: SecStaticCode?
        var requirement: SecRequirement?
        var download: SecStaticCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &own) == errSecSuccess, let own,
              SecCodeCopyDesignatedRequirement(own, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &download) == errSecSuccess, let download else {
            throw Failure("couldn't read the code signatures to compare")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(download, flags, requirement)
        guard status == errSecSuccess else {
            throw Failure("the download failed its signature check (\(SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"))")
        }
    }

    nonisolated private static func signer(of url: URL) -> String? {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        return SecCertificateCopySubjectSummary(leaf) as String?
    }

    nonisolated private static func run(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure("\(tool) ended with status \(process.terminationStatus)") }
    }
}
