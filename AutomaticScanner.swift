// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Combine

struct ScanProduct: Equatable {
    let classID: String
    let name: String
}

/// Ephemeral first observation, solely for a bounded second-sample wait.
/// Never persist this type in LicenseStore or interpret it as a license verdict.
struct ScanCandidate: Equatable {
    let rule: String
    let observedAt: Date

    init?(rule: String, observedAt: Date) {
        let allowed: Set<String> = ["product_not_activated", "product_not_registered", "unlicensed_status",
                                    "license_expired", "trial_expired", "demo_mode", "no_valid_license"]
        guard allowed.contains(rule), observedAt.timeIntervalSince1970.isFinite,
              observedAt.timeIntervalSince1970 > 0 else { return nil }
        self.rule = rule
        self.observedAt = observedAt
    }
}

struct ScanObservation {
    var isRunning: Bool
    var state: String
    var classID: String
    var productName: String
    var classes: [ScanProduct]
    var startedAt: Date
    var readyAt: Date?
    var needsActivation: Bool
    var evidenceRule: String = ""
    var candidate: ScanCandidate? = nil
}

/// The runner owns only session UUIDs retained by DeskModel, never saved PIDs.
/// Each worker has an independent durable queue and at most one live host.
final class AutomaticScanner: ObservableObject {
    static let workerCount = 2
    static let startupLimit: TimeInterval = 25
    static let readyObservationTime: TimeInterval = 4
    static let candidateObservationGrace: TimeInterval = 2.5

    static func observationDeadline(readyAt: Date, startedAt: Date, candidate: ScanCandidate?, now: Date) -> Date {
        let baseline = readyAt.addingTimeInterval(readyObservationTime)
        var deadline = baseline
        if let candidate, candidate.observedAt >= startedAt, candidate.observedAt <= now {
            // Do not move the ready origin or accumulate time when a rule changes.
            // A vanished/stale candidate immediately restores the ordinary window.
            deadline = max(baseline, min(candidate.observedAt.addingTimeInterval(candidateObservationGrace),
                                         baseline.addingTimeInterval(candidateObservationGrace)))
        }
        return min(deadline, startedAt.addingTimeInterval(startupLimit))
    }

    @Published private(set) var runs: [AutoScanRun] = []
    @Published private(set) var error = ""
    @Published private(set) var isStopping = false
    @Published private(set) var message = ""

    var launch: (AutoScanTask) -> UUID? = { _ in nil }
    var stop: (UUID) -> Void = { _ in }
    var observe: (UUID) -> ScanObservation? = { _ in nil }
    var isKnown: (AutoScanTask) -> Bool = { _ in false }
    var storageIssue: () -> String = { "" }

    private final class Worker {
        let store: AutoScanStore
        var run: AutoScanRun?
        var sessionID: UUID?
        var readyAt: Date?
        var result: AutoScanOutcome?
        var reason = ""
        var metadataKey = ""
        init(store: AutoScanStore) { self.store = store; run = store.run }
    }
    private let directory: URL
    private let automaticallyTick: Bool
    private var workers: [Worker] = []
    private var timer: Timer?
    private var suspending = false
    private var shuttingDown = false
    private var processing = false
    private var memoryPressure: DispatchSourceMemoryPressure?

    var ownedSessionIDs: Set<UUID> { Set(workers.compactMap(\.sessionID)) }
    var hasActiveHosts: Bool { !ownedSessionIDs.isEmpty }
    var isRunning: Bool { !suspending && !shuttingDown && workers.contains { $0.run?.status == .running } }
    var isBusy: Bool { isRunning || hasActiveHosts || isStopping }
    var canResume: Bool { !isBusy && error.isEmpty && runs.contains { $0.status == .paused && !$0.pending.isEmpty } }
    var completedCount: Int { runs.reduce(0) { $0 + $1.completedCount } }
    var totalCount: Int { runs.reduce(0) { $0 + $1.totalCount } }
    var results: [AutoScanResult] { runs.flatMap(\.results) }
    var unactivatedCount: Int { results.filter { $0.outcome == .needsActivation }.count }
    var inconclusiveCount: Int { results.filter { [.inconclusive, .timedOut, .loadFailed, .changed].contains($0.outcome) }.count }
    var isComplete: Bool { !runs.isEmpty && runs.allSatisfy { $0.status == .complete } && !hasActiveHosts }
    var reportURL: URL { directory.appendingPathComponent("自動チェック結果.csv") }

    init(directory: URL, automaticallyTick: Bool = true) {
        self.directory = directory
        self.automaticallyTick = automaticallyTick
        loadStores()
        if automaticallyTick {
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
            source.setEventHandler { [weak self] in
                guard let self = self, self.isRunning else { return }
                self.pause(reason: "メモリ負荷が高くなったため、自動チェックを一時停止しました。")
            }
            source.resume()
            memoryPressure = source
        }
    }

    private func loadStores() {
        do {
            let loaded = try (0..<Self.workerCount).map {
                Worker(store: try AutoScanStore(directory: directory.appendingPathComponent("worker-\($0)")))
            }
            workers = loaded
            error = ""
            publish()
        } catch { self.error = "自動チェックの記録を読み込めません: " + error.localizedDescription }
    }

    func reload() {
        guard !hasActiveHosts, !isRunning else { return }
        loadStores()
        suspending = false
        isStopping = false
    }

    func start(tasks: [AutoScanTask]) {
        guard !isBusy, error.isEmpty, !tasks.isEmpty, workers.count == Self.workerCount else { return }
        shuttingDown = false
        suspending = false
        var seen = Set<String>()
        let unique = tasks.filter { seen.insert($0.id).inserted }
        for (index, worker) in workers.enumerated() {
            var run = AutoScanRun(tasks: unique.enumerated().filter { $0.offset % Self.workerCount == index }.map(\.element))
            run.resume()
            guard commit(run, worker: worker) else { return }
        }
        message = "自動チェック中。認証画面への入力や操作は行いません。"
        beginTimer()
        tick()
    }

    func resume() {
        guard canResume else { return }
        suspending = false
        shuttingDown = false
        for worker in workers {
            guard var run = worker.run else { continue }
            run.resume()
            guard commit(run, worker: worker) else { return }
        }
        message = "保存した続きから自動チェックを再開しています。"
        beginTimer()
        tick()
    }

    func pause(reason: String = "自動チェックを一時停止しました。続きから再開できます。") {
        guard isBusy else { return }
        suspending = true
        isStopping = hasActiveHosts
        message = reason
        for worker in workers {
            if let id = worker.sessionID { stop(id) }
        }
        tick()
    }

    /// Called before DeskModel closes all its retained children. The last
    /// checkpoint intentionally retains unfinished work for safe recovery.
    func shutdown() {
        shuttingDown = true
        suspending = true
        timer?.invalidate(); timer = nil
        memoryPressure?.cancel(); memoryPressure = nil
    }

    private func beginTimer() {
        guard automaticallyTick, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func publish() {
        let next = workers.compactMap(\.run)
        if next != runs { runs = next }
    }

    @discardableResult private func commit(_ run: AutoScanRun, worker: Worker) -> Bool {
        do {
            try worker.store.save(run)
            worker.run = run
            publish()
            return true
        } catch { fail("自動チェックの記録を保存できません: " + error.localizedDescription); return false }
    }

    private func fail(_ description: String) {
        if error.isEmpty { error = description }
        suspending = true
        isStopping = hasActiveHosts
        message = "記録を保護してチェックを停止しています。"
        for worker in workers { if let id = worker.sessionID { stop(id) } }
    }

    private func requestEnd(_ worker: Worker, outcome: AutoScanOutcome, reason: String) {
        guard worker.result == nil else { return }
        worker.result = outcome
        worker.reason = reason
        if let id = worker.sessionID { stop(id) }
    }

    func tick(now: Date = Date()) {
        guard !processing, !shuttingDown else { return }
        processing = true
        defer { processing = false }
        let issue = storageIssue()
        if !issue.isEmpty && isRunning { fail(issue) }
        for worker in workers {
            guard var run = worker.run else { continue }
            if let id = worker.sessionID {
                guard let observed = observe(id) else {
                    // Missing ownership evidence is not proof of exit. Never
                    // release this slot and accidentally create another host.
                    fail("チェック中のホストの状態を確認できません。アプリを再起動して保存した続きから再開してください。")
                    continue
                }
                if !suspending, let task = run.current, !observed.classID.isEmpty {
                    let key = observed.classID + "|" + observed.classes.map { $0.classID }.joined(separator: "|")
                    if worker.metadataKey != key {
                        let siblings = observed.classes.filter { $0.classID != observed.classID }.map {
                            AutoScanTask(entry: task.entry, classID: $0.classID, productName: $0.name)
                        }.filter { !isKnown($0) }
                        do {
                            try run.identifyCurrent(classID: observed.classID, productName: observed.productName, siblings: siblings)
                            guard commit(run, worker: worker) else { continue }
                            worker.metadataKey = key
                        } catch { fail("製品の識別情報が一致しません: " + error.localizedDescription); continue }
                    }
                }
                if suspending {
                    if observed.isRunning { continue }
                    // Do not mark paused items completed. Retry this item on
                    // resume, after the previous process is definitely gone.
                    run.pause()
                    worker.sessionID = nil
                    worker.result = nil
                    worker.readyAt = nil
                    worker.metadataKey = ""
                    if error.isEmpty { _ = commit(run, worker: worker) }
                    else { worker.run = run; publish() }
                    continue
                }
                if observed.needsActivation { requestEnd(worker, outcome: .needsActivation, reason: observed.evidenceRule) }
                if !observed.isRunning {
                    let outcome = observed.needsActivation ? AutoScanOutcome.needsActivation : worker.result
                        ?? (observed.state == "error" ? .loadFailed : .inconclusive)
                    let reason = observed.needsActivation ? observed.evidenceRule : worker.reason.isEmpty ? "host_exited_without_license_evidence" : worker.reason
                    do { try run.finishCurrent(outcome: outcome, reason: reason, checkedAt: now) }
                    catch { fail(error.localizedDescription); continue }
                    guard commit(run, worker: worker) else { continue }
                    worker.sessionID = nil
                    worker.result = nil
                    worker.readyAt = nil
                    worker.metadataKey = ""
                    continue
                }
                if worker.result != nil { continue } // Wait for actual exit.
                if observed.state == "error" { requestEnd(worker, outcome: .loadFailed, reason: "plugin_load_error"); continue }
                if let ready = observed.readyAt, worker.readyAt == nil { worker.readyAt = ready }
                if now.timeIntervalSince(observed.startedAt) >= Self.startupLimit {
                    requestEnd(worker, outcome: .timedOut, reason: "host_absolute_time_limit")
                } else if let ready = worker.readyAt {
                    let candidate = observed.classID.isEmpty ? nil : observed.candidate
                    let deadline = Self.observationDeadline(readyAt: ready, startedAt: observed.startedAt,
                                                            candidate: candidate, now: now)
                    if now >= deadline {
                        requestEnd(worker, outcome: .inconclusive, reason: "no_supported_explicit_license_status")
                    }
                }
            } else if suspending {
                if run.status == .running {
                    run.pause()
                    if error.isEmpty { _ = commit(run, worker: worker) }
                    else { worker.run = run; publish() }
                }
            } else if run.status == .running {
                // At most one item per worker per tick, including launch errors.
                guard let task = run.beginNext() else { _ = commit(run, worker: worker); continue }
                guard commit(run, worker: worker) else { continue }
                let stamp = Inventory.stamp(path: task.entry.path, info: Inventory.plist(task.entry.path + "/Contents/Info.plist"))
                let skip: AutoScanOutcome? = stamp != task.entry.metadataStamp ? .changed
                    : (!task.classID.isEmpty && isKnown(task)) ? .skipped : nil
                if let skip = skip {
                    do { try run.finishCurrent(outcome: skip, reason: skip == .changed ? "binary_changed" : "license_already_recorded", checkedAt: now) }
                    catch { fail(error.localizedDescription); continue }
                    _ = commit(run, worker: worker)
                    continue
                }
                if let id = launch(task) { worker.sessionID = id }
                else {
                    do { try run.finishCurrent(outcome: .loadFailed, reason: "host_launch_failed", checkedAt: now) }
                    catch { fail(error.localizedDescription); continue }
                    _ = commit(run, worker: worker)
                }
            }
        }
        if suspending && !hasActiveHosts {
            isStopping = false
            timer?.invalidate(); timer = nil
            writeReport()
        } else if isComplete {
            timer?.invalidate(); timer = nil
            message = "全対象の自動チェックが終了しました。未認証は専用一覧に表示しています。判定できなかった製品は結果に分けて記録しました。"
            writeReport()
        }
    }

    private static func csvField(_ value: String) -> String {
        // CSV quoting alone does not prevent a spreadsheet from interpreting
        // vendor-supplied metadata as a formula. Preserve the original text,
        // but prefix formula-like cells with an apostrophe before CSV escaping.
        let ignored = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        let normalized = value.precomposedStringWithCompatibilityMapping.unicodeScalars
        let first = normalized.first { !ignored.contains($0) }
        let formulaLike = first.map { "=+-@".unicodeScalars.contains($0) } ?? false
        let beginsWithLineControl = value.first.map { "\t\r\n".contains($0) } ?? false
        let safe = formulaLike || beginsWithLineControl ? "'" + value : value
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    func writeReport() {
        var lines = ["Product,Vendor,Format,Result,Reason,Path,ClassID"]
        for result in results.sorted(by: { $0.task.productName.localizedStandardCompare($1.task.productName) == .orderedAscending }) {
            let t = result.task
            lines.append([t.productName, t.entry.vendor, t.entry.format, result.outcome.title, result.reason, t.entry.path, t.classID].map(Self.csvField).joined(separator: ","))
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try ("\u{feff}" + lines.joined(separator: "\n") + "\n").write(to: reportURL, atomically: true, encoding: .utf8)
        } catch { message = "チェック記録は保存済みですが、CSVを書き出せません: " + error.localizedDescription }
    }
}
