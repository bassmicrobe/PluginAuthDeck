// SPDX-License-Identifier: AGPL-3.0-only
// Compile: swiftc Inventory.swift AutoScan.swift autoscan_tests.swift -o /tmp/auth-autoscan-tests
import Foundation
import Darwin

@main
struct AutoScanTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("auth-autoscan-tests-" + UUID().uuidString)
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
            catch { }
        }
        func entry(_ name: String, format: String = "VST3", stamp: String = "version-1") -> Entry {
            let path = root.appendingPathComponent(name + "." + format).path
            return Entry(id: path, name: name, vendor: "Acme", format: format, path: path,
                identifier: path, version: "1", architectures: ["arm64"], metadataStamp: stamp)
        }
        let bundle = entry("Bundle")
        let other = entry("Other")
        let initial = AutoScanTask(entry: bundle)
        let secondModule = AutoScanTask(entry: other)
        let classOne = AutoScanTask(entry: bundle, classID: "one", productName: "Product One")
        let classTwo = AutoScanTask(entry: bundle, classID: "two", productName: "Product Two")
        let changedClass = AutoScanTask(entry: entry("Bundle", stamp: "version-2"), classID: "one", productName: "Product One")
        check(classOne.id != changedClass.id, "different binary versions have distinct scan identities")
        check(classOne.id != classTwo.id, "bundled products retain separate identities")

        var run = AutoScanRun(tasks: [initial, initial, secondModule])
        check(run.status == .paused && run.pending.count == 2, "new run is paused and removes exact duplicate tasks")
        check(run.totalCount == 2 && run.completedCount == 0, "initial counts cover pending tasks only")
        check(run.beginNext() == nil, "a paused queue cannot open anything")
        run.resume()
        check(run.beginNext() == initial, "explicit resume allows the first task")
        check(run.beginNext() == nil && run.current == initial, "there is at most one in-flight task")
        let beforeInvalid = run
        expectError("a sibling from another version is rejected") {
            try run.identifyCurrent(classID: "one", productName: "Product One", siblings: [changedClass])
        }
        check(run == beforeInvalid, "failed class discovery leaves the queue unchanged")
        try run.identifyCurrent(classID: "one", productName: "Product One", siblings: [classOne, classTwo, classTwo])
        check(run.current == classOne && run.pending.map(\.id) == [secondModule.id, classTwo.id],
              "initial placeholder is replaced and unseen siblings are queued exactly once")
        check(run.totalCount == 3, "discovering sibling classes expands total count")
        let identified = run
        expectError("the requested explicit class cannot silently change") {
            try run.identifyCurrent(classID: "two", productName: "Product Two")
        }
        check(run == identified, "wrong-class rejection is transactional")
        try run.finishCurrent(outcome: .needsActivation, reason: "explicit-activation-label", checkedAt: Date(timeIntervalSince1970: 10.25))
        check(run.completedCount == 1 && run.current == nil && run.status == .running,
              "finished result is separate from pending work")
        check(run.results[0].task == classOne && run.results[0].checkedAt == Date(timeIntervalSince1970: 10.25),
              "result records exact source, class and observation time")
        expectError("a result cannot be completed twice") { try run.finishCurrent(outcome: .inconclusive, reason: "duplicate") }

        _ = run.beginNext()
        run.pause()
        check(run.status == .paused && run.current == nil && run.pending.first == secondModule,
              "pause requeues only the interrupted target at the front")
        check(run.completedCount == 1, "pause preserves completed results")
        run.resume(); _ = run.beginNext()
        try run.finishCurrent(outcome: .loadFailed, reason: "host-load-failed")
        check(run.results.last?.task.classID == "" && run.results.last?.outcome == .loadFailed,
              "failure before class discovery remains a module load result")
        check(run.beginNext() == classTwo, "resume does not repeat the completed first class")
        try run.identifyCurrent(classID: "two", productName: "Product Two", siblings: [classOne, classTwo])
        check(run.pending.isEmpty, "rediscovery never requeues completed or in-flight classes")
        try run.finishCurrent(outcome: .inconclusive, reason: "no-explicit-signal")
        check(run.status == .complete && run.completedCount == 3 && run.totalCount == 3,
              "last task completes the run")
        run.resume(); check(run.status == .complete && run.beginNext() == nil, "completed runs do not restart automatically")
        check(!AutoScanOutcome.allCases.map(\.rawValue).contains("activated"), "absence of a warning is never represented as activated")
        check(AutoScanOutcome.noActivationDetected.title == "未認証表示なし",
              "an inspected display without an activation warning is not called licensed")

        let inspection = AutoScanDiagnostics(phase: "observing", probeDiagnostic: "ocr_no_supported_status",
            staticTextNodes: 12, maskedRegions: 3, completedInspectionCount: 3, textInspectionCount: 2)
        var inspectedRun = AutoScanRun(tasks: [classOne])
        inspectedRun.resume(); _ = inspectedRun.beginNext()
        let beforeInspected = inspectedRun
        expectError("a negative display result needs actual completed inspections") {
            try inspectedRun.finishCurrent(outcome: .noActivationDetected, reason: "no_activation_display")
        }
        check(inspectedRun == beforeInspected, "rejected evidence does not consume the current task")
        for invalidInspection in [
            AutoScanDiagnostics(phase: "observing", completedInspectionCount: 1, textInspectionCount: 1),
            AutoScanDiagnostics(phase: "observing", completedInspectionCount: 2, textInspectionCount: 0),
            AutoScanDiagnostics(phase: "observing", completedInspectionCount: 2, textInspectionCount: 3),
            AutoScanDiagnostics(phase: "observing", completedInspectionCount: -1, textInspectionCount: 0),
            AutoScanDiagnostics(phase: "observing", staticTextNodes: 4097, completedInspectionCount: 2, textInspectionCount: 2),
            AutoScanDiagnostics(phase: "observing", probeDiagnostic: "raw UI text must never be persisted", completedInspectionCount: 2, textInspectionCount: 2)
        ] {
            expectError("incomplete or invalid inspection metadata cannot prove a negative display check") {
                try inspectedRun.finishCurrent(outcome: .noActivationDetected, reason: "no_activation_display",
                                               diagnostics: invalidInspection)
            }
        }
        try inspectedRun.finishCurrent(outcome: .noActivationDetected, reason: "no_activation_display",
                                       diagnostics: inspection)
        let inspectedStore = try AutoScanStore(directory: root.appendingPathComponent("Inspected"))
        try inspectedStore.save(inspectedRun)
        let inspectedReload = try AutoScanStore(directory: root.appendingPathComponent("Inspected"))
        check(inspectedReload.run?.results.first?.diagnostics == inspection
            && inspectedReload.run?.results.first?.outcome == .noActivationDetected,
            "safe inspection metadata and its limited result survive reload")

        var auOne = entry("Shared AU", format: "AU")
        auOne.id += "|aumu,one,Acme"
        var auTwo = auOne
        auTwo.id = auOne.path + "|aumu,two,Acme"
        auTwo.identifier = "AudioUnit:Synths/aumu,two,Acme"
        let auQueue = AutoScanRun(tasks: [AutoScanTask(entry: auOne), AutoScanTask(entry: auTwo)])
        check(auQueue.totalCount == 2, "AU components sharing one file are not collapsed by path")

        // If a discovery placeholder and an already-known sibling were queued,
        // resolving the placeholder to that sibling must remove the duplicate.
        var placeholder = AutoScanRun(tasks: [initial, classOne, classTwo])
        placeholder.resume(); _ = placeholder.beginNext()
        try placeholder.identifyCurrent(classID: "one", productName: "Product One", siblings: [classOne, classTwo])
        check(placeholder.totalCount == 2 && placeholder.pending == [classTwo], "class resolution absorbs an equivalent pending task")

        // A retry keeps the first attempt with the same product identity. It
        // never inflates product counts or replaces an unknown with a verdict.
        var retryRun = AutoScanRun(tasks: [initial, secondModule])
        retryRun.resume(); _ = retryRun.beginNext()
        try retryRun.identifyCurrent(classID: "one", productName: "Product One")
        let retryDiagnostics = AutoScanDiagnostics(phase: "creating_instance", probeDiagnostic: "ocr_pending")
        check(try retryRun.retryCurrent(outcome: .timedOut, reason: "creating_instance_heartbeat_stalled",
            checkedAt: Date(timeIntervalSince1970: 100), diagnostics: retryDiagnostics), "first transient failure can be queued once")
        check(retryRun.completedCount == 0 && retryRun.totalCount == 2 && retryRun.current == nil,
            "retry records an attempt without adding a completed product")
        check(retryRun.beginNext() == secondModule, "ordinary work runs before the retry pass")
        let unchangedUnknown = retryRun
        check(try !retryRun.retryCurrent(outcome: .inconclusive, reason: "no_supported_explicit_license_status"),
            "unknown does not loop automatically")
        check(retryRun == unchangedUnknown, "declined retry leaves the current task intact")
        try retryRun.finishCurrent(outcome: .inconclusive, reason: "no_supported_explicit_license_status")
        let retryTask = retryRun.beginNext()!
        check(retryTask.id == classOne.id && retryTask.isRetry && retryTask.launchBudgetSeconds == 60,
            "retry retains exact identity and has the longer bounded launch budget")
        try retryRun.identifyCurrent(classID: "one", productName: "Product One")
        check(retryRun.current?.previousAttempts == retryTask.previousAttempts,
            "class rediscovery preserves the initial diagnostic attempt")
        retryRun.pause()
        let retryStore = try AutoScanStore(directory: root.appendingPathComponent("Retry"))
        try retryStore.save(retryRun)
        var retryReload = try AutoScanStore(directory: root.appendingPathComponent("Retry")).run!
        check(retryReload.status == .paused && retryReload.pending.first?.previousAttempts?.count == 1,
            "paused/reloaded retries retain their history without starting a host")
        check(retryReload.pending.first?.previousAttempts?.first?.diagnostics == retryDiagnostics,
              "first-attempt diagnostics survive retry queue persistence")
        retryReload.resume(); _ = retryReload.beginNext()
        check(try !retryReload.retryCurrent(outcome: .loadFailed, reason: "instance_creation_failed"),
            "second failure cannot schedule an unbounded third attempt")
        try retryReload.finishCurrent(outcome: .loadFailed, reason: "instance_creation_failed")
        check(retryReload.totalCount == 2 && retryReload.completedCount == 2
            && retryReload.results.last?.task.previousAttempts?.first?.outcome == .timedOut,
            "final outcome and first failure are preserved with one product count")
        var recheckUnknown = AutoScanRun(tasks: [secondModule])
        recheckUnknown.resume()
        check(recheckUnknown.beginNext() == secondModule, "a new scan can explicitly recheck a previously unknown product")
        let legacyEncoder = JSONEncoder()
        let legacyTaskBytes = try legacyEncoder.encode(initial)
        let legacyTask = try JSONDecoder().decode(AutoScanTask.self, from: legacyTaskBytes)
        check(legacyTask.previousAttempts == nil && !legacyTask.isRetry && legacyTask.launchBudgetSeconds == 25,
            "older task JSON without attempt metadata retains the ordinary budget")
        let legacyResultBytes = try legacyEncoder.encode(run.results[0])
        let legacyResultJSON = try JSONSerialization.jsonObject(with: legacyResultBytes) as! [String: Any]
        check(legacyResultJSON["diagnostics"] == nil, "legacy records omit optional inspection metadata")
        let legacyResult = try JSONDecoder().decode(AutoScanResult.self, from: legacyResultBytes)
        check(legacyResult.diagnostics == nil && legacyResult.outcome == .needsActivation,
              "old results lacking diagnostics decode without inventing inspection evidence")
        let legacyAttempt = try JSONDecoder().decode(AutoScanAttempt.self,
            from: Data("{\"outcome\":\"timedOut\",\"reason\":\"loading_heartbeat_stalled\",\"checkedAt\":100}".utf8))
        check(legacyAttempt.diagnostics == nil, "old retry metadata without diagnostics remains readable")
        let repeatedAttempt = AutoScanAttempt(outcome: .timedOut, reason: "loading_heartbeat_stalled", checkedAt: Date())
        let invalidRetry = AutoScanRun(tasks: [AutoScanTask(entry: bundle, previousAttempts: [repeatedAttempt, repeatedAttempt])])
        expectError("checkpoints reject an unbounded retry history") { try retryStore.save(invalidRetry) }

        let store = try AutoScanStore(directory: root.appendingPathComponent("Store"))
        check(store.run == nil && !fm.fileExists(atPath: store.fileURL.path), "no checkpoint means no implicit run")
        try store.save(run)
        let completedReload = try AutoScanStore(directory: root.appendingPathComponent("Store"))
        check(completedReload.run?.status == .complete && completedReload.run?.results == run.results,
              "a completed checkpoint remains complete after reload")

        var interrupted = AutoScanRun(tasks: [initial, secondModule])
        interrupted.resume(); _ = interrupted.beginNext()
        try interrupted.identifyCurrent(classID: "one", productName: "Product One", siblings: [classTwo])
        try interrupted.finishCurrent(outcome: .needsActivation, reason: "explicit-activation-label")
        _ = interrupted.beginNext()
        try store.save(interrupted)
        let originalBytes = try Data(contentsOf: store.fileURL)
        let restored = try AutoScanStore(directory: root.appendingPathComponent("Store"))
        var recovered = restored.run!
        check(recovered.status == .paused && recovered.current == nil, "interrupted run is recovered paused")
        check(recovered.pending.map(\.id) == [secondModule.id, classTwo.id], "only the unfinished target is returned to the front")
        check(recovered.results == interrupted.results, "recovery preserves completed classes and outcomes")
        check(try Data(contentsOf: restored.fileURL) == originalBytes, "recovery itself performs no disk mutation")
        check(recovered.beginNext() == nil, "recovery never resumes a process by itself")
        try restored.save(recovered)
        check(restored.run == recovered, "recovered checkpoint saves against original disk snapshot successfully")
        recovered.resume(); check(recovered.beginNext() == secondModule, "explicit resume picks the interrupted target")
        try recovered.finishCurrent(outcome: .timedOut, reason: "host-timeout")
        _ = recovered.beginNext()
        try recovered.finishCurrent(outcome: .changed, reason: "binary-stamp-changed")
        try restored.save(recovered)
        check(restored.run?.status == .complete, "timeout and changed source both allow the durable queue to finish")

        expectError("another writer cannot overwrite a newer checkpoint") { try store.save(run) }
        try store.reload()
        check(store.run?.results == recovered.results, "explicit reload adopts a valid newer checkpoint")

        let beforeCorruption = restored.run
        let bad = Data("{bad checkpoint".utf8)
        try bad.write(to: restored.fileURL, options: .atomic)
        expectError("corrupt checkpoint is not reset on load") { _ = try AutoScanStore(directory: root.appendingPathComponent("Store")) }
        expectError("running store refuses to overwrite corruption") { try restored.save(run) }
        expectError("reload reports corruption") { try restored.reload() }
        let bytesAfterFailedSave = try Data(contentsOf: restored.fileURL)
        check(restored.run == beforeCorruption && bytesAfterFailedSave == bad,
              "failed save and reload preserve memory and original corrupted bytes")

        // Invalid state documents are rejected even when their JSON is valid.
        let invalidDirectory = root.appendingPathComponent("Invalid")
        try fm.createDirectory(at: invalidDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        var invalidRun = try JSONSerialization.jsonObject(with: encoder.encode(run)) as! [String: Any]
        invalidRun["pending"] = [try JSONSerialization.jsonObject(with: encoder.encode(initial))]
        let invalid = try JSONSerialization.data(withJSONObject: ["version": 1, "run": invalidRun])
        try invalid.write(to: invalidDirectory.appendingPathComponent("autoscan-state.json"))
        expectError("complete run with pending tasks is invalid") { _ = try AutoScanStore(directory: invalidDirectory) }
        var invalidInspected = try JSONSerialization.jsonObject(with: encoder.encode(inspectedRun)) as! [String: Any]
        var inspectedResults = invalidInspected["results"] as! [[String: Any]]
        inspectedResults[0].removeValue(forKey: "diagnostics")
        invalidInspected["results"] = inspectedResults
        try JSONSerialization.data(withJSONObject: ["version": 1, "run": invalidInspected])
            .write(to: invalidDirectory.appendingPathComponent("autoscan-state.json"))
        expectError("saved negative display results without inspection evidence are rejected") {
            _ = try AutoScanStore(directory: invalidDirectory)
        }
        invalidRun = try JSONSerialization.jsonObject(with: encoder.encode(run)) as! [String: Any]
        let future = try JSONSerialization.data(withJSONObject: ["version": 2, "run": invalidRun])
        try future.write(to: invalidDirectory.appendingPathComponent("autoscan-state.json"))
        expectError("newer checkpoint schemas are not overwritten") { _ = try AutoScanStore(directory: invalidDirectory) }

        let blockedDirectory = root.appendingPathComponent("Blocked")
        let blockedStore = try AutoScanStore(directory: blockedDirectory)
        try blockedStore.save(run)
        let blockedSnapshot = blockedStore.run
        let lockedFD = Darwin.open(blockedDirectory.appendingPathComponent(".autoscan-state.lock").path, O_CREAT | O_WRONLY, mode_t(0o600))
        check(lockedFD >= 0 && flock(lockedFD, LOCK_EX | LOCK_NB) == 0, "test holds the checkpoint lock")
        expectError("checkpoint lock contention does not block indefinitely") { try blockedStore.save(interrupted) }
        check(blockedStore.run == blockedSnapshot, "lock contention leaves saved memory unchanged")
        _ = flock(lockedFD, LOCK_UN); Darwin.close(lockedFD)
        try blockedStore.save(interrupted)
        check(blockedStore.run == interrupted, "save can retry after lock release")

        let backup = root.appendingPathComponent("Blocked-original")
        try fm.moveItem(at: blockedDirectory, to: backup)
        try Data("directory replaced with a file for the test".utf8).write(to: blockedDirectory)
        expectError("disk write failure is surfaced") { try blockedStore.save(run) }
        check(blockedStore.run == interrupted, "disk write failure cannot advance the in-memory queue")
        check(fm.fileExists(atPath: backup.appendingPathComponent("autoscan-state.json").path), "last committed checkpoint remains recoverable")
        print("PASS: \(count) automatic scan state fixtures")
    }
}
