#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Exercise the real DeskModel without creating an app or opening a plug-in.

Everything written by the model lives under TemporaryDirectory. The only child
the Swift fixture starts is its own /bin/sleep; a defer terminates and waits for
that retained Process on success and on every thrown test failure.
"""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent

HARNESS = r'''
import Foundation
import Combine
import Darwin

enum FixtureFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let message): return message }
    }
}

final class FakeOCRPreparation: OCRPreparationTask {
    var isRunning = true
    var cancellations = 0
    let completion: (OCRPreparationOutcome) -> Void
    init(_ completion: @escaping (OCRPreparationOutcome) -> Void) { self.completion = completion }
    func cancel() { cancellations += 1 }
    func finish(_ result: OCRPreparationOutcome) { isRunning = false; completion(result) }
    func replay(_ result: OCRPreparationOutcome) { completion(result) }
}

@main struct ModelFixtures {
    static var checks = 0

    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !value() { throw FixtureFailure.failed(message) }
    }

    static func bundle(_ root: URL, name: String, format: String) throws -> Entry {
        let path = root.appendingPathComponent(name + (format == "AU" ? ".component" : ".vst3"))
        let macOS = path.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        // A small Mach-O header is enough for the inventory parser. It is never
        // executable or loaded, and its file metadata provides a real stamp.
        try Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01] + Array(repeating: 0, count: 24))
            .write(to: macOS.appendingPathComponent(name))
        let info: [String: Any] = ["CFBundleExecutable": name,
            "CFBundleIdentifier": "test.plugin-auth-desk." + name,
            "CFBundleShortVersionString": "1.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: path.appendingPathComponent("Contents/Info.plist"))
        return Entry(id: format + ":" + path.path, name: name, vendor: "Fixture Vendor",
            format: format, path: path.path, identifier: "fixture." + name, version: "1.0",
            architectures: Inventory.architectures(macOS.appendingPathComponent(name).path),
            metadataStamp: Inventory.stamp(path: path.path, info: info))
    }

    static func write(_ value: [String: Any], to directory: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("status.json"), options: .atomic)
    }

    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    static func reportReaderFixtures(_ root: URL) throws {
        let directory = root.appendingPathComponent("report-inputs")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let normal = directory.appendingPathComponent("normal.json")
        let data = Data("{\"name\":\"音色 é\",\"state\":\"ready\"}".utf8)
        try data.write(to: normal)
        try expect(HostReportReader.object(at: normal, maximumBytes: data.count)?["name"] as? String == "音色 é",
            "valid UTF-8 object accepted exactly at the byte limit")
        try expect(HostReportReader.object(at: normal, maximumBytes: data.count - 1) == nil,
            "byte limit rejects a valid object even one byte over")
        try expect(HostReportReader.object(at: normal, maximumBytes: 0) == nil,
            "invalid read budget rejected")
        try expect(HostReportReader.object(at: directory.appendingPathComponent("absent"), maximumBytes: 100) == nil,
            "missing report is absent, not a license verdict")
        try expect(HostReportReader.object(at: directory, maximumBytes: 100) == nil,
            "directory is not read as a report")
        for invalid in [Data(), Data("{unfinished".utf8), Data("[1,2]".utf8), Data([0xff, 0xfe])] {
            let path = directory.appendingPathComponent("invalid.json")
            try invalid.write(to: path)
            try expect(HostReportReader.object(at: path, maximumBytes: 100) == nil,
                "empty, invalid UTF-8, malformed and non-object JSON fail safely")
        }
        let huge = directory.appendingPathComponent("huge.json")
        try Data().write(to: huge)
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(1) << 40) // Sparse synthetic file, no large allocation.
        try handle.close()
        try expect(HostReportReader.object(at: huge, maximumBytes: HostReportReader.statusLimit) == nil,
            "terabyte sparse regular file rejected before allocation or read")
        let fifo = directory.appendingPathComponent("pipe.json")
        try expect(mkfifo(fifo.path, mode_t(0o600)) == 0, "create synthetic FIFO without a writer")
        try expect(HostReportReader.object(at: fifo, maximumBytes: 100) == nil,
            "FIFO without a writer rejected without blocking open")
        for target in [normal, fifo] {
            let link = directory.appendingPathComponent("link-" + target.lastPathComponent)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            try expect(HostReportReader.object(at: link, maximumBytes: 100) == nil,
                "symlinks to a valid report or FIFO rejected")
        }
    }

    static func inventoryCacheFixtures(_ root: URL) throws {
        let support = root.appendingPathComponent("cache-fixtures")
        let cache = support.appendingPathComponent("inventory.json")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let invalid = DeskModel(directory: support, refreshOnLaunch: false)
        try expect(invalid.entries.isEmpty && !invalid.inventoryError.isEmpty,
            "non-file inventory cache is rejected with a visible recovery message")
        try FileManager.default.removeItem(at: cache)
        try expect(mkfifo(cache.path, mode_t(0o600)) == 0, "create isolated inventory FIFO")
        let start = Date()
        let piped = DeskModel(directory: support, refreshOnLaunch: false)
        try expect(piped.entries.isEmpty && !piped.inventoryError.isEmpty && Date().timeIntervalSince(start) < 2,
            "inventory FIFO cannot block application startup")
        try FileManager.default.removeItem(at: cache)
        try Data("{broken".utf8).write(to: cache)
        let corrupt = DeskModel(directory: support, refreshOnLaunch: false)
        try expect(corrupt.entries.isEmpty && !corrupt.inventoryError.isEmpty,
            "malformed inventory reports its recovery path")
        let entry = try bundle(root, name: "音色 🎹 cache", format: "VST3")
        try JSONEncoder().encode([entry]).write(to: cache, options: .atomic)
        let recovered = DeskModel(directory: support, refreshOnLaunch: false)
        try expect(recovered.entries == [entry] && recovered.inventoryError.isEmpty,
            "valid Unicode inventory loads after the invalid cache is replaced")
    }

    static func requestFixtures(_ entry: Entry) throws {
        let ordinary = AutoScanTask(entry: entry)
        let retry = AutoScanTask(entry: entry, classID: "selected-class", previousAttempts: [
            AutoScanAttempt(outcome: .timedOut, reason: "creating_instance_heartbeat_stalled", checkedAt: Date())])
        for (task, expected) in [(ordinary, 35), (retry, 70)] {
            let request = DeskModel.hostRequest(entry: task.entry, classID: task.classID, automatic: true,
                scanBudgetSeconds: task.launchBudgetSeconds, parentPID: 12345)
            let decoded = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: request)) as! [String: Any]
            try expect(decoded["scanDeadlineSeconds"] as? Int == expected && decoded["mode"] as? String == "scan",
                "ordinary/retry task budget reaches the serialized host request as 35/70 seconds")
            try expect(decoded["path"] as? String == entry.path && decoded["identifier"] as? String == entry.identifier
                && decoded["classID"] as? String == task.classID && decoded["parentPID"] as? Int == 12345,
                "deadline selection does not change the requested plug-in/class or parent ownership")
        }
        let manual = DeskModel.hostRequest(entry: entry, classID: "manual-class", automatic: false,
            scanBudgetSeconds: 60, parentPID: 12345)
        try expect(manual["mode"] as? String == "manual" && manual["scanDeadlineSeconds"] == nil,
            "manual authorization sessions never inherit an automatic scan deadline")
        for budget in [0.0, -1.0, 1000000.0, Double.nan, Double.infinity] {
            let request = DeskModel.hostRequest(entry: entry, classID: "", automatic: true,
                scanBudgetSeconds: budget, parentPID: 12345)
            try expect(request["scanDeadlineSeconds"] as? Int == 35 && JSONSerialization.isValidJSONObject(request),
                "unexpected launch budgets cannot create an unbounded or invalid JSON host deadline")
        }
    }

    static func preparationFixtures(_ root: URL, entries: [Entry]) throws {
        try expect(OCRPreparationProcess.validResponse(Data("{\"version\":1,\"ready\":true}".utf8)),
            "warmup accepts only its positive fixed typed response")
        for json in ["", "{}", "[]", "{\"version\":true,\"ready\":true}",
                     "{\"version\":1,\"ready\":1}", "{\"version\":1,\"ready\":false}",
                     "{\"version\":2,\"ready\":true}", "{\"version\":1,\"ready\":true,\"text\":\"extra\"}",
                     "{\"version\":1,\"ready\":true} trailing", String(repeating: " ", count: 4097)] {
            try expect(!OCRPreparationProcess.validResponse(Data(json.utf8)), "malformed or unbounded preparation output cannot start a scan")
        }
        let model = DeskModel(directory: root.appendingPathComponent("preparation-success"),
            initialEntries: [entries[0]], refreshOnLaunch: false)
        var jobs: [FakeOCRPreparation] = []
        model.prepareOCR = { _, completion in let job = FakeOCRPreparation(completion); jobs.append(job); return job }
        var launches = 0
        model.automaticScanner.launch = { _ in launches += 1; return nil }
        model.startAutomaticScan()
        try expect(model.preparingAutomaticScan && jobs.count == 1 && launches == 0
            && model.automaticScanner.totalCount == 0, "preparation precedes every queue write and plug-in launch")
        model.startAutomaticScan()
        model.resumeAutomaticScan()
        try expect(jobs.count == 1, "repeated start or resume cannot duplicate a preparation")
        try expect(model.open(entries[0]) == nil && model.sessions.isEmpty,
            "manual plugin launch is blocked while preparing")
        model.category = "プラグイン"
        model.startReview()
        model.refresh()
        try expect(model.workflow == nil && !model.scanning,
            "manual workflow and inventory refresh cannot race preparation")
        model.entries = entries
        model.query = "hidden-all"
        model.format = "AU"
        model.favoritesOnly = true
        model.favorites = []
        jobs[0].finish(.ready)
        try expect(!model.preparingAutomaticScan && model.automaticScanner.totalCount == entries.count && launches == 2,
            "successful preparation starts the latest complete pending inventory regardless of UI filters")
        jobs[0].replay(.ready)
        try expect(launches == 2, "a duplicate ready callback cannot start the queue again")
        model.automaticScanner.tick()
        model.automaticScanner.tick()
        try expect(model.automaticScanner.isComplete, "fake hosts finish without any real plugin")
        model.startAutomaticScan()
        try expect(jobs.count == 1 && !model.preparingAutomaticScan,
            "successful warmup is cached only for this model lifetime")
        model.automaticScanner.shutdown()

        let cancelled = DeskModel(directory: root.appendingPathComponent("preparation-cancel"),
            initialEntries: [entries[0]], refreshOnLaunch: false)
        var cancellationJobs: [FakeOCRPreparation] = []
        cancelled.prepareOCR = { _, completion in let job = FakeOCRPreparation(completion); cancellationJobs.append(job); return job }
        var cancelledLaunches = 0
        cancelled.automaticScanner.launch = { _ in cancelledLaunches += 1; return nil }
        cancelled.startAutomaticScan()
        cancelled.cancelAutomaticPreparation()
        cancelled.startAutomaticScan()
        try expect(cancelled.preparingAutomaticScan && cancelled.stoppingAutomaticPreparation
            && cancellationJobs.count == 1 && cancellationJobs[0].cancellations == 1,
            "cancel retains the owned preparation until exit and prevents overlapping restart")
        cancellationJobs[0].finish(.ready)
        try expect(!cancelled.preparingAutomaticScan && cancelledLaunches == 0
            && cancelled.automaticScanner.totalCount == 0 && cancelled.notice.contains("中止"),
            "success racing cancellation never creates a queue or false completion")
        cancelled.startAutomaticScan()
        cancellationJobs[0].replay(.ready)
        try expect(cancelled.preparingAutomaticScan && cancellationJobs.count == 2 && cancelledLaunches == 0,
            "an old callback cannot finish or launch the new preparation generation")
        cancellationJobs[1].finish(.failed)
        try expect(!cancelled.preparingAutomaticScan && cancelled.notice.contains("再試行")
            && cancelled.automaticScanner.totalCount == 0, "preparation failure is visible and retryable without fake scan results")
        cancelled.startAutomaticScan()
        cancellationJobs[2].finish(.ready)
        try expect(cancellationJobs.count == 3 && cancelledLaunches == 1,
            "cancelled and failed preparations are not cached and a later success starts once")
        cancelled.automaticScanner.shutdown()

        let sync = DeskModel(directory: root.appendingPathComponent("preparation-synchronous"),
            initialEntries: [entries[0]], refreshOnLaunch: false)
        sync.prepareOCR = { _, completion in
            let job = FakeOCRPreparation(completion); job.finish(.failed); return job
        }
        sync.startAutomaticScan()
        try expect(!sync.preparingAutomaticScan && sync.automaticScanner.totalCount == 0 && sync.notice.contains("再試行"),
            "synchronous launch failure does not leave a stale preparation token or handle")

        let closing = DeskModel(directory: root.appendingPathComponent("preparation-shutdown"),
            initialEntries: [entries[0]], refreshOnLaunch: false)
        var closingJob: FakeOCRPreparation?
        closing.prepareOCR = { _, completion in let job = FakeOCRPreparation(completion); closingJob = job; return job }
        var shutdownFinished = false
        closing.startAutomaticScan()
        closing.shutdown { shutdownFinished = true }
        try expect(!shutdownFinished && closingJob?.cancellations == 1,
            "application shutdown waits for its owned preparation child to exit")
        closingJob?.finish(.ready)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        closing.startAutomaticScan()
        closingJob?.replay(.ready)
        try expect(shutdownFinished && closing.automaticScanner.totalCount == 0 && !closing.preparingAutomaticScan,
            "shutdown and a late ready callback cannot launch or orphan preparation work")

        let resumeDirectory = root.appendingPathComponent("preparation-resume")
        var run = AutoScanRun(tasks: [AutoScanTask(entry: entries[0])])
        run.resume(); run.pause()
        try AutoScanStore(directory: resumeDirectory.appendingPathComponent("Automatic Scan/worker-0")).save(run)
        let resumed = DeskModel(directory: resumeDirectory, initialEntries: [entries[0]], refreshOnLaunch: false)
        var resumeJobs: [FakeOCRPreparation] = []
        resumed.prepareOCR = { _, completion in let job = FakeOCRPreparation(completion); resumeJobs.append(job); return job }
        var resumeLaunches = 0
        resumed.automaticScanner.launch = { _ in resumeLaunches += 1; return nil }
        resumed.resumeAutomaticScan()
        try expect(resumed.preparingAutomaticScan && resumeLaunches == 0 && resumed.automaticScanner.canResume,
            "a saved queue remains paused until a new app lifetime finishes preparation")
        resumeJobs[0].finish(.failed)
        try expect(resumed.automaticScanner.canResume && resumed.automaticScanner.completedCount == 0,
            "failed resume preparation preserves all saved pending work")
        resumed.resumeAutomaticScan()
        resumeJobs[1].finish(.ready)
        try expect(resumeLaunches == 1 && !resumed.preparingAutomaticScan,
            "successful preparation resumes the saved queue once")
        resumed.automaticScanner.shutdown()
    }

    static func scannerMetadataFixtures(_ root: URL, entry: Entry, process: Process) throws {
        let support = root.appendingPathComponent("scan-metadata-fixtures")
        let directory = support.appendingPathComponent("session")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = DeskModel(directory: support, initialEntries: [entry], refreshOnLaunch: false)
        // Exact quarter-second fixtures avoid unrelated Date epoch-rounding
        // differences when the host's Unix timestamp passes through JSON.
        let started = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 2)
        let id = UUID()
        func freshSession() -> HostSession {
            HostSession(id: id, entry: entry, process: process, directory: directory, started: started,
                lifecycle: SessionLifecycle(name: entry.name, startedAt: started))
        }
        func heartbeat(_ value: Double) throws {
            try JSONSerialization.data(withJSONObject: ["timestamp": value])
                .write(to: directory.appendingPathComponent("heartbeat.json"), options: .atomic)
        }
        model.sessions = [freshSession()]
        let firstReady = started.addingTimeInterval(0.25)
        let firstBeat = floor(Date().timeIntervalSince1970)
        var report: [String: Any] = ["state": "loading", "name": entry.name,
            "readyAt": firstReady.timeIntervalSince1970, "phase": "error", "lastActivePhase": "creating_instance"]
        try heartbeat(firstBeat)
        try write(report, to: directory)
        model.poll()
        let initial = model.automaticScanner.observe(id)
        try expect(initial?.readyAt == firstReady && initial?.heartbeatAt == Date(timeIntervalSince1970: firstBeat),
            "host readiness and heartbeat timestamps reach the real scanner adapter without using poll time")
        try expect(initial?.phase == "creating_instance" && initial?.needsActivation == false && model.currentRecords.isEmpty,
            "last active phase is retained without converting diagnostic metadata into license evidence")

        var publications = 0
        let subscription = model.$sessions.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        try heartbeat(firstBeat + 0.25)
        model.poll()
        try expect(publications > 0 && model.automaticScanner.observe(id)?.heartbeatAt == Date(timeIntervalSince1970: firstBeat + 0.25),
            "heartbeat-only changes are published to the scanner instead of discarded by session equality")
        report["lastActivePhase"] = "creating_editor"
        report["failureReason"] = "instance_creation_failed"
        report["terminationReason"] = "scan_time_limit"
        report["probeDiagnostic"] = "ocr_time_budget_exceeded"
        report["readyAt"] = firstReady.addingTimeInterval(1).timeIntervalSince1970
        try write(report, to: directory); model.poll()
        let updated = model.automaticScanner.observe(id)
        try expect(updated?.phase == "creating_editor" && updated?.failureReason == "instance_creation_failed"
            && updated?.terminationReason == "scan_time_limit" && updated?.probeDiagnostic == "ocr_time_budget_exceeded",
            "phase and fixed failure/termination diagnostics survive poll and scanner observation")
        try expect(updated?.readyAt == firstReady, "later host reports never slide the initial readiness window")

        report["lastActivePhase"] = "/not/a/fixed/code"
        report["failureReason"] = String(repeating: "x", count: 65)
        report["terminationReason"] = "arbitrary raw error text"
        report["probeDiagnostic"] = "raw OCR text must not be a diagnostic"
        try write(report, to: directory); model.poll()
        let rejected = model.automaticScanner.observe(id)
        try expect(rejected?.phase == "creating_editor" && rejected?.failureReason == "instance_creation_failed"
            && rejected?.terminationReason == "scan_time_limit" && rejected?.probeDiagnostic == "ocr_time_budget_exceeded",
            "raw text and oversized diagnostics do not replace the bounded fixed-code fields")
        report["probeDiagnostic"] = "ocr_no_supported_status"
        try write(report, to: directory); model.poll()
        try expect(model.automaticScanner.observe(id)?.probeDiagnostic == "ocr_no_supported_status",
            "OCR-only diagnostic changes are published without waiting for a lifecycle or heartbeat change")
        for invalidBeat in [started.timeIntervalSince1970 - 10, Date().timeIntervalSince1970 + 60] {
            try heartbeat(invalidBeat); model.poll()
            try expect(model.automaticScanner.observe(id)?.heartbeatAt == updated?.heartbeatAt,
                "stale or far-future heartbeat cannot refresh the scanner's progress timestamp")
        }
        try FileManager.default.removeItem(at: directory.appendingPathComponent("heartbeat.json"))
        for invalidReady in [started.timeIntervalSince1970 - 10, Date().timeIntervalSince1970 + 60, "invalid"] as [Any] {
            model.sessions = [freshSession()]
            try write(["state": "loading", "readyAt": invalidReady], to: directory); model.poll()
            try expect(model.automaticScanner.observe(id)?.readyAt == nil,
                "invalid host readiness is not accepted while the plug-in is still loading")
        }
        model.sessions = [freshSession()]
        try write(["state": "loading", "readyAt": started.addingTimeInterval(-0.25).timeIntervalSince1970], to: directory)
        model.poll()
        try expect(model.automaticScanner.observe(id)?.readyAt == started,
            "a valid near-start host timestamp is clamped to session start so the scanner can observe readiness")
        try expect(model.currentRecords.isEmpty && model.unactivated.isEmpty,
            "ready, heartbeat, phase and errors never manufacture an activation verdict")
    }

    static func run() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try inventoryCacheFixtures(root)
        try reportReaderFixtures(root)
        let support = root.appendingPathComponent("support")
        let a = try bundle(root, name: "BundleA", format: "VST3")
        let unknown = try bundle(root, name: "Unknown", format: "VST3")
        let au = try bundle(root, name: "BundleA_AU", format: "AU")
        try expect(!a.metadataStamp.isEmpty && a.architectures == ["arm64"], "real fixture binary stamp and architecture")
        try requestFixtures(a)

        let seed = try LicenseStore(directory: support)
        try seed.upsert(LicenseRecord(entryID: a.id, metadataStamp: "older-binary",
            classID: "obsolete-class", productName: "Obsolete", status: .needsActivation, source: .detected))
        let model = DeskModel(directory: support, initialEntries: [a, unknown, au], refreshOnLaunch: false)
        model.favoritesOnly = false
        try expect(model.unactivated.isEmpty && model.currentRecords.isEmpty, "unknown and old-binary records excluded")
        try expect(model.needsReview(a) && model.needsReview(unknown), "unknown remains available for review")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        try scannerMetadataFixtures(root, entry: a, process: process)
        let started = Date().addingTimeInterval(-0.5)
        let observed = Date().timeIntervalSince1970
        let cacheFailureSupport = root.appendingPathComponent("cache-write-failure")
        let blockedCache = cacheFailureSupport.appendingPathComponent("inventory.json")
        try FileManager.default.createDirectory(at: blockedCache, withIntermediateDirectories: true)
        let cacheFailure = DeskModel(directory: cacheFailureSupport, initialEntries: [a], refreshOnLaunch: false)
        cacheFailure.inventoryError = ""
        let cacheReport = cacheFailureSupport.appendingPathComponent("session")
        try FileManager.default.createDirectory(at: cacheReport, withIntermediateDirectories: true)
        cacheFailure.sessions = [HostSession(id: UUID(), entry: a, process: process, directory: cacheReport,
            started: started, lifecycle: SessionLifecycle(name: a.name, startedAt: started))]
        try write(["state": "ready", "classID": "cache-class", "name": "Cache Product",
            "classes": ["Cache Product"], "classEntries": [["classID": "cache-class", "name": "Cache Product"]]],
            to: cacheReport)
        cacheFailure.poll()
        try expect(cacheFailure.entries.first?.aliases.contains("Cache Product") == true && !cacheFailure.inventoryError.isEmpty,
            "failed cache save preserves the in-memory catalog and reports failure")
        try expect((try blockedCache.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true,
            "failed cache save leaves the blocking destination intact")
        try FileManager.default.removeItem(at: blockedCache)
        try write(["state": "ready", "classID": "cache-class", "name": "Cache Product",
            "classes": ["Cache Product", "Recovered Product"],
            "classEntries": [["classID": "cache-class", "name": "Cache Product"],
                             ["classID": "recovered-class", "name": "Recovered Product"]]], to: cacheReport)
        cacheFailure.poll()
        let restoredCache = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: blockedCache))
        try expect(cacheFailure.inventoryError.isEmpty && restoredCache == cacheFailure.entries,
            "a successful later cache save clears the error and persists the current catalog")
        let sessionDirectory = support.appendingPathComponent("Sessions/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let session = HostSession(id: UUID(), entry: a, process: process, directory: sessionDirectory,
            started: started, lifecycle: SessionLifecycle(name: a.name, startedAt: started))
        model.sessions = [session]
        model.workflow = ActivationWorkflow(mode: .review,
            targets: [ActivationTarget(entry: a, classID: "", productName: a.name)])
        model.workflow?.sessionID = session.id
        var workflowPublications = 0
        let subscription = model.$workflow.dropFirst().sink { _ in workflowPublications += 1 }
        defer { subscription.cancel() }
        var report: [String: Any] = ["state": "ready", "classID": "class-A", "name": "Product Alpha",
            "classes": ["Product Alpha", "Product Beta"],
            "classEntries": [["classID": "class-A", "name": "Product Alpha"],
                             ["classID": "class-B", "name": "Product Beta"]]]
        try write(report, to: sessionDirectory)
        model.poll()
        try expect(model.sessions[0].classID == "class-A", "poll ingests actual product identity")
        try expect(model.sessions[0].lifecycle.displayName == "Product Alpha", "poll ingests display name")
        try expect(model.unactivated.isEmpty, "ready UI does not imply license failure or success")
        try expect(FileManager.default.fileExists(atPath: support.appendingPathComponent("class-catalog.json").path),
            "class catalog is written only into injected support directory")
        try expect(model.workflow?.targets.count == 2 && model.workflow?.targets.last?.classID == "class-B",
            "actual model metadata expands unreviewed sibling class once")
        model.poll()
        model.poll()
        try expect(workflowPublications == 1, "repeated metadata does not republish unchanged workflow")
        model.workflow = nil

        var oversized = report
        oversized["classID"] = "oversized-must-not-be-ingested"
        oversized["padding"] = String(repeating: "x", count: HostReportReader.statusLimit)
        try write(oversized, to: sessionDirectory)
        model.poll()
        try expect(model.sessions[0].classID == "class-A" && model.currentRecords.isEmpty,
            "actual poll rejects oversized status without changing identity or license state")
        let heartbeat = sessionDirectory.appendingPathComponent("heartbeat.json")
        try Data("{\"timestamp\":0,\"padding\":\"\(String(repeating: "x", count: HostReportReader.heartbeatLimit))\"}".utf8)
            .write(to: heartbeat)
        try write(report, to: sessionDirectory)
        model.poll()
        try expect(model.sessions[0].state == "ready",
            "oversized heartbeat cannot mark a valid ready report unresponsive")
        try Data("{\"timestamp\":0}".utf8).write(to: heartbeat)
        model.poll()
        try expect(model.sessions[0].state == "waiting", "normal heartbeat still drives responsiveness status")
        try FileManager.default.removeItem(at: heartbeat)

        report["licenseCandidate"] = ["rule": "product_not_activated", "observedAt": observed]
        try write(report, to: sessionDirectory); model.poll()
        try expect(model.sessions[0].candidate?.rule == "product_not_activated"
            && model.automaticScanner.observe(session.id)?.candidate == model.sessions[0].candidate,
            "validated first observation reaches scanner without becoming confirmed evidence")
        try expect(model.currentRecords.isEmpty && model.unactivated.isEmpty,
            "candidate alone never writes a license record")
        for invalid in [
            ["rule": "unknown-rule", "observedAt": observed],
            ["rule": "product_not_activated", "observedAt": started.timeIntervalSince1970 - 10],
            ["rule": "product_not_activated", "observedAt": Date().timeIntervalSince1970 + 60],
            ["rule": "product_not_activated", "observedAt": "invalid"]
        ] as [[String: Any]] {
            report["licenseCandidate"] = invalid
            try write(report, to: sessionDirectory); model.poll()
            try expect(model.sessions[0].candidate == nil, "invalid candidate clears transient observation")
        }
        report["licenseCandidate"] = ["rule": "product_not_activated", "observedAt": observed]
        try write(report, to: sessionDirectory); model.poll()
        report.removeValue(forKey: "classID")
        try write(report, to: sessionDirectory); model.poll()
        try expect(model.sessions[0].candidate == nil, "candidate without current report class identity is rejected")
        report["classID"] = "class-A"
        try write(report, to: sessionDirectory); model.poll()
        report.removeValue(forKey: "licenseCandidate")
        try write(report, to: sessionDirectory); model.poll()
        try expect(model.sessions[0].candidate == nil && model.automaticScanner.observe(session.id)?.candidate == nil,
            "candidate disappearance clears both session and scanner adapter")

        report["licenseEvidence"] = ["state": "needsActivation", "classID": "wrong-class",
            "name": "Wrong Product", "rule": "fixture.explicit-unactivated", "observedAt": observed]
        try write(report, to: sessionDirectory)
        model.poll()
        try expect(model.unactivated.isEmpty, "mismatched evidence cannot mark another class")

        report["licenseEvidence"] = ["state": "needsActivation", "classID": "class-A",
            "name": "Product Alpha", "rule": "fixture.explicit-unactivated", "observedAt": observed]
        try write(report, to: sessionDirectory)
        model.poll()
        try expect(model.unactivated.count == 1 && model.unactivated[0].classID == "class-A", "explicit evidence creates exactly one unactivated product")
        try expect(model.unactivated[0].source == .detected, "automatic evidence retains detected source")
        let observedByScanner = model.automaticScanner.observe(session.id)
        try expect(observedByScanner?.needsActivation == true && observedByScanner?.classID == "class-A"
            && observedByScanner?.classes.count == 2, "automatic adapter receives exact detected class and discovered products")
        let firstReady = model.sessions[0].readyAt
        try expect(model.records(for: unknown).isEmpty && model.records(for: au).isEmpty,
            "evidence never propagates to another bundle or AU counterpart")
        model.query = "Product Alpha"
        try expect(model.unactivated.count == 1, "class name search finds product inside bundle")
        model.query = "Product Beta"
        try expect(model.unactivated.isEmpty, "unrecorded sibling is not presented as unactivated")
        model.query = ""
        model.format = "AU"
        try expect(model.unactivated.isEmpty, "format filter isolates AU from VST3")
        model.format = "すべて"
        try expect(model.mark(model.sessions[0], as: .activated), "manual confirmation saves")
        try expect(model.unactivated.isEmpty, "manual activation removes item from unactivated list")
        for _ in 0..<3 { model.poll() }
        try expect(model.sessions[0].readyAt == firstReady && firstReady != nil,
            "repeated ready reports do not extend automatic observation window")
        try expect(model.automaticScanner.observe(session.id)?.needsActivation == false,
            "automatic adapter reflects manual activation without stale detector verdict")
        try expect(model.records(for: a).first { $0.classID == "class-A" }?.source == .user,
            "historical polling cannot replace user source")
        try expect(model.unactivated.isEmpty, "historical polling cannot resurrect activated item")

        let reopened = DeskModel(directory: support, initialEntries: [a, unknown, au], refreshOnLaunch: false)
        reopened.sessions = [session]
        reopened.poll() // Same old evidence, but fresh per-session observation cache.
        try expect(reopened.unactivated.isEmpty && reopened.records(for: a).first { $0.classID == "class-A" }?.status == .activated,
            "persisted user confirmation wins historical evidence after reload")
        try expect(reopened.sessions[0].evidenceObservedAt == observed, "ignored old observation is acknowledged once")

        var closed = model.sessions[0]
        closed = HostSession(id: closed.id, entry: closed.entry, process: Process(), directory: closed.directory,
            started: closed.started, lifecycle: closed.lifecycle, knownClasses: closed.knownClasses,
            classID: closed.classID, evidenceObservedAt: closed.evidenceObservedAt)
        closed.lifecycle.exited(code: 0)
        model.sessions = [closed]
        let target = ActivationTarget(entry: a, classID: "class-A", productName: "Product Alpha")
        model.workflow = ActivationWorkflow(mode: .review, targets: [target])
        model.workflow?.sessionID = closed.id
        try expect(model.open(unknown) == nil, "queue excludes independent plugin launches")
        try expect(model.workflow?.index == 0, "blocked launch preserves current queue item")
        model.finishWorkflowItem(as: .notRequired)
        try expect(model.workflow == nil, "explicit confirmation advances and finishes closed session")
        let confirmed = try LicenseStore(directory: support).state(for: a, classID: "class-A")
        try expect(confirmed?.status == .notRequired && confirmed?.source == .user,
            "queue completion persists user confirmation before finishing")
        model.finishWorkflowItem(as: .needsActivation)
        try expect(try LicenseStore(directory: support).state(for: a, classID: "class-A")?.status == .notRequired,
            "second completion click cannot mark or skip a later item")

        model.workflow = ActivationWorkflow(mode: .review, targets: [target])
        model.workflow?.sessionID = closed.id
        let otherWriter = try LicenseStore(directory: support)
        try otherWriter.upsert(LicenseRecord(entryID: unknown.id, metadataStamp: unknown.metadataStamp,
            classID: "unknown-class", productName: "Unknown", status: .notRequired, source: .user))
        model.finishWorkflowItem(as: .activated)
        try expect(model.workflow?.index == 0 && model.workflow?.waitingForExit == false,
            "concurrent writer conflict cannot advance queue")
        try expect(!model.licenseError.isEmpty, "concurrent writer conflict is visible")
        model.reloadLicenseState()
        try expect(model.licenseError.isEmpty && model.records(for: unknown).count == 1,
            "explicit reload recovers records without discarding other writer")
        model.finishWorkflowItem(as: .activated)
        try expect(model.workflow == nil && model.records(for: a).first { $0.classID == "class-A" }?.source == .user,
            "queue can safely retry after explicit reload")

        // Review completeness must use the exact enumerated class IDs, not
        // names, aliases, or an assumption that a bundle has only one product.
        let single = try bundle(root, name: "SingleConfirmed", format: "VST3")
        let sameNames = try bundle(root, name: "SameNamedClasses", format: "VST3")
        let legacyOnly = try bundle(root, name: "LegacyNamesOnly", format: "VST3")
        var sharedAU1 = try bundle(root, name: "SharedAU", format: "AU")
        var sharedAU2 = sharedAU1
        sharedAU1.id += "|component-one"; sharedAU1.identifier += ".one"
        sharedAU2.id += "|component-two"; sharedAU2.identifier += ".two"
        let reviewSupport = root.appendingPathComponent("review-support")
        let review = DeskModel(directory: reviewSupport,
            initialEntries: [single, sameNames, legacyOnly, sharedAU1, sharedAU2], refreshOnLaunch: false)
        func reviewReport(_ entry: Entry, selected: String, products: [[String: String]]?) throws {
            let directory = reviewSupport.appendingPathComponent("Sessions/" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var value: [String: Any] = ["state": "ready", "name": products?.first?["name"] ?? entry.name, "classID": selected]
            value["classes"] = products?.compactMap { $0["name"] } ?? [entry.name]
            if let products = products { value["classEntries"] = products }
            try write(value, to: directory)
            review.sessions = [HostSession(id: UUID(), entry: entry, process: process, directory: directory,
                started: started, lifecycle: SessionLifecycle(name: entry.name, startedAt: started))]
            review.poll()
        }
        try reviewReport(legacyOnly, selected: "legacy-class", products: nil)
        try expect(review.mark(review.sessions[0], as: .activated), "legacy names-only manual record fixture saves")
        try expect(review.needsReview(legacyOnly), "names-only catalog plus one confirmed class cannot hide unenumerated siblings")

        try reviewReport(single, selected: "only-class", products: [["classID": "only-class", "name": "Actual Product"]])
        try expect(review.mark(review.sessions[0], as: .notRequired), "manual single-class confirmation saves")
        try expect(!review.needsReview(single), "confirmed single enumerated class is not repeatedly rechecked")
        let reloadedReview = DeskModel(directory: reviewSupport, refreshOnLaunch: false)
        try expect(!reloadedReview.needsReview(single), "single-class completeness and confirmation survive app reload")

        let duplicateNames = [["classID": "distinct-one", "name": "Same Product"],
                              ["classID": "distinct-two", "name": "Same Product"]]
        try reviewReport(sameNames, selected: "distinct-one", products: duplicateNames)
        try expect(review.mark(review.sessions[0], as: .activated), "first same-name class confirmation saves")
        try expect(review.needsReview(sameNames), "same-name sibling remains unconfirmed by distinct class ID")
        try reviewReport(sameNames, selected: "distinct-two", products: duplicateNames)
        try expect(review.mark(review.sessions[0], as: .notRequired), "second same-name class confirmation saves")
        try expect(!review.needsReview(sameNames), "all enumerated class IDs confirmed completes bundle review")

        try reviewReport(sharedAU1, selected: "au-one", products: [["classID": "au-one", "name": "SharedAU"]])
        try expect(review.mark(review.sessions[0], as: .activated), "first AU component manual confirmation saves")
        try expect(!review.needsReview(sharedAU1) && review.needsReview(sharedAU2),
            "same-path AU component confirmation never completes another component")
        try reviewReport(sharedAU2, selected: "au-two", products: [["classID": "au-two", "name": "SharedAU"]])
        try expect(review.mark(review.sessions[0], as: .activated), "second AU component manual confirmation saves")
        try expect(!review.needsReview(sharedAU1) && !review.needsReview(sharedAU2),
            "separately confirmed AU components do not need repeated review")

        let malformed = try bundle(root, name: "MalformedEnumeration", format: "VST3")
        let malformedModel = DeskModel(directory: root.appendingPathComponent("malformed-support"),
            initialEntries: [malformed], refreshOnLaunch: false)
        let malformedDirectory = root.appendingPathComponent("malformed-report")
        try FileManager.default.createDirectory(at: malformedDirectory, withIntermediateDirectories: true)
        try write(["state": "ready", "name": "One", "classID": "valid-one", "classes": ["One", "Two"],
            "classEntries": [["classID": "valid-one", "name": "One"], ["classID": "", "name": "Two"]]], to: malformedDirectory)
        malformedModel.sessions = [HostSession(id: UUID(), entry: malformed, process: process, directory: malformedDirectory,
            started: started, lifecycle: SessionLifecycle(name: malformed.name, startedAt: started))]
        malformedModel.poll()
        try expect(malformedModel.mark(malformedModel.sessions[0], as: .activated), "partial enumeration fixture confirmation saves")
        try expect(malformedModel.needsReview(malformed), "malformed class entry cannot shrink full enumeration to one confirmed product")
        try write(["state": "ready", "name": "One", "classID": "valid-one", "classes": ["One", "Two"],
            "classEntries": [["classID": "valid-one", "name": "One"]]], to: malformedDirectory)
        malformedModel.poll()
        try expect(malformedModel.needsReview(malformed), "truncated classEntries cannot claim completeness against a longer class names list")

        // A binary change invalidates both display and in-flight manual updates.
        let binary = URL(fileURLWithPath: a.path).appendingPathComponent("Contents/MacOS/BundleA")
        let file = try FileHandle(forWritingTo: binary)
        try file.seekToEnd()
        try file.write(contentsOf: Data([0x01]))
        try file.close()
        var updated = a
        updated.metadataStamp = Inventory.stamp(path: a.path, info: Inventory.plist(a.path + "/Contents/Info.plist"))
        try expect(updated.metadataStamp != a.metadataStamp, "binary replacement changes identity")
        let upgraded = DeskModel(directory: support, initialEntries: [updated, unknown, au], refreshOnLaunch: false)
        try expect(upgraded.records(for: updated).isEmpty && upgraded.needsReview(updated),
            "new binary is unknown until rechecked")
        model.workflow = ActivationWorkflow(mode: .review, targets: [target])
        model.workflow?.sessionID = closed.id
        model.finishWorkflowItem(as: .needsActivation)
        try expect(model.workflow?.index == 0 && model.workflow?.waitingForExit == false,
            "in-flight confirmation rejects changed binary without advancing")
        try expect(model.unactivated.isEmpty, "rejected confirmation does not manufacture unactivated record")
        model.cancelWorkflow()

        let wholeInventory = DeskModel(directory: root.appendingPathComponent("whole-inventory"),
            initialEntries: [updated, unknown, au], refreshOnLaunch: false)
        wholeInventory.prepareOCR = { _, completion in
            let job = FakeOCRPreparation(completion); job.finish(.ready); return job
        }
        var launchAttempts = 0
        wholeInventory.automaticScanner.launch = { _ in launchAttempts += 1; return nil }
        wholeInventory.query = "does-not-match-any-product"
        wholeInventory.format = "AU"
        wholeInventory.favoritesOnly = true
        wholeInventory.favorites = []
        try expect(wholeInventory.filtered.isEmpty, "fixture initially hides all plugins using UI filters")
        wholeInventory.startAutomaticScan()
        try expect(wholeInventory.automaticScanner.totalCount == 3 && launchAttempts == 2,
            "automatic scan includes entire unknown inventory regardless of UI filtering")
        wholeInventory.automaticScanner.shutdown()

        // Process exit alone is not enough: the termination callback must first
        // ingest the final status and complete SessionLifecycle.
        var pendingFinal = HostSession(id: UUID(), entry: unknown, process: Process(),
            directory: root.appendingPathComponent("no-process"), started: Date(),
            lifecycle: SessionLifecycle(name: unknown.name))
        wholeInventory.sessions = [pendingFinal]
        try expect(wholeInventory.automaticScanner.observe(pendingFinal.id)?.isRunning == true,
            "automatic adapter retains slot until final lifecycle callback completes")
        pendingFinal.lifecycle.exited(code: 0)
        wholeInventory.sessions = [pendingFinal]
        try expect(wholeInventory.automaticScanner.observe(pendingFinal.id)?.isRunning == false,
            "automatic adapter releases slot only after lifecycle completion")
        try preparationFixtures(root, entries: [updated, unknown, au])
        print("PASS: \(checks) DeskModel integration checks (poll, evidence, filters, queue, persistence, conflicts, binary identity)")
    }
}
'''


def main():
    source = (ROOT / "main.swift").read_text()
    marker = "\nstruct DeskView: View {"
    if source.count(marker) != 1:
        raise RuntimeError("Expected exactly one DeskView boundary; refusing to compile app launch code")
    model = source.split(marker, 1)[0]
    if "initialEntries: [Entry]? = nil" not in model or "directory: supportDirectory" not in model:
        raise RuntimeError("DeskModel must inject supportDirectory, including class-catalog writes")
    with tempfile.TemporaryDirectory(prefix="plugin-auth-model-tests-") as temporary:
        temporary = Path(temporary)
        (temporary / "DeskModel.swift").write_text(model)
        (temporary / "ModelFixtures.swift").write_text(HARNESS)
        executable = temporary / "model-fixtures"
        subprocess.run([
            "xcrun", "swiftc", "-parse-as-library",
            *(str(ROOT / name) for name in (
                "Inventory.swift", "LicenseState.swift", "ActivationWorkflow.swift", "SessionLifecycle.swift",
                "AutoScan.swift", "AutomaticScanner.swift")),
            str(temporary / "DeskModel.swift"), str(temporary / "ModelFixtures.swift"),
            "-o", str(executable),
        ], check=True, timeout=120)
        subprocess.run([str(executable), str(temporary)], check=True, timeout=45)


if __name__ == "__main__":
    main()
