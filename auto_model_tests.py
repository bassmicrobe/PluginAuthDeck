#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Deterministic integration fixtures for the actual automatic scan controller.

Only temporary fixture bundles and checkpoint files are created. All host
callbacks are in-memory fakes: no plug-in, GUI, audio, or child process starts.
"""
from pathlib import Path
import csv
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent

HARNESS = r'''
import Foundation
import Combine

enum Failure: Error { case check(String) }

final class Hosts {
    let directory: URL
    let base: Date
    var observations: [UUID: ScanObservation] = [:]
    var targets: [UUID: AutoScanTask] = [:]
    var launchOrder: [UUID] = []
    var stops: [UUID] = []
    var attempts = 0
    var maximumLive = 0
    var checkpointFailures = 0
    var failLaunch = false
    var issue = ""
    var knownClasses = Set<String>()

    init(directory: URL, base: Date) { self.directory = directory; self.base = base }

    func attach(_ scanner: AutomaticScanner) {
        scanner.launch = { [weak self, weak scanner] task in
            guard let self = self, let scanner = scanner else { return nil }
            self.attempts += 1
            // Verify the real controller durably checkpoints before its launch
            // callback. Read raw JSON because AutoScanStore safely recovers a
            // running checkpoint as paused when a new reader opens it.
            let saved = (0..<AutomaticScanner.workerCount).contains { worker in
                let file = scanner.checkpointDirectory.appendingPathComponent("worker-\(worker)/autoscan-state.json")
                guard let data = try? Data(contentsOf: file),
                      let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let run = doc["run"] as? [String: Any],
                      let current = run["current"] as? [String: Any],
                      let entry = current["entry"] as? [String: Any] else { return false }
                return run["status"] as? String == "running"
                    && entry["id"] as? String == task.entry.id
                    && entry["metadataStamp"] as? String == task.entry.metadataStamp
                    && current["classID"] as? String == task.classID
            }
            if !saved { self.checkpointFailures += 1 }
            if self.failLaunch { return nil }
            let id = UUID()
            self.targets[id] = task
            self.observations[id] = ScanObservation(isRunning: true, state: "loading",
                classID: task.classID, productName: task.productName, classes: [],
                startedAt: self.base, readyAt: nil, needsActivation: false)
            self.launchOrder.append(id)
            self.maximumLive = max(self.maximumLive, self.observations.values.filter(\.isRunning).count)
            return id
        }
        scanner.stop = { [weak self] id in self?.stops.append(id) }
        scanner.observe = { [weak self] id in self?.observations[id] }
        scanner.isKnown = { [weak self] task in self?.knownClasses.contains(task.classID) ?? false }
        scanner.storageIssue = { [weak self] in self?.issue ?? "" }
    }

    func ready(_ id: UUID, at: Date? = nil) {
        observations[id]?.state = "ready"
        observations[id]?.readyAt = at ?? base
    }
    func close(_ id: UUID, state: String = "closed") {
        observations[id]?.isRunning = false
        observations[id]?.state = state
    }
}

@main struct Fixtures {
    static var checks = 0
    static func expect(_ condition: @autoclosure () throws -> Bool, _ text: String) throws {
        checks += 1
        if try !condition() { throw Failure.check(text) }
    }

    static func entry(_ root: URL, _ index: Int) throws -> Entry {
        let path = root.appendingPathComponent("Fixture\(index).vst3")
        let binary = path.appendingPathComponent("Contents/MacOS/Fixture")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1] + Array(repeating: 0, count: 24)).write(to: binary)
        let info: [String: Any] = ["CFBundleExecutable": "Fixture", "CFBundleIdentifier": "fixture.\(index)",
            "CFBundleShortVersionString": "1.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: path.appendingPathComponent("Contents/Info.plist"))
        return Entry(id: "fixture:\(index)", name: "Fixture \(index)", vendor: "Fixture Vendor", format: "VST3",
            path: path.path, identifier: path.path, version: "1.0", architectures: ["arm64"],
            metadataStamp: Inventory.stamp(path: path.path, info: info))
    }

    static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }

    static func run() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        if let mode = CommandLine.arguments.dropFirst(2).first, mode.hasPrefix("--nonregular-") {
            let scanner = AutomaticScanner(directory: root, automaticallyTick: false)
            if mode.hasSuffix("-lock") {
                scanner.start(tasks: [AutoScanTask(entry: try entry(root, 999))])
            }
            try expect(!scanner.error.isEmpty && scanner.runs.isEmpty && !scanner.canResume,
                "nonregular state or lock fails promptly without creating a replacement run")
            print("PASS: \(mode) rejected without blocking")
            return
        }
        let entries = try (0..<8).map { try entry(root, $0) }
        let tasks = entries.map { AutoScanTask(entry: $0) }
        let base = Date()

        // Ready -> observation window -> stop request -> confirmed exit. An
        // exit is the only event that releases a worker slot.
        let directory = root.appendingPathComponent("sequential")
        let scanner = AutomaticScanner(directory: directory, automaticallyTick: false)
        let hosts = Hosts(directory: directory, base: base)
        hosts.attach(scanner)
        scanner.start(tasks: Array(tasks.prefix(4)))
        try expect(hosts.launchOrder.count == 2 && scanner.ownedSessionIDs.count == 2, "two bounded worker launches")
        try expect(hosts.checkpointFailures == 0, "checkpoint saved before every launch")
        let first = hosts.launchOrder
        first.forEach { hosts.ready($0) }
        scanner.tick(now: base.addingTimeInterval(3.9))
        try expect(hosts.stops.isEmpty, "ready observation does not end before four seconds")
        scanner.tick(now: base.addingTimeInterval(4))
        try expect(Set(hosts.stops) == Set(first) && scanner.completedCount == 0, "four seconds requests stop without declaring completion")
        scanner.tick(now: base.addingTimeInterval(100))
        try expect(hosts.launchOrder.count == 2 && hosts.stops.count == 2, "unresponsive teardown neither relaunches nor repeats stop")
        hosts.close(first[0])
        scanner.tick(now: base.addingTimeInterval(101))
        try expect(scanner.completedCount == 1 && hosts.launchOrder.count == 2, "exit commits one result without same-tick recursion")
        scanner.tick(now: base.addingTimeInterval(102))
        try expect(hosts.launchOrder.count == 3 && hosts.maximumLive == 2, "other worker progresses while one teardown remains blocked")
        hosts.close(first[1])
        scanner.tick(now: base.addingTimeInterval(103))
        scanner.tick(now: base.addingTimeInterval(104))
        try expect(hosts.launchOrder.count == 4 && scanner.completedCount == 2, "both slots independently reuse only after exit")
        try expect(scanner.unactivatedCount == 0 && scanner.inconclusiveCount == 2, "ready alone yields inconclusive, never a license verdict")

        scanner.pause()
        let beforeResume = hosts.launchOrder.count
        try expect(scanner.isStopping && !scanner.canResume, "pause waits for owned hosts")
        scanner.resume()
        try expect(hosts.launchOrder.count == beforeResume, "immediate resume cannot race host shutdown")
        hosts.launchOrder.suffix(2).forEach { hosts.close($0) }
        scanner.tick(now: base.addingTimeInterval(105))
        try expect(scanner.canResume && !scanner.isBusy && scanner.completedCount == 2, "pause requeues unfinished work after confirmed exit")
        try expect(scanner.runs.allSatisfy { $0.status == .paused && $0.current == nil }, "paused checkpoint contains no live ownership")
        scanner.shutdown()

        let restored = AutomaticScanner(directory: directory, automaticallyTick: false)
        let restoredHosts = Hosts(directory: directory, base: base)
        restoredHosts.attach(restored)
        try expect(restored.canResume && restoredHosts.attempts == 0 && restored.completedCount == 2,
            "restart preserves results and never opens hosts until explicit resume")
        restored.resume()
        try expect(restoredHosts.launchOrder.count == 2 && restoredHosts.checkpointFailures == 0, "explicit resume checkpoints and restarts unfinished items")
        let ids = restoredHosts.launchOrder
        restoredHosts.observations[ids[0]]?.classID = "detected-class"
        restoredHosts.observations[ids[0]]?.needsActivation = true
        restoredHosts.observations[ids[0]]?.evidenceRule = "fixture_stable_explicit_status"
        restored.tick(now: base.addingTimeInterval(1))
        try expect(restoredHosts.stops.contains(ids[0]) && restored.completedCount == 2, "explicit evidence requests stop but still waits for exit")
        restoredHosts.close(ids[0])
        restoredHosts.close(ids[1], state: "error")
        restored.tick(now: base.addingTimeInterval(2))
        try expect(restored.isComplete && restored.completedCount == 4 && restored.unactivatedCount == 1,
            "closed detected product and failed product finish independently")
        try expect(restored.results.contains { $0.outcome == .loadFailed }, "load failure stays distinct from licensing")
        try expect(FileManager.default.fileExists(atPath: restored.reportURL.path), "completion writes report in injected directory")

        // Absolute startup deadline applies even without ready and even when
        // the host keeps presenting a modal/license dialog.
        let timeoutDir = root.appendingPathComponent("timeout")
        let timed = AutomaticScanner(directory: timeoutDir, automaticallyTick: false)
        let timedHosts = Hosts(directory: timeoutDir, base: base)
        timedHosts.attach(timed)
        timed.start(tasks: Array(tasks.prefix(2)))
        timed.tick(now: base.addingTimeInterval(24.9))
        try expect(timedHosts.stops.isEmpty, "startup allowed before deadline")
        timed.tick(now: base.addingTimeInterval(25))
        try expect(timedHosts.stops.count == 2 && timed.completedCount == 0, "absolute 25 second deadline stops both stalled hosts")
        timedHosts.launchOrder.forEach { timedHosts.close($0) }
        timed.tick(now: base.addingTimeInterval(26))
        try expect(timed.isComplete && timed.results.allSatisfy { $0.outcome == .timedOut }, "timeout results require real exit")

        // A late first label can wait for the next sample, but is never a verdict.
        let lateDir = root.appendingPathComponent("late-candidate")
        let late = AutomaticScanner(directory: lateDir, automaticallyTick: false)
        let lateHosts = Hosts(directory: lateDir, base: base)
        lateHosts.attach(late)
        late.start(tasks: Array(tasks.prefix(2)))
        let lateIDs = lateHosts.launchOrder
        for (index, id) in lateIDs.enumerated() {
            lateHosts.ready(id)
            lateHosts.observations[id]?.classID = "late-\(index)"
            lateHosts.observations[id]?.candidate = ScanCandidate(rule: "license_expired",
                observedAt: base.addingTimeInterval(index == 0 ? 3.5 : 3.99))
        }
        late.tick(now: base.addingTimeInterval(4))
        late.tick(now: base.addingTimeInterval(5))
        try expect(lateHosts.stops.isEmpty && late.unactivatedCount == 0 && late.completedCount == 0,
            "late first candidates extend observation but never create a license verdict")
        lateHosts.observations[lateIDs[0]]?.needsActivation = true
        lateHosts.observations[lateIDs[0]]?.evidenceRule = "license_expired"
        late.tick(now: base.addingTimeInterval(5.5))
        try expect(lateHosts.stops == [lateIDs[0]], "confirmed second sample can finish during candidate grace")
        lateHosts.observations[lateIDs[1]]?.candidate = nil
        late.tick(now: base.addingTimeInterval(5.5))
        try expect(Set(lateHosts.stops) == Set(lateIDs), "candidate disappearance restores the ordinary elapsed deadline")
        lateIDs.forEach { lateHosts.close($0) }
        late.tick(now: base.addingTimeInterval(6))
        try expect(late.isComplete && late.unactivatedCount == 1 && late.inconclusiveCount == 1,
            "only confirmed evidence is retained; withdrawn candidate remains inconclusive")
        try expect(late.results.filter { $0.outcome == .inconclusive }.allSatisfy { $0.reason != "license_expired" },
            "candidate rule is not persisted as a completed licensing reason")

        // Changing/repeated candidates cannot slide the fixed ready + 6.5 cap.
        let capDir = root.appendingPathComponent("candidate-cap")
        let cap = AutomaticScanner(directory: capDir, automaticallyTick: false)
        let capHosts = Hosts(directory: capDir, base: base)
        capHosts.attach(cap)
        cap.start(tasks: Array(tasks.prefix(2)))
        for (index, id) in capHosts.launchOrder.enumerated() {
            capHosts.ready(id)
            capHosts.observations[id]?.classID = "cap-\(index)"
            capHosts.observations[id]?.candidate = ScanCandidate(rule: "license_expired", observedAt: base.addingTimeInterval(3.8))
        }
        cap.tick(now: base.addingTimeInterval(4))
        for id in capHosts.launchOrder {
            capHosts.observations[id]?.candidate = ScanCandidate(rule: "demo_mode", observedAt: base.addingTimeInterval(5.9))
            capHosts.observations[id]?.readyAt = base.addingTimeInterval(30)
        }
        cap.tick(now: base.addingTimeInterval(6.49))
        try expect(capHosts.stops.isEmpty, "replaced candidate can use remaining fixed grace")
        cap.tick(now: base.addingTimeInterval(6.5))
        try expect(capHosts.stops.count == 2 && cap.unactivatedCount == 0,
            "candidate changes and repeated ready reports cannot extend ready plus 6.5 seconds")
        capHosts.launchOrder.forEach { capHosts.close($0) }
        cap.tick(now: base.addingTimeInterval(7))
        try expect(cap.results.allSatisfy { $0.outcome == .inconclusive }, "unconfirmed candidates expire as inconclusive")

        let absoluteDir = root.appendingPathComponent("candidate-absolute-cap")
        let absolute = AutomaticScanner(directory: absoluteDir, automaticallyTick: false)
        let absoluteHosts = Hosts(directory: absoluteDir, base: base)
        absoluteHosts.attach(absolute)
        absolute.start(tasks: Array(tasks.prefix(2)))
        for (index, id) in absoluteHosts.launchOrder.enumerated() {
            absoluteHosts.ready(id, at: base.addingTimeInterval(22))
            absoluteHosts.observations[id]?.classID = "absolute-\(index)"
            absoluteHosts.observations[id]?.candidate = ScanCandidate(rule: "demo_mode", observedAt: base.addingTimeInterval(24.5))
        }
        absolute.tick(now: base.addingTimeInterval(24.9))
        try expect(absoluteHosts.stops.isEmpty, "late-ready candidate can observe only until absolute cap")
        absolute.tick(now: base.addingTimeInterval(25))
        try expect(absoluteHosts.stops.count == 2, "candidate grace cannot extend the absolute 25 second limit")
        absoluteHosts.launchOrder.forEach { absoluteHosts.close($0) }
        absolute.tick(now: base.addingTimeInterval(26))
        try expect(absolute.results.allSatisfy { $0.outcome == .timedOut }, "absolute candidate cap is recorded as timeout")

        try expect(ScanCandidate(rule: "arbitrary UI text", observedAt: base) == nil, "candidate rejects unknown rules")
        try expect(ScanCandidate(rule: "license_expired", observedAt: Date(timeIntervalSince1970: .nan)) == nil,
            "candidate rejects non-finite timestamp")
        try expect(ScanCandidate(rule: "license_expired", observedAt: Date(timeIntervalSince1970: 0)) == nil,
            "candidate rejects invalid epoch")
        for time in [-1.0, 0.0, 1.0, 7.0] {
            let candidate = ScanCandidate(rule: "license_expired", observedAt: base.addingTimeInterval(time))
            let deadline = AutomaticScanner.observationDeadline(readyAt: base, startedAt: base,
                candidate: candidate, now: base.addingTimeInterval(4))
            try expect(deadline == base.addingTimeInterval(4), "old, early, or future candidates do not extend observation")
        }
        let unidentifiedDir = root.appendingPathComponent("unidentified-candidate")
        let unidentified = AutomaticScanner(directory: unidentifiedDir, automaticallyTick: false)
        let unidentifiedHosts = Hosts(directory: unidentifiedDir, base: base)
        unidentifiedHosts.attach(unidentified)
        unidentified.start(tasks: Array(tasks.prefix(2)))
        for id in unidentifiedHosts.launchOrder {
            unidentifiedHosts.ready(id)
            unidentifiedHosts.observations[id]?.candidate = ScanCandidate(rule: "license_expired", observedAt: base.addingTimeInterval(3.5))
        }
        unidentified.tick(now: base.addingTimeInterval(4))
        try expect(unidentifiedHosts.stops.count == 2, "candidate without selected class cannot extend the deadline")
        for controller in [late, cap, absolute, unidentified] { controller.shutdown() }

        // Save failures stop every owned host, keep unfinished checkpoints,
        // and require an explicit reload before allowing resume.
        let conflictDir = root.appendingPathComponent("license-conflict")
        let conflict = AutomaticScanner(directory: conflictDir, automaticallyTick: false)
        let conflictHosts = Hosts(directory: conflictDir, base: base)
        conflictHosts.attach(conflict)
        conflict.start(tasks: Array(tasks.prefix(2)))
        conflictHosts.issue = "fixture license ledger conflict"
        conflict.tick(now: base)
        try expect(!conflict.error.isEmpty && conflictHosts.stops.count == 2, "license storage failure stops both workers")
        conflictHosts.launchOrder.forEach { conflictHosts.close($0) }
        conflict.tick(now: base)
        try expect(conflict.completedCount == 0 && !conflict.canResume && !conflict.hasActiveHosts,
            "failed storage never manufactures completion or resumes silently")
        conflictHosts.issue = ""
        conflict.reload()
        try expect(conflict.canResume && conflict.runs.allSatisfy { $0.pending.count == 1 }, "reload recovers interrupted durable targets")

        // Own queue-file conflicts receive the same protection as license-file
        // conflicts; externally modified bytes must remain untouched.
        let queueDir = root.appendingPathComponent("queue-conflict")
        let queue = AutomaticScanner(directory: queueDir, automaticallyTick: false)
        let queueHosts = Hosts(directory: queueDir, base: base)
        queueHosts.attach(queue)
        queue.start(tasks: Array(tasks.prefix(2)))
        let checkpoint = queue.checkpointDirectory.appendingPathComponent("worker-0/autoscan-state.json")
        var altered = try Data(contentsOf: checkpoint)
        altered.append(Data("\n".utf8))
        try altered.write(to: checkpoint)
        let qid = queueHosts.launchOrder[0]
        queueHosts.observations[qid]?.classID = "new-class"
        queue.tick(now: base)
        try expect(!queue.error.isEmpty && Set(queueHosts.stops) == Set(queueHosts.launchOrder), "queue checkpoint conflict stops every owned host")
        try expect(try Data(contentsOf: checkpoint) == altered, "external checkpoint bytes preserved on conflict")

        // Starting a scan replaces both workers together. A second-worker
        // conflict must preserve every previous result and never launch a host.
        let atomicDir = root.appendingPathComponent("atomic-start")
        let atomic = AutomaticScanner(directory: atomicDir, automaticallyTick: false)
        let atomicHosts = Hosts(directory: atomicDir, base: base)
        atomicHosts.failLaunch = true
        atomicHosts.attach(atomic)
        atomic.start(tasks: Array(tasks.prefix(2)))
        let previousResults = atomic.results
        let previousDirectory = atomic.checkpointDirectory
        let previousManifest = try Data(contentsOf: atomicDir.appendingPathComponent("current-run.json"))
        let secondWorker = previousDirectory.appendingPathComponent("worker-1/autoscan-state.json")
        let modifiedSecondWorker = try Data(contentsOf: secondWorker) + Data("\n".utf8)
        try modifiedSecondWorker.write(to: secondWorker)
        let previousAttempts = atomicHosts.attempts
        atomic.start(tasks: Array(tasks.suffix(2)))
        try expect(!atomic.error.isEmpty && atomicHosts.attempts == previousAttempts,
            "second-worker conflict prevents every new launch")
        try expect(atomic.results == previousResults && atomic.checkpointDirectory == previousDirectory,
            "failed start leaves all old workers and in-memory results intact")
        try expect(try Data(contentsOf: atomicDir.appendingPathComponent("current-run.json")) == previousManifest,
            "failed start does not switch the active run manifest")
        atomic.reload()
        try expect(atomic.results == previousResults && atomic.isComplete && !atomic.canResume,
            "reload after failed start never combines old results with a new queue")
        atomic.start(tasks: Array(tasks.suffix(2)))
        try expect(atomic.isComplete && atomic.results.map(\.id) == tasks.suffix(2).map(\.id)
            && atomic.checkpointDirectory != previousDirectory, "retry publishes a complete new generation")
        try expect(try Data(contentsOf: secondWorker) == modifiedSecondWorker,
            "successful replacement retains previous generation for recovery")

        // The second worker exceeds the durable size limit after the first
        // worker is staged: failure still cannot publish a partial generation.
        let workspace = try AutoScanWorkspace(directory: atomicDir)
        let priorStores = try workspace.stores(count: AutomaticScanner.workerCount)
        let beforeOversized = try Data(contentsOf: atomicDir.appendingPathComponent("current-run.json"))
        let beforeDirectories = try FileManager.default.contentsOfDirectory(atPath: atomicDir.appendingPathComponent("runs").path)
        var oversized = AutoScanRun(tasks: [tasks[0]])
        oversized.resume(); _ = oversized.beginNext()
        try oversized.finishCurrent(outcome: .inconclusive, reason: String(repeating: "x", count: 16 * 1024 * 1024))
        var rejectedOversized = false
        do { _ = try workspace.replace(with: [AutoScanRun(tasks: [tasks[1]]), oversized], previous: priorStores) }
        catch { rejectedOversized = true }
        try expect(rejectedOversized, "second staged checkpoint rejects oversized data")
        try expect(try Data(contentsOf: atomicDir.appendingPathComponent("current-run.json")) == beforeOversized,
            "second staged write failure leaves the active manifest unchanged")
        try expect(try Set(FileManager.default.contentsOfDirectory(atPath: atomicDir.appendingPathComponent("runs").path)) == Set(beforeDirectories),
            "failed unpublished generation is removed without touching previous generations")

        // An old controller cannot overwrite a newly published generation.
        let competing = AutomaticScanner(directory: atomicDir, automaticallyTick: false)
        let competingHosts = Hosts(directory: atomicDir, base: base)
        competingHosts.failLaunch = true
        competingHosts.attach(competing)
        atomic.start(tasks: Array(tasks.prefix(2)))
        let latestManifest = try Data(contentsOf: atomicDir.appendingPathComponent("current-run.json"))
        competing.start(tasks: Array(tasks.suffix(2)))
        try expect(!competing.error.isEmpty && competingHosts.attempts == 0,
            "stale manifest prevents another controller replacing the current run")
        try expect(try Data(contentsOf: atomicDir.appendingPathComponent("current-run.json")) == latestManifest,
            "manifest conflict preserves the newer run")

        let legacyDir = root.appendingPathComponent("legacy-migration")
        for index in 0..<AutomaticScanner.workerCount {
            var legacyRun = AutoScanRun(tasks: [tasks[index]])
            legacyRun.resume(); _ = legacyRun.beginNext()
            try legacyRun.finishCurrent(outcome: .inconclusive, reason: "legacy-fixture")
            try AutoScanStore(directory: legacyDir.appendingPathComponent("worker-\(index)")).save(legacyRun)
        }
        let legacyFile = legacyDir.appendingPathComponent("worker-0/autoscan-state.json")
        let legacyBytes = try Data(contentsOf: legacyFile)
        let legacy = AutomaticScanner(directory: legacyDir, automaticallyTick: false)
        try expect(legacy.completedCount == 2 && legacy.isComplete && legacy.checkpointDirectory == legacyDir,
            "old worker directories load without a manifest")
        let legacyHosts = Hosts(directory: legacyDir, base: base)
        legacyHosts.failLaunch = true
        legacyHosts.attach(legacy)
        legacy.start(tasks: Array(tasks.suffix(2)))
        try expect(legacy.isComplete && legacy.checkpointDirectory != legacyDir,
            "starting from legacy storage publishes the new complete generation")
        try expect(try Data(contentsOf: legacyFile) == legacyBytes, "migration preserves all legacy checkpoint bytes")
        let migrated = AutomaticScanner(directory: legacyDir, automaticallyTick: false)
        try expect(migrated.results == legacy.results && migrated.isComplete,
            "reload follows the new manifest instead of stale legacy checkpoints")

        for (name, document) in [
            ("broken", Data("{broken".utf8)),
            ("unknown", Data("{\"version\":2,\"directory\":\"\(UUID().uuidString)\"}".utf8)),
            ("escape", Data("{\"version\":1,\"directory\":\"../../outside\"}".utf8)),
            ("missing", Data("{\"version\":1,\"directory\":\"\(UUID().uuidString)\"}".utf8))
        ] {
            let invalidDir = root.appendingPathComponent("manifest-" + name)
            try FileManager.default.createDirectory(at: invalidDir, withIntermediateDirectories: true)
            let manifest = invalidDir.appendingPathComponent("current-run.json")
            try document.write(to: manifest)
            let invalid = AutomaticScanner(directory: invalidDir, automaticallyTick: false)
            invalid.start(tasks: Array(tasks.prefix(2)))
            try expect(!invalid.error.isEmpty && invalid.runs.isEmpty && !invalid.canResume,
                "invalid or incomplete manifest is rejected: " + name)
            try expect(try Data(contentsOf: manifest) == document, "invalid manifest is never overwritten: " + name)
        }

        // Product metadata expands siblings exactly once, with known siblings
        // excluded and repeated polls producing no redundant @Published run.
        let classDir = root.appendingPathComponent("classes")
        let classes = AutomaticScanner(directory: classDir, automaticallyTick: false)
        let classHosts = Hosts(directory: classDir, base: base)
        classHosts.knownClasses = ["class-C"]
        classHosts.attach(classes)
        classes.start(tasks: Array(tasks.prefix(2)))
        let cid = classHosts.launchOrder[0]
        classHosts.observations[cid]?.classID = "class-A"
        classHosts.observations[cid]?.classes = [ScanProduct(classID: "class-A", name: "A"),
            ScanProduct(classID: "class-B", name: "B"), ScanProduct(classID: "class-B", name: "B"),
            ScanProduct(classID: "class-C", name: "C")]
        var publications = 0
        let subscription = classes.$runs.dropFirst().sink { _ in publications += 1 }
        classes.tick(now: base)
        try expect(classes.totalCount == 3 && classes.runs[0].current?.classID == "class-A", "exact product identity plus one unknown sibling added")
        classes.tick(now: base)
        classes.tick(now: base)
        try expect(publications == 1 && classes.totalCount == 3, "same class report is neither resaved nor republished")
        subscription.cancel()
        classHosts.observations[cid]?.classID = "wrong-class"
        classes.tick(now: base)
        try expect(!classes.error.isEmpty && classes.completedCount == 0, "changed class identity stops scan rather than misapplying result")

        let missingDir = root.appendingPathComponent("missing-ownership")
        let missing = AutomaticScanner(directory: missingDir, automaticallyTick: false)
        let missingHosts = Hosts(directory: missingDir, base: base)
        missingHosts.attach(missing)
        missing.start(tasks: Array(tasks.prefix(4)))
        missingHosts.observations.removeValue(forKey: missingHosts.launchOrder[0])
        missing.tick(now: base)
        missing.tick(now: base.addingTimeInterval(40))
        try expect(!missing.error.isEmpty && missingHosts.launchOrder.count == 2 && missing.hasActiveHosts,
            "missing ownership evidence cannot release a live slot")

        let failuresDir = root.appendingPathComponent("launch-failures")
        let failures = AutomaticScanner(directory: failuresDir, automaticallyTick: false)
        let failedHosts = Hosts(directory: failuresDir, base: base)
        failedHosts.failLaunch = true
        failedHosts.attach(failures)
        failures.start(tasks: tasks)
        try expect(failedHosts.attempts == 2 && failures.completedCount == 2, "launch failures are bounded to one item per worker per tick")
        failures.tick(now: base)
        try expect(failedHosts.attempts == 4 && failures.completedCount == 4, "failed queue continues without synchronous recursion")
        try expect(failedHosts.checkpointFailures == 0, "failed launch still had durable checkpoint")

        // Verify live file identity again before any automatic launch.
        let changedDir = root.appendingPathComponent("binary-changed")
        let changed = AutomaticScanner(directory: changedDir, automaticallyTick: false)
        let changedHosts = Hosts(directory: changedDir, base: base)
        changedHosts.attach(changed)
        let binary = URL(fileURLWithPath: entries[0].path).appendingPathComponent("Contents/MacOS/Fixture")
        try Data([1, 2, 3]).write(to: binary)
        changed.start(tasks: Array(tasks.prefix(2)))
        try expect(changed.results.first?.outcome == .changed && changedHosts.launchOrder.count == 1,
            "changed binary skipped before host launch")

        // Export synthetic vendor metadata through the real persistence/report
        // path. Python's CSV parser checks cells after this harness completes.
        let csvDir = root.appendingPathComponent("csv-cells")
        let csvValues = ["Ordinary, \"quoted\"\n音色", "=1+1", "+SUM(1,2)", "-1+2", "@SUM(1,2)",
                         " \t=1+1", "\n=1+1", "\r=1+1", "\tplain", "＝1+1", "\u{feff}=1+1", "'=literal"]
        let csvTasks = try csvValues.enumerated().map { index, value -> AutoScanTask in
            var item = try entry(root, 100 + index)
            item.vendor = value
            return AutoScanTask(entry: item, classID: value, productName: value)
        }
        var csvRun = AutoScanRun(tasks: csvTasks)
        csvRun.resume()
        while let task = csvRun.beginNext() {
            try csvRun.finishCurrent(outcome: .inconclusive, reason: task.productName, checkedAt: base)
        }
        try AutoScanStore(directory: csvDir.appendingPathComponent("worker-0")).save(csvRun)
        let csvScanner = AutomaticScanner(directory: csvDir, automaticallyTick: false)
        try expect(csvScanner.writeReport(), "successful CSV export confirms the file can be opened")
        try expect(csvScanner.isComplete && csvScanner.results.count == csvValues.count,
            "CSV fixture exports actual stored results without opening any plugins")
        let priorReport = try Data(contentsOf: csvScanner.reportURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: csvDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: csvDir.path) }
        try expect(!csvScanner.writeReport(), "CSV write failure tells the caller not to open a stale report")
        try expect(csvScanner.message.contains("CSVを書き出せません"), "CSV write failure remains visible to the user")
        try expect(try Data(contentsOf: csvScanner.reportURL) == priorReport,
            "failed atomic CSV replacement preserves the previous report")

        for controller in [restored, timed, conflict, queue, atomic, competing, legacy, migrated, classes, missing, failures, changed] { controller.shutdown() }
        print("PASS: \(checks) AutomaticScanner integration checks (durability, max-two, exits, deadlines, pause/resume, conflicts, classes)")
    }
}
'''


def main():
    with tempfile.TemporaryDirectory(prefix="plugin-auth-auto-model-tests-") as directory:
        directory = Path(directory)
        harness = directory / "AutomaticFixtures.swift"
        harness.write_text(HARNESS)
        binary = directory / "automatic-fixtures"
        subprocess.run([
            "xcrun", "swiftc", "-parse-as-library",
            *(str(ROOT / name) for name in ("Inventory.swift", "AutoScan.swift", "AutomaticScanner.swift")),
            str(harness), "-o", str(binary),
        ], check=True, timeout=120)
        for mode, name in [("checkpoint", "worker-0/autoscan-state.json"),
                           ("lock", "worker-0/.autoscan-state.lock"),
                           ("manifest", "current-run.json"), ("run-lock", ".autoscan-run.lock")]:
            fifo_root = directory / f"fifo-{mode}"
            fifo = fifo_root / name
            fifo.parent.mkdir(parents=True)
            os.mkfifo(fifo)
            subprocess.run([str(binary), str(fifo_root), f"--nonregular-{mode}"], check=True, timeout=2)
            assert fifo.is_fifo(), "rejected state and lock must remain untouched"
        subprocess.run([str(binary), str(directory)], check=True, timeout=30)
        with (directory / "csv-cells" / "自動チェック結果.csv").open(encoding="utf-8-sig", newline="") as stream:
            rows = list(csv.reader(stream))
        originals = ['Ordinary, "quoted"\n音色', '=1+1', '+SUM(1,2)', '-1+2', '@SUM(1,2)',
                     ' \t=1+1', '\n=1+1', '\r=1+1', '\tplain', '＝1+1', '\ufeff=1+1', "'=literal"]
        expected = {value if i in (0, len(originals) - 1) else "'" + value for i, value in enumerate(originals)}
        assert rows[0] == ['Product', 'Vendor', 'Format', 'Result', 'Reason', 'Path', 'ClassID']
        assert len(rows) == len(originals) + 1
        assert {row[0] for row in rows[1:]} == expected
        for row in rows[1:]:
            assert len(row) == 7, "quotes, commas, CR and LF must stay inside their cells"
            assert row[0] == row[1] == row[4] == row[6], "all vendor-controlled fields use safe CSV encoding"
            assert row[2] == 'VST3' and row[5].startswith(str(directory)), "ordinary fields preserve their content"
        print(f"PASS: {len(originals)} CSV export cases (formula prefixes, controls, Unicode, quoting, ordinary text)")


if __name__ == "__main__":
    main()
