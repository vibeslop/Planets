import Foundation
import Testing
@testable import Planets
@testable import PlanetsCore

@MainActor
@Suite struct ConfigStoreTests {
    let directory: URL
    var url: URL { directory.appendingPathComponent("planets.toml") }
    /// Latin-1 "é": not UTF-8.
    let notUTF8 = Data("[tiling]\ngaps = 4 # caf".utf8) + Data([0xE9, 0x0A])

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("planets-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @Test func aMissingFileIsCreatedWithTheDefaults() throws {
        let store = ConfigStore(url: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == Config.defaultFileContents)
        #expect(store.error == nil)
    }

    @Test func aFileThatIsntUTF8IsAnErrorNotTheDefaults() throws {
        try notUTF8.write(to: url)
        let store = ConfigStore(url: url)
        #expect(store.error == "planets.toml isn't UTF-8 text")
    }

    @Test func aFileThatStopsBeingUTF8KeepsTheLastGoodSettings() throws {
        try Data("[tiling]\ngaps = 4\n".utf8).write(to: url)
        let store = ConfigStore(url: url)
        #expect(store.config.layout.innerGap == 4)
        try notUTF8.write(to: url)
        store.load()
        #expect(store.error != nil)
        #expect(store.config.layout.innerGap == 4)
        // Fixed, it loads again.
        try Data("[tiling]\ngaps = 6\n".utf8).write(to: url)
        store.load()
        #expect(store.error == nil)
        #expect(store.config.layout.innerGap == 6)
    }

    /// A setting saved from the menu mustn't write the defaults over a file it couldn't read.
    @Test func aSettingLeavesAnUnreadableFileAlone() throws {
        try notUTF8.write(to: url)
        let store = ConfigStore(url: url)
        store.set(.bool(false), table: "appearance", key: "focus_glow")
        #expect(try Data(contentsOf: url) == notUTF8)
    }
}

@Suite struct SingleInstanceTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("planets-lock-\(UUID().uuidString)")

    /// flock locks belong to an open file, so a second open in this process stands in for
    /// a second Planets.
    private func holdLock() -> Int32 {
        let fd = open(directory.appendingPathComponent("planets.lock").path, O_RDWR | O_CREAT, 0o600)
        return flock(fd, LOCK_EX | LOCK_NB) == 0 ? fd : -1
    }

    @Test func theFirstCopyTakesTheLockAndKeepsIt() throws {
        #expect(Lifecycle.claimSingleInstance(in: directory))
        #expect(holdLock() == -1)
    }

    @Test func aSecondCopyIsTurnedAway() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let held = holdLock()
        #expect(held >= 0)
        #expect(!Lifecycle.claimSingleInstance(in: directory))
        close(held)
    }
}
