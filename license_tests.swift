// SPDX-License-Identifier: AGPL-3.0-only
// Compile: swiftc Inventory.swift LicenseState.swift license_tests.swift -o /tmp/auth-license-tests
import Foundation
import Darwin

@main
struct LicenseStateTests {
    static func main() throws {
        if CommandLine.arguments.count == 3 {
            do {
                let store = try LicenseStore(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
                if CommandLine.arguments[1] == "--lock-probe" {
                    try store.upsert(LicenseRecord(entryID: "fixture", metadataStamp: "fixture-stamp", classID: "class",
                        productName: "Fixture", status: .activated, source: .user))
                }
                exit(1)
            } catch { exit(0) }
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("auth-license-tests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            count += 1
            guard condition else { fatalError("FAIL: " + message) }
        }
        func expectError(_ message: String, _ operation: () throws -> Void) {
            count += 1
            do { try operation(); fatalError("FAIL: expected error: " + message) }
            catch { /* Expected: callers must explicitly handle failed persistence. */ }
        }
        func entry(_ format: String = "VST3", _ stamp: String = "stamp-1") -> Entry {
            let path = root.appendingPathComponent("Product." + format).path
            return Entry(id: path, name: "Product", vendor: "Acme", format: format, path: path,
                identifier: path, version: "1", architectures: ["arm64"], metadataStamp: stamp)
        }
        let vst = entry()
        let au = entry("AU")
        func record(_ entry: Entry = vst, classID: String = "class-one", name: String = "Product One",
                    status: LicenseStatus = .needsActivation, source: LicenseSource = .detected,
                    time: Double = 100) -> LicenseRecord {
            LicenseRecord(entryID: entry.id, metadataStamp: entry.metadataStamp, classID: classID,
                productName: name, status: status, source: source, evidenceRule: source == .detected ? "test-explicit-activation-text" : nil,
                checkedAt: Date(timeIntervalSince1970: time))
        }
        let store = try LicenseStore(directory: root.appendingPathComponent("Ledger"))
        check(store.records.isEmpty && store.state(for: vst, classID: "class-one") == nil, "missing ledger starts unknown")
        check(!fm.fileExists(atPath: store.fileURL.path), "read-only initialization does not create an empty ledger")

        let first = record()
        check(try store.upsert(first), "explicit detection can be stored")
        check(store.state(for: vst, classID: "class-one") == first, "stored detection is matched exactly")
        let firstBytes = try Data(contentsOf: store.fileURL)
        check(try !store.upsert(first), "duplicate detection does not create another record")
        check(try Data(contentsOf: store.fileURL) == firstBytes, "duplicate detection does not rewrite the ledger")
        check(store.records.count == 1, "one record per entry and class")

        let manual = record(status: .activated, source: .user, time: 101.125)
        check(try store.upsert(manual), "manual activation confirmation is stored")
        check(store.state(for: vst, classID: "class-one")?.source == .user, "manual source is explicit")
        check(try !store.upsert(first), "stale observation cannot undo later manual confirmation")
        check(try !store.upsert(record(time: 101.125)), "detector cannot win an equal-time tie with a user")
        let reopened = try LicenseStore(directory: root.appendingPathComponent("Ledger"))
        check(reopened.state(for: vst, classID: "class-one") == manual, "fractional observation timestamp survives encoding")
        check(try store.upsert(record(time: 102)), "a newly observed failure on a later launch can replace a manual result")
        check(try store.upsert(record(status: .notRequired, source: .user, time: 103)), "manual no-license-needed status is stored")

        check(try store.upsert(record(classID: "class-two", name: "Product Two")), "a second bundled class gets its own record")
        check(store.state(for: vst, classID: "class-one")?.status == .notRequired, "second class never changes the first class")
        check(store.state(for: vst, classID: "class-two")?.status == .needsActivation, "second class status is separate")
        check(try store.upsert(record(au)), "AU can be recorded separately")
        check(store.state(for: au, classID: "class-one")?.status == .needsActivation, "AU state does not inherit VST3 confirmation")
        check(try store.upsert(record(classID: "", name: "Module-level observation", status: .activated, source: .user)),
              "an explicit empty class ID is supported")
        check(store.state(for: vst, classID: "class-two")?.status == .needsActivation,
              "empty class ID is not a wildcard")
        check(store.state(for: vst, classID: "other-class") == nil, "unseen classes remain unknown")

        let newerVersion = entry("VST3", "stamp-2")
        check(store.state(for: newerVersion, classID: "class-one") == nil, "changed binary stamp invalidates saved state")
        check(store.matchingRecords(entries: [newerVersion, au]).count == 1, "stale version records are excluded from queues")
        check(store.matchingRecords(entries: []).isEmpty, "uninstalled entries are excluded")
        check(store.matchingRecords(entries: [vst, vst, au]).count == 4, "duplicate current entries do not crash or duplicate records")
        check(store.state(for: entry("VST3", ""), classID: "class-one") == nil, "missing stamp cannot validate a record")
        expectError("missing metadata stamp") { _ = try store.upsert(record(entry("VST3", ""))) }
        check(try store.upsert(record(newerVersion, status: .activated, source: .user, time: 104)), "a new version can be explicitly confirmed")
        check(store.state(for: vst, classID: "class-one") == nil, "new version confirmation does not validate older binaries")

        let beforeForget = store.records.count
        check(try store.forget(entryID: vst.id, classID: "class-two"), "forget removes exactly the requested class")
        check(store.records.count == beforeForget - 1 && store.state(for: au, classID: "class-one") != nil,
              "forget preserves the other format")
        check(try !store.forget(entryID: vst.id, classID: "missing"), "forget of unknown record is a no-op")

        // Another process / store instance must not lose changes through a stale
        // read-modify-write. It can explicitly reload, then retry.
        expectError("stale store refuses to overwrite newer disk contents") { _ = try reopened.upsert(record(classID: "new-class", time: 200)) }
        try reopened.reload()
        check(try reopened.upsert(record(classID: "new-class", time: 200)), "explicit reload allows a safe retry")

        let corruptBytes = Data("{not valid json".utf8)
        try corruptBytes.write(to: reopened.fileURL, options: .atomic)
        let memoryBeforeCorruption = reopened.records
        expectError("corrupt file is rejected on initialization") { _ = try LicenseStore(directory: root.appendingPathComponent("Ledger")) }
        expectError("corrupt file cannot be overwritten by a running store") { _ = try reopened.upsert(record(classID: "post-corruption", time: 300)) }
        expectError("reload reports corruption") { try reopened.reload() }
        check(reopened.records == memoryBeforeCorruption, "failed reload preserves the last known in-memory records")
        check(try Data(contentsOf: reopened.fileURL) == corruptBytes, "corrupt bytes remain untouched for recovery")

        let unknownVersion = root.appendingPathComponent("UnknownVersion")
        try fm.createDirectory(at: unknownVersion, withIntermediateDirectories: true)
        try Data("{\"version\":2,\"records\":[]}".utf8).write(to: unknownVersion.appendingPathComponent("license-state.json"))
        expectError("newer schema is not silently reset") { _ = try LicenseStore(directory: unknownVersion) }

        let duplicateDirectory = root.appendingPathComponent("Duplicates")
        try fm.createDirectory(at: duplicateDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        let encodedRecord = try JSONSerialization.jsonObject(with: encoder.encode(first))
        let duplicates = try JSONSerialization.data(withJSONObject: ["version": 1, "records": [encodedRecord, encodedRecord]])
        try duplicates.write(to: duplicateDirectory.appendingPathComponent("license-state.json"))
        expectError("duplicate keys in external data are corruption") { _ = try LicenseStore(directory: duplicateDirectory) }

        check(LicenseRecord.identifier(entryID: "a:b", classID: "c") != LicenseRecord.identifier(entryID: "a", classID: "b:c"),
              "stable record IDs cannot collide through delimiter-containing paths")
        check(LicenseStatus.activated.title == "認証済み" && LicenseSource.user.title == "手動", "status labels are available to UI")

        let tieStore = try LicenseStore(directory: root.appendingPathComponent("Tie"))
        check(try tieStore.upsert(record(time: 500)), "tie fixture stores a detector result")
        check(try tieStore.upsert(record(status: .activated, source: .user, time: 500)), "user wins an exact timestamp tie")
        check(tieStore.state(for: vst, classID: "class-one")?.source == .user, "tie winner remains explicitly manual")

        let lockedDirectory = root.appendingPathComponent("Locked")
        try fm.createDirectory(at: lockedDirectory, withIntermediateDirectories: true)
        let lockedStore = try LicenseStore(directory: lockedDirectory)
        let fd = Darwin.open(lockedDirectory.appendingPathComponent(".license-state.lock").path, O_CREAT | O_WRONLY, mode_t(0o600))
        check(fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0, "test acquires the cooperating process lock")
        expectError("a busy ledger never blocks the UI indefinitely") { _ = try lockedStore.upsert(first) }
        check(lockedStore.records.isEmpty, "lock failure leaves memory unchanged")
        _ = flock(fd, LOCK_UN); Darwin.close(fd)
        check(try lockedStore.upsert(first), "saving works after releasing the lock")

        let failingDirectory = root.appendingPathComponent("WriteFailure")
        let failingStore = try LicenseStore(directory: failingDirectory)
        _ = try failingStore.upsert(first)
        let savedBytes = try Data(contentsOf: failingStore.fileURL)
        let recoveredDirectory = root.appendingPathComponent("WriteFailureOriginal")
        try fm.moveItem(at: failingDirectory, to: recoveredDirectory)
        try Data("a file is deliberately blocking this test directory".utf8).write(to: failingDirectory)
        expectError("failed disk save is reported") { _ = try failingStore.upsert(record(status: .activated, source: .user, time: 600)) }
        check(failingStore.records == [first], "failed disk save does not publish a false confirmation in memory")
        check(try Data(contentsOf: recoveredDirectory.appendingPathComponent("license-state.json")) == savedBytes,
              "failed disk save leaves the previously committed bytes intact")
        let fifoDirectory = root.appendingPathComponent("FIFO")
        try fm.createDirectory(at: fifoDirectory, withIntermediateDirectories: true)
        check(mkfifo(fifoDirectory.appendingPathComponent("license-state.json").path, mode_t(0o600)) == 0,
              "create writerless ledger FIFO")
        let fifoLockDirectory = root.appendingPathComponent("FIFOLock")
        try fm.createDirectory(at: fifoLockDirectory, withIntermediateDirectories: true)
        check(mkfifo(fifoLockDirectory.appendingPathComponent(".license-state.lock").path, mode_t(0o600)) == 0,
              "create ledger lock FIFO")
        for (mode, directory) in [("--read-probe", fifoDirectory), ("--lock-probe", fifoLockDirectory)] {
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            probe.arguments = [mode, directory.path]
            try probe.run()
            let deadline = Date().addingTimeInterval(2)
            while probe.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            let blocked = probe.isRunning
            if blocked { kill(probe.processIdentifier, SIGKILL) }
            probe.waitUntilExit()
            check(!blocked && probe.terminationStatus == 0, "non-regular ledger or lock is reported without blocking: " + mode)
        }
        check(!fm.fileExists(atPath: fifoLockDirectory.appendingPathComponent("license-state.json").path),
              "rejected FIFO lock never creates a ledger")
        print("PASS: \(count) license state fixtures")
    }
}
