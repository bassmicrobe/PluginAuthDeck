// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Darwin

enum LicenseStatus: String, Codable, CaseIterable {
    case needsActivation, activated, notRequired

    var title: String {
        switch self {
        case .needsActivation: return "未認証"
        case .activated: return "認証済み"
        case .notRequired: return "認証不要"
        }
    }
}

enum LicenseSource: String, Codable {
    case detected, user

    var title: String { self == .user ? "手動" : "検出" }
}

struct LicenseRecord: Codable, Identifiable, Equatable {
    var entryID: String
    var metadataStamp: String
    var classID: String
    var productName: String
    var status: LicenseStatus
    var source: LicenseSource
    var evidenceRule: String?
    // For a detection this is the original observation time, not the time when
    // a repeated poll happened to read it. For a user action it is click time.
    var checkedAt: Date

    var id: String { Self.identifier(entryID: entryID, classID: classID) }

    static func identifier(entryID: String, classID: String) -> String {
        // Length framing avoids collisions if a filename contains a delimiter.
        "\(entryID.utf8.count):\(entryID)\(classID.utf8.count):\(classID)"
    }

    init(entryID: String, metadataStamp: String, classID: String, productName: String,
         status: LicenseStatus, source: LicenseSource, evidenceRule: String? = nil,
         checkedAt: Date = Date()) {
        self.entryID = entryID
        self.metadataStamp = metadataStamp
        self.classID = classID
        self.productName = productName
        self.status = status
        self.source = source
        self.evidenceRule = evidenceRule
        self.checkedAt = checkedAt
    }

    fileprivate var isValid: Bool {
        !entryID.isEmpty && !metadataStamp.isEmpty
            && !productName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && checkedAt.timeIntervalSince1970.isFinite
    }
}

enum LicenseStoreError: LocalizedError {
    case unreadable(String)
    case corrupt(String)
    case unsupportedVersion(Int)
    case invalidRecord
    case changedOnDisk
    case cannotSave(String)
    case busy

    var errorDescription: String? {
        switch self {
        case .unreadable(let path): return "認証状態の記録を読み込めません: \(path)"
        case .corrupt(let path): return "認証状態の記録が壊れているため、上書きを停止しました: \(path)"
        case .unsupportedVersion(let version): return "認証状態の記録は未対応の形式です（バージョン \(version)）。上書きは行いません。"
        case .invalidRecord: return "プラグインの版または製品名を確認できないため、認証状態を保存できません。一覧を更新してからやり直してください。"
        case .changedOnDisk: return "認証状態の記録が別の操作で変更されました。再読み込みしてからやり直してください。"
        case .cannotSave(let path): return "認証状態の記録を保存できません: \(path)"
        case .busy: return "認証状態の記録を別の操作が使用中です。少し待ってからやり直してください。"
        }
    }
}

final class LicenseStore {
    let fileURL: URL
    private let directory: URL
    private let lock = NSLock()
    private var storedRecords: [LicenseRecord] = []
    private var diskSnapshot: Data?
    private static let maximumBytes = 16 * 1024 * 1024

    private struct Document: Codable {
        let version: Int
        let records: [LicenseRecord]
    }

    var records: [LicenseRecord] {
        lock.lock(); defer { lock.unlock() }
        return storedRecords
    }

    init(directory: URL) throws {
        self.directory = directory
        fileURL = directory.appendingPathComponent("license-state.json")
        try reload()
    }

    // Reload is explicit. If decoding fails, keep the current in-memory records
    // intact, and never replace the bad file with an empty document.
    func reload() throws {
        lock.lock(); defer { lock.unlock() }
        let data = try readDisk()
        let decoded = try decode(data)
        storedRecords = decoded
        diskSnapshot = data
    }

    func state(for entry: Entry, classID: String) -> LicenseRecord? {
        guard !entry.metadataStamp.isEmpty else { return nil }
        let id = LicenseRecord.identifier(entryID: entry.id, classID: classID)
        return records.first { $0.id == id && $0.metadataStamp == entry.metadataStamp }
    }

    func matchingRecords(entries: [Entry]) -> [LicenseRecord] {
        var current: [String: String] = [:]
        for entry in entries where !entry.metadataStamp.isEmpty { current[entry.id] = entry.metadataStamp }
        return records.filter { current[$0.entryID] == $0.metadataStamp }
    }

    // Returns false for a duplicate or older observation. Different formats and
    // different classes always have different keys; empty classID never acts as
    // a wildcard. Later launches may replace an older confirmation with a newly
    // observed failure, but stale polling from that same session cannot do so.
    @discardableResult
    func upsert(_ record: LicenseRecord) throws -> Bool {
        guard record.isValid else { throw LicenseStoreError.invalidRecord }
        lock.lock(); defer { lock.unlock() }
        return try withDiskLock {
            try ensureUnchanged()
            if let previous = storedRecords.first(where: { $0.id == record.id }) {
                if previous == record { return false }
                if record.checkedAt < previous.checkedAt { return false }
                if record.checkedAt == previous.checkedAt {
                    // User intent wins a tie with a detector. Duplicate/revised
                    // detections at the same time cannot rewrite a prior result.
                    if record.source != .user || previous.source == .user { return false }
                }
            }
            var updated = storedRecords.filter { $0.id != record.id }
            updated.append(record)
            updated.sort { $0.id < $1.id }
            try persist(updated)
            return true
        }
    }

    @discardableResult
    func forget(entryID: String, classID: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return try withDiskLock {
            try ensureUnchanged()
            let id = LicenseRecord.identifier(entryID: entryID, classID: classID)
            let updated = storedRecords.filter { $0.id != id }
            guard updated.count != storedRecords.count else { return false }
            try persist(updated)
            return true
        }
    }

    private func readDisk() throws -> Data? {
        do { return try LocalFileReader.read(fileURL.path, maximumBytes: Self.maximumBytes) }
        catch LocalFileReadError.missing { return nil }
        catch LocalFileReadError.tooLarge { throw LicenseStoreError.corrupt(fileURL.path) }
        catch { throw LicenseStoreError.unreadable(fileURL.path) }
    }

    private func decode(_ data: Data?) throws -> [LicenseRecord] {
        guard let data = data else { return [] }
        let document: Document
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            document = try decoder.decode(Document.self, from: data)
        } catch { throw LicenseStoreError.corrupt(fileURL.path) }
        guard document.version == 1 else { throw LicenseStoreError.unsupportedVersion(document.version) }
        guard document.records.allSatisfy(\.isValid),
              Set(document.records.map(\.id)).count == document.records.count else {
            throw LicenseStoreError.corrupt(fileURL.path)
        }
        return document.records
    }

    private func ensureUnchanged() throws {
        let data = try readDisk()
        _ = try decode(data) // Surface corruption instead of overwriting it.
        guard data == diskSnapshot else { throw LicenseStoreError.changedOnDisk }
    }

    private func persist(_ records: [LicenseRecord]) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .secondsSince1970
            let data = try encoder.encode(Document(version: 1, records: records))
            guard data.count <= Self.maximumBytes else { throw LicenseStoreError.cannotSave(fileURL.path) }
            try data.write(to: fileURL, options: [.atomic])
            // Only publish the new state after the atomic replacement succeeds.
            storedRecords = records
            diskSnapshot = data
        } catch let error as LicenseStoreError { throw error }
        catch { throw LicenseStoreError.cannotSave(fileURL.path) }
    }

    private func withDiskLock<T>(_ body: () throws -> T) throws -> T {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw LicenseStoreError.cannotSave(fileURL.path) }
        let lockPath = directory.appendingPathComponent(".license-state.lock").path
        let fd = Darwin.open(lockPath, O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, mode_t(0o600))
        guard fd >= 0 else { throw LicenseStoreError.cannotSave(fileURL.path) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw LicenseStoreError.cannotSave(fileURL.path)
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw LicenseStoreError.busy }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }
}
