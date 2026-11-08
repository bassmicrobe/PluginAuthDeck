// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Darwin

// Checkpoints use Unix seconds. Canonicalize at creation so conversion between
// Foundation's 2001 epoch and the JSON epoch does not introduce a one-ULP change
// on reload and make an otherwise identical durable state compare differently.
private func canonicalScanDate(_ date: Date = Date()) -> Date {
    Date(timeIntervalSince1970: date.timeIntervalSince1970)
}

struct AutoScanTask: Codable, Identifiable, Equatable {
    var entry: Entry
    var classID: String
    var productName: String
    // Missing in v1.3.3 checkpoints. Keep the first failed attempt with this
    // exact product while counting only the final result as a completed item.
    var previousAttempts: [AutoScanAttempt]?

    var isRetry: Bool { !(previousAttempts ?? []).isEmpty }
    var launchBudgetSeconds: TimeInterval { isRetry ? 60 : 25 }

    var id: String {
        [entry.id, entry.metadataStamp, classID].map { "\($0.utf8.count):\($0)" }.joined()
    }

    init(entry: Entry, classID: String = "", productName: String? = nil,
         previousAttempts: [AutoScanAttempt]? = nil) {
        self.entry = entry
        self.classID = classID
        self.productName = productName ?? entry.name
        self.previousAttempts = previousAttempts
    }

    fileprivate var isValid: Bool {
        !entry.id.isEmpty && !entry.path.isEmpty && ["VST3", "AU"].contains(entry.format)
            && !productName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (previousAttempts ?? []).count <= 1
            && (previousAttempts ?? []).allSatisfy(\.isValid)
    }
}

enum AutoScanOutcome: String, Codable, CaseIterable {
    case needsActivation, noActivationDetected, inconclusive, loadFailed, timedOut, changed, skipped

    var title: String {
        switch self {
        case .needsActivation: return "未認証"
        case .noActivationDetected: return "未認証表示なし"
        case .inconclusive: return "未判定"
        case .loadFailed: return "読み込み失敗"
        case .timedOut: return "時間切れ"
        case .changed: return "変更あり"
        case .skipped: return "スキップ"
        }
    }
}

/// Bounded operational evidence only. These counters distinguish an inspected
/// editor from a missing/unfinished capture, without retaining any UI content.
/// A negative display check never asserts that a product is licensed.
struct AutoScanDiagnostics: Codable, Equatable {
    var phase: String = ""
    var probeDiagnostic: String = ""
    var staticTextNodes: Int = 0
    var maskedRegions: Int = 0
    var completedInspectionCount: Int = 0
    var textInspectionCount: Int = 0

    var hasInspectedDisplay: Bool {
        completedInspectionCount >= 2 && textInspectionCount >= 2
    }

    fileprivate var isValid: Bool {
        func code(_ value: String) -> Bool {
            value.utf8.count <= 128 && value.utf8.allSatisfy {
                (97...122).contains($0) || (48...57).contains($0) || $0 == 95
            }
        }
        return code(phase) && code(probeDiagnostic)
            && (0...4096).contains(staticTextNodes) && (0...4096).contains(maskedRegions)
            && (0...100_000).contains(completedInspectionCount)
            && (0...completedInspectionCount).contains(textInspectionCount)
    }
}

struct AutoScanAttempt: Codable, Equatable {
    var outcome: AutoScanOutcome
    var reason: String
    var checkedAt: Date
    var diagnostics: AutoScanDiagnostics? = nil

    fileprivate var isValid: Bool {
        [.loadFailed, .timedOut].contains(outcome) && checkedAt.timeIntervalSince1970.isFinite
            && !reason.isEmpty && reason.utf8.count <= 128
            && reason.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
            && (diagnostics?.isValid ?? true)
    }
}

struct AutoScanResult: Codable, Identifiable, Equatable {
    var task: AutoScanTask
    var outcome: AutoScanOutcome
    // A detection rule identifier or a short diagnostic code, never a license
    // key, screenshot, or the complete text scraped from a plug-in window.
    var reason: String
    var checkedAt: Date
    var diagnostics: AutoScanDiagnostics?

    var id: String { task.id }

    init(task: AutoScanTask, outcome: AutoScanOutcome, reason: String, checkedAt: Date = Date(),
         diagnostics: AutoScanDiagnostics? = nil) {
        self.task = task
        self.outcome = outcome
        self.reason = reason
        self.checkedAt = canonicalScanDate(checkedAt)
        self.diagnostics = diagnostics
    }
}

enum AutoScanStatus: String, Codable {
    case running, paused, complete
}

enum AutoScanError: LocalizedError {
    case noCurrentTask
    case wrongClass
    case wrongSource
    case alreadyCompleted
    case invalidState
    case unreadable(String)
    case corrupt(String)
    case unsupportedVersion(Int)
    case changedOnDisk
    case cannotSave(String)
    case busy

    var errorDescription: String? {
        switch self {
        case .noCurrentTask: return "現在確認中のプラグインがありません。"
        case .wrongClass: return "要求したものと異なるプラグインが開いたため、確認結果を記録しませんでした。"
        case .wrongSource: return "プラグインの場所または版が変わったため、確認対象を追加できませんでした。"
        case .alreadyCompleted: return "そのプラグインはこの実行ですでに確認済みです。"
        case .invalidState: return "自動確認の状態が整合していないため、保存を停止しました。"
        case .unreadable(let path): return "自動確認の記録を読み込めません: \(path)"
        case .corrupt(let path): return "自動確認の記録が壊れているため、上書きを停止しました: \(path)"
        case .unsupportedVersion(let version): return "自動確認の記録は未対応の形式です（バージョン \(version)）。"
        case .changedOnDisk: return "自動確認の記録が別の操作で変更されました。再読み込みしてください。"
        case .cannotSave(let path): return "自動確認の記録を保存できません: \(path)"
        case .busy: return "自動確認の記録を別の操作が使用中です。少し待ってからやり直してください。"
        }
    }
}

// A pure state machine. It never starts or stops a process. The owner must save
// each transition before opening the next host, and only pause after the owned
// host has exited. This preserves at most one durable in-flight task.
struct AutoScanRun: Codable, Equatable, Identifiable {
    let id: UUID
    let startedAt: Date
    private(set) var updatedAt: Date
    private(set) var status: AutoScanStatus
    private(set) var pending: [AutoScanTask]
    private(set) var results: [AutoScanResult]
    private(set) var current: AutoScanTask?

    var completedCount: Int { results.count }
    var totalCount: Int { pending.count + results.count + (current == nil ? 0 : 1) }
    // Finish ordinary work before the bounded retry pass, including classes
    // discovered by a retry. Identity never includes the attempt number.
    var nextTask: AutoScanTask? { pending.first { !$0.isRetry } ?? pending.first }
    var hasOrdinaryPending: Bool { pending.contains { !$0.isRetry } }

    init(tasks: [AutoScanTask], startedAt: Date = Date(), id: UUID = UUID()) {
        self.id = id
        self.startedAt = canonicalScanDate(startedAt)
        updatedAt = self.startedAt
        var seen = Set<String>()
        pending = tasks.filter { seen.insert($0.id).inserted }
        results = []
        current = nil
        status = pending.isEmpty ? .complete : .paused
    }

    mutating func resume() {
        guard status != .complete else { return }
        status = pending.isEmpty && current == nil ? .complete : .running
        updatedAt = canonicalScanDate()
    }

    mutating func pause() {
        if let task = current {
            pending.removeAll { $0.id == task.id }
            pending.insert(task, at: 0)
            current = nil
        }
        status = pending.isEmpty ? .complete : .paused
        updatedAt = canonicalScanDate()
    }

    @discardableResult
    mutating func beginNext() -> AutoScanTask? {
        guard status == .running, current == nil else { return nil }
        guard !pending.isEmpty else {
            status = .complete
            updatedAt = canonicalScanDate()
            return nil
        }
        let index = pending.firstIndex { !$0.isRetry } ?? pending.startIndex
        current = pending.remove(at: index)
        updatedAt = canonicalScanDate()
        return current
    }

    mutating func identifyCurrent(classID: String, productName: String, siblings: [AutoScanTask] = []) throws {
        guard let original = current else { throw AutoScanError.noCurrentTask }
        guard !classID.isEmpty, original.classID.isEmpty || original.classID == classID else { throw AutoScanError.wrongClass }
        let identified = AutoScanTask(entry: original.entry, classID: classID, productName: productName,
                                     previousAttempts: original.previousAttempts)
        guard identified.isValid else { throw AutoScanError.invalidState }
        guard !results.contains(where: { $0.id == identified.id }) else { throw AutoScanError.alreadyCompleted }
        // Validate the entire batch before changing anything, so a bad sibling
        // cannot partially rewrite the durable target.
        guard siblings.allSatisfy({ $0.isValid && !$0.classID.isEmpty
            && $0.entry.id == original.entry.id && $0.entry.metadataStamp == original.entry.metadataStamp
            && $0.entry.path == original.entry.path && $0.entry.format == original.entry.format
            && $0.entry.identifier == original.entry.identifier && $0.entry.version == original.entry.version }) else {
            throw AutoScanError.wrongSource
        }
        var next = pending.filter { $0.id != identified.id }
        var seen = Set(next.map(\.id) + results.map(\.id) + [identified.id])
        for sibling in siblings where seen.insert(sibling.id).inserted { next.append(sibling) }
        pending = next
        current = identified
        updatedAt = canonicalScanDate()
    }

    mutating func finishCurrent(outcome: AutoScanOutcome, reason: String, checkedAt: Date = Date(),
                                diagnostics: AutoScanDiagnostics? = nil) throws {
        guard let task = current else { throw AutoScanError.noCurrentTask }
        guard checkedAt.timeIntervalSince1970.isFinite, diagnostics?.isValid ?? true,
              outcome != .noActivationDetected || diagnostics?.hasInspectedDisplay == true else {
            throw AutoScanError.invalidState
        }
        guard !results.contains(where: { $0.id == task.id }) else { throw AutoScanError.alreadyCompleted }
        results.append(AutoScanResult(task: task, outcome: outcome, reason: reason, checkedAt: checkedAt,
                                      diagnostics: diagnostics))
        current = nil
        if pending.isEmpty { status = .complete }
        updatedAt = canonicalScanDate()
    }

    // Called only after the owned host has actually exited. Pauses, ownership
    // failures and storage conflicts must not consume a retry or create a result.
    @discardableResult
    mutating func retryCurrent(outcome: AutoScanOutcome, reason: String, checkedAt: Date = Date(),
                               diagnostics: AutoScanDiagnostics? = nil) throws -> Bool {
        guard var task = current else { throw AutoScanError.noCurrentTask }
        guard !task.isRetry, [.loadFailed, .timedOut].contains(outcome) else { return false }
        let attempt = AutoScanAttempt(outcome: outcome, reason: reason, checkedAt: canonicalScanDate(checkedAt),
                                      diagnostics: diagnostics)
        guard attempt.isValid else { throw AutoScanError.invalidState }
        task.previousAttempts = [attempt]
        guard !pending.contains(where: { $0.id == task.id }), !results.contains(where: { $0.id == task.id }) else {
            throw AutoScanError.alreadyCompleted
        }
        pending.append(task)
        current = nil
        status = .running
        updatedAt = canonicalScanDate()
        return true
    }

    // Reload is always a safe point: a process from the previous app lifetime is
    // not assumed to be alive. Completed results are preserved, while only the
    // interrupted target is returned to the front for an explicit resume.
    fileprivate mutating func recoverAfterReload() {
        guard status != .complete else { return }
        if current != nil || status == .running { pause() }
    }

    fileprivate func validate() throws {
        let tasks = pending + results.map(\.task) + (current.map { [$0] } ?? [])
        guard startedAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite,
              tasks.allSatisfy(\.isValid), Set(tasks.map(\.id)).count == tasks.count,
              results.allSatisfy({ $0.checkedAt.timeIntervalSince1970.isFinite
                  && ($0.diagnostics?.isValid ?? true)
                  && ($0.outcome != .noActivationDetected || $0.diagnostics?.hasInspectedDisplay == true) }),
              current == nil || status == .running,
              status != .complete || (pending.isEmpty && current == nil) else { throw AutoScanError.invalidState }
    }
}

final class AutoScanStore {
    let fileURL: URL
    private let directory: URL
    private let lock = NSLock()
    private var storedRun: AutoScanRun?
    private var diskSnapshot: Data?
    private static let maximumBytes = 16 * 1024 * 1024

    private struct Document: Codable {
        let version: Int
        let run: AutoScanRun
    }

    var run: AutoScanRun? {
        lock.lock(); defer { lock.unlock() }
        return storedRun
    }

    init(directory: URL) throws {
        self.directory = directory
        fileURL = directory.appendingPathComponent("autoscan-state.json")
        try reload()
    }

    func reload() throws {
        lock.lock(); defer { lock.unlock() }
        let data = try readDisk()
        var decoded = try decode(data)
        decoded?.recoverAfterReload()
        storedRun = decoded
        // Keep the original bytes for conflict detection. Recovery is committed
        // only when the owner next saves; it never resumes work by itself.
        diskSnapshot = data
    }

    func save(_ run: AutoScanRun) throws {
        try run.validate()
        lock.lock(); defer { lock.unlock() }
        try withDiskLock {
            let existing = try readDisk()
            _ = try decode(existing)
            guard existing == diskSnapshot else { throw AutoScanError.changedOnDisk }
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .secondsSince1970
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(Document(version: 1, run: run))
                guard data.count <= Self.maximumBytes else { throw AutoScanError.cannotSave(fileURL.path) }
                try data.write(to: fileURL, options: [.atomic])
                storedRun = run
                diskSnapshot = data
            } catch let error as AutoScanError { throw error }
            catch { throw AutoScanError.cannotSave(fileURL.path) }
        }
    }

    fileprivate func withUnchangedSnapshot<T>(_ operation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        return try withDiskLock {
            let existing = try readDisk()
            _ = try decode(existing)
            guard existing == diskSnapshot else { throw AutoScanError.changedOnDisk }
            return try operation()
        }
    }

    private func readDisk() throws -> Data? {
        do {
            return try LocalFileReader.read(fileURL.path, maximumBytes: Self.maximumBytes)
        } catch LocalFileReadError.missing { return nil }
        catch LocalFileReadError.tooLarge { throw AutoScanError.corrupt(fileURL.path) }
        catch { throw AutoScanError.unreadable(fileURL.path) }
    }

    private func decode(_ data: Data?) throws -> AutoScanRun? {
        guard let data = data else { return nil }
        let document: Document
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            document = try decoder.decode(Document.self, from: data)
        } catch { throw AutoScanError.corrupt(fileURL.path) }
        guard document.version == 1 else { throw AutoScanError.unsupportedVersion(document.version) }
        do { try document.run.validate() }
        catch { throw AutoScanError.corrupt(fileURL.path) }
        return document.run
    }

    private func withDiskLock<T>(_ body: () throws -> T) throws -> T {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw AutoScanError.cannotSave(fileURL.path) }
        let fd = Darwin.open(directory.appendingPathComponent(".autoscan-state.lock").path,
                             O_CREAT | O_WRONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, mode_t(0o600))
        guard fd >= 0 else { throw AutoScanError.cannotSave(fileURL.path) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw AutoScanError.cannotSave(fileURL.path)
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw AutoScanError.busy }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }
}

/// A scan starts as a complete set of independent worker checkpoints. Publish
/// their directory only after every checkpoint is durable; a failed new scan
/// must not replace half of the previous scan's results.
final class AutoScanWorkspace {
    private struct Manifest: Codable {
        let version: Int
        let directory: String
    }

    private let directory: URL
    private let manifestURL: URL
    private var diskSnapshot: Data?
    private(set) var activeDirectory: URL

    init(directory: URL) throws {
        self.directory = directory
        manifestURL = directory.appendingPathComponent("current-run.json")
        activeDirectory = directory
        diskSnapshot = try readManifest()
        if let data = diskSnapshot {
            let manifest: Manifest
            do { manifest = try JSONDecoder().decode(Manifest.self, from: data) }
            catch { throw AutoScanError.corrupt(manifestURL.path) }
            guard manifest.version == 1 else { throw AutoScanError.unsupportedVersion(manifest.version) }
            guard UUID(uuidString: manifest.directory) != nil else { throw AutoScanError.corrupt(manifestURL.path) }
            activeDirectory = directory.appendingPathComponent("runs", isDirectory: true)
                .appendingPathComponent(manifest.directory, isDirectory: true)
        }
    }

    func stores(count: Int) throws -> [AutoScanStore] {
        let stores = try (0..<count).map {
            try AutoScanStore(directory: activeDirectory.appendingPathComponent("worker-\($0)"))
        }
        guard diskSnapshot == nil || stores.allSatisfy({ $0.run != nil }) else {
            throw AutoScanError.corrupt(manifestURL.path)
        }
        return stores
    }

    func save(_ run: AutoScanRun, to store: AutoScanStore) throws {
        try withManifestLock {
            try ensureCurrent()
            try store.save(run)
        }
    }

    func replace(with runs: [AutoScanRun], previous: [AutoScanStore]) throws -> [AutoScanStore] {
        guard !runs.isEmpty, runs.count == previous.count else { throw AutoScanError.invalidState }
        try runs.forEach { try $0.validate() }
        return try withManifestLock {
            try ensureCurrent()
            return try withSnapshots(previous[...]) { try publish(runs) }
        }
    }

    private func publish(_ runs: [AutoScanRun]) throws -> [AutoScanStore] {
        let name = UUID().uuidString
        let parent = directory.appendingPathComponent("runs", isDirectory: true)
        let next = parent.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: next, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw AutoScanError.cannotSave(manifestURL.path) }
        do {
            let stores = try runs.enumerated().map { index, run in
                let store = try AutoScanStore(directory: next.appendingPathComponent("worker-\(index)"))
                try store.save(run)
                return store
            }
            let data = try JSONEncoder().encode(Manifest(version: 1, directory: name))
            try data.write(to: manifestURL, options: .atomic)
            diskSnapshot = data
            activeDirectory = next
            return stores
        } catch {
            // Only remove the unpublished directory created above.
            // Old generations remain available for manual recovery.
            do { try FileManager.default.removeItem(at: next) }
            catch { throw AutoScanError.cannotSave(next.path + "（未公開の作業記録を削除できません）") }
            throw error
        }
    }

    private func withSnapshots<T>(_ stores: ArraySlice<AutoScanStore>, _ operation: () throws -> T) throws -> T {
        guard let first = stores.first else { return try operation() }
        return try first.withUnchangedSnapshot { try withSnapshots(stores.dropFirst(), operation) }
    }

    private func readManifest() throws -> Data? {
        do { return try LocalFileReader.read(manifestURL.path, maximumBytes: 1024) }
        catch LocalFileReadError.missing { return nil }
        catch { throw AutoScanError.corrupt(manifestURL.path) }
    }

    private func ensureCurrent() throws {
        guard try readManifest() == diskSnapshot else { throw AutoScanError.changedOnDisk }
    }

    private func withManifestLock<T>(_ operation: () throws -> T) throws -> T {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw AutoScanError.cannotSave(manifestURL.path) }
        let fd = Darwin.open(directory.appendingPathComponent(".autoscan-run.lock").path,
                             O_CREAT | O_WRONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, mode_t(0o600))
        guard fd >= 0 else { throw AutoScanError.cannotSave(manifestURL.path) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw AutoScanError.cannotSave(manifestURL.path)
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw AutoScanError.busy }
        defer { _ = flock(fd, LOCK_UN) }
        return try operation()
    }
}
