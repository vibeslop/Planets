import Foundation
import PlanetsCore

@MainActor
final class ConfigStore {
    let url: URL
    private(set) var config: Config
    private(set) var warnings: [String] = []
    private(set) var error: String?
    var onChange: ((Config) -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var watchedInode: ino_t = 0
    private var lastContents: String?
    private var reloadScheduled = false

    init(url: URL = IPC.configURL) {
        self.url = url
        config = Config()
        load()
        watch()
        watchFile()
    }

    private func read() -> Result<String, ConfigError> {
        do {
            guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else {
                return .failure(ConfigError("\(url.lastPathComponent) isn't UTF-8 text"))
            }
            return .success(text)
        } catch {
            return .failure(ConfigError("Couldn't read \(url.path): \(error.localizedDescription)"))
        }
    }

    func load() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Config.defaultFileContents.write(to: url, atomically: true, encoding: .utf8)
        }
        let text: String
        switch read() {
        case .success(let read): text = read
        case .failure(let failure):
            error = failure.message
            lastContents = nil
            onChange?(config)
            return
        }
        guard text != lastContents else { return }
        lastContents = text
        do {
            let (parsed, warnings) = try Config.parse(text)
            self.warnings = warnings
            error = nil
            let changed = parsed != config
            config = parsed
            if changed { onChange?(parsed) }
        } catch {
            self.error = "\(error)"
            onChange?(config)
        }
    }

    func set(_ value: TOMLValue, table: String, key: String) {
        guard case .success(let contents) = read() else { return load() }
        let edited = TOMLEditor.setting(value, table: table, key: key, in: contents)
        do {
            try edited.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            self.error = "Couldn't save \(url.path): \(error.localizedDescription)"
        }
        load()
    }

    private func watch() {
        let directory = url.deletingLastPathComponent().path
        let fd = open(directory, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    private func watchFile() {
        var info = stat()
        guard stat(url.path, &info) == 0, fileSource == nil || info.st_ino != watchedInode else { return }
        fileSource?.cancel()
        fileSource = nil
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedInode = info.st_ino
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileSource = source
    }

    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            MainActor.assumeIsolated {
                self?.reloadScheduled = false
                self?.load()
                self?.watchFile()
            }
        }
    }
}
