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

    static func run() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try reportReaderFixtures(root)
        let support = root.appendingPathComponent("support")
        let a = try bundle(root, name: "BundleA", format: "VST3")
        let unknown = try bundle(root, name: "Unknown", format: "VST3")
        let au = try bundle(root, name: "BundleA_AU", format: "AU")
        try expect(!a.metadataStamp.isEmpty && a.architectures == ["arm64"], "real fixture binary stamp and architecture")

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
        let started = Date().addingTimeInterval(-0.5)
        let observed = Date().timeIntervalSince1970
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
