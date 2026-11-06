// SPDX-License-Identifier: AGPL-3.0-only
import Cocoa
import SwiftUI
import Darwin

/// Availability limits for files written by the helper, not a plug-in sandbox.
enum HostReportReader {
    static let statusLimit = 512 * 1024
    static let heartbeatLimit = 4 * 1024

    static func object(at url: URL, maximumBytes: Int) -> [String: Any]? {
        guard url.isFileURL, maximumBytes > 0, maximumBytes < Int.max else { return nil }
        // Nonblocking open is essential: a FIFO must not stall the UI before
        // fstat can reject it. Never follow a substituted report-file symlink.
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= maximumBytes else { return nil }
        let expected = Int(info.st_size)
        // Read one extra byte to reject a file that grew after fstat, rather
        // than accepting a valid JSON prefix. Allocation and total bytes read
        // remain bounded even if a producer keeps appending to the file.
        var data = Data(count: expected + 1)
        let count: Int? = data.withUnsafeMutableBytes { buffer in
            var total = 0
            while total < buffer.count {
                let received = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: total), buffer.count - total)
                guard received >= 0 else { return nil }
                if received == 0 { return total }
                total += received
            }
            return total
        }
        guard count == expected else { return nil }
        data.removeLast()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

struct HostSession: Identifiable {
    let id: UUID
    let entry: Entry
    let process: Process
    let directory: URL
    let started: Date
    var lifecycle: SessionLifecycle
    var knownClasses: [String] = []
    var classID = ""
    var evidenceObservedAt = 0.0
    var products: [ScanProduct] = []
    var readyAt: Date?
    var candidate: ScanCandidate?
    var state: String { lifecycle.state }
    var message: String { lifecycle.message }
    var stopping: Bool { lifecycle.stopping }
    var isRunning: Bool { lifecycle.isRunning }
}

final class DeskModel: ObservableObject {
    private static let maximumInventoryCacheBytes = 16 * 1024 * 1024
    @Published var entries: [Entry] = []
    @Published var managers = Inventory.managers()
    @Published var selection: String?
    @Published var query = ""
    @Published var category = "未認証"
    @Published var format = "すべて"
    @Published var architecture = "自動"
    @Published var favoritesOnly = false
    @Published var favorites = Set(UserDefaults.standard.stringArray(forKey: "favorites") ?? [])
    @Published var sessions: [HostSession] = []
    @Published var scanning = false
    @Published var notice = ""
    @Published var scanSeconds = 0.0
    @Published var licenseRecords: [LicenseRecord] = []
    @Published var licenseError = ""
    @Published var inventoryError = ""
    @Published var unconfirmedOnly = false
    @Published var workflow: ActivationWorkflow?
    private let supportDirectory: URL
    private var licenseStore: LicenseStore?
    private var entryIndex: [String: Entry] = [:]
    private var licenseIndex: [String: [LicenseRecord]] = [:]
    private var timer: Timer?
    private var searchDocuments: [String: String] = [:]
    private var backgroundTimersEnabled = true
    lazy var automaticScanner: AutomaticScanner = {
        let scanner = AutomaticScanner(directory: supportDirectory.appendingPathComponent("Automatic Scan"),
                                       automaticallyTick: backgroundTimersEnabled)
        scanner.launch = { [weak self] task in self?.open(task.entry, classID: task.classID, automatic: true) }
        scanner.stop = { [weak self] id in self?.stop(id) }
        scanner.observe = { [weak self] id in
            guard let self = self, let session = self.sessions.first(where: { $0.id == id }) else { return nil }
            let license = self.records(for: session.entry).first { $0.classID == session.classID }
            return ScanObservation(isRunning: session.process.isRunning || session.lifecycle.isRunning,
                state: session.state, classID: session.classID, productName: session.lifecycle.displayName,
                classes: session.products, startedAt: session.started, readyAt: session.readyAt,
                needsActivation: license?.status == .needsActivation,
                evidenceRule: license?.evidenceRule ?? "user_confirmed", candidate: session.candidate)
        }
        scanner.isKnown = { [weak self] task in
            self?.records(for: task.entry).contains { $0.classID == task.classID } ?? false
        }
        scanner.storageIssue = { [weak self] in self?.licenseError ?? "" }
        return scanner
    }()

    private static func searchIndex(_ entries: [Entry]) -> [String: String] {
        Dictionary(entries.map { ($0.id, $0.searchText) }, uniquingKeysWith: { _, latest in latest })
    }

    init(directory: URL = Inventory.support, initialEntries: [Entry]? = nil, refreshOnLaunch: Bool = true) {
        supportDirectory = directory
        backgroundTimersEnabled = refreshOnLaunch
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
        let cache = supportDirectory.appendingPathComponent("inventory.json")
        do {
            let data = try LocalFileReader.read(cache.path, maximumBytes: Self.maximumInventoryCacheBytes)
            entries = try JSONDecoder().decode([Entry].self, from: data)
        } catch LocalFileReadError.missing {
            // A first launch has no cache; the inventory refresh creates it.
        } catch {
            inventoryError = "一覧キャッシュを読み込めません。「一覧を更新」で再取得してください。認証記録は変更していません。"
        }
        if let initialEntries = initialEntries { entries = initialEntries }
        searchDocuments = Self.searchIndex(entries + managers)
        entryIndex = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        do {
            let store = try LicenseStore(directory: supportDirectory)
            licenseStore = store
            licenseRecords = store.records
            licenseIndex = Dictionary(grouping: licenseRecords, by: \.entryID)
        } catch { licenseError = "認証記録を読み込めません。元の記録を保護して記録操作を停止しています: " + error.localizedDescription }
        if refreshOnLaunch { refresh() }
    }

    var filtered: [Entry] {
        let source = category == "認証アプリ" ? managers : entries
        let words = query.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased().split(whereSeparator: { $0.isWhitespace })
        return source.filter { e in
            (category == "認証アプリ" || format == "すべて" || e.format == format)
            && (!favoritesOnly || favorites.contains(e.id))
            && (category != "プラグイン" || !unconfirmedOnly || needsReview(e))
            && words.allSatisfy { (searchDocuments[e.id] ?? e.name.lowercased()).contains($0) }
        }
    }
    var currentRecords: [LicenseRecord] {
        licenseRecords.filter { !$0.metadataStamp.isEmpty && entryIndex[$0.entryID]?.metadataStamp == $0.metadataStamp }
    }
    var unactivated: [LicenseRecord] {
        let words = query.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased().split(whereSeparator: { $0.isWhitespace })
        return currentRecords.filter { r in
            guard r.status == .needsActivation, let e = entryIndex[r.entryID] else { return false }
            // A bundle's other class names must not select this product into an
            // activation run. Search only the actual recorded product/vendor.
            var product = e
            product.name = r.productName
            product.aliases = []
            return (format == "すべて" || e.format == format)
                && (!favoritesOnly || favorites.contains(e.id))
                && words.allSatisfy { product.searchText.contains($0) }
        }.sorted { $0.productName.localizedStandardCompare($1.productName) == .orderedAscending }
    }
    var selectedRecord: LicenseRecord? { category == "未認証" ? unactivated.first { $0.id == selection } : nil }
    var selected: Entry? {
        if category == "未認証" { return selectedRecord.flatMap { entryIndex[$0.entryID] } }
        return filtered.first { $0.id == selection }
    }
    var visibleCount: Int { category == "未認証" ? unactivated.count : filtered.count }
    func records(for entry: Entry) -> [LicenseRecord] {
        (licenseIndex[entry.id] ?? []).filter { $0.metadataStamp == entry.metadataStamp && !entry.metadataStamp.isEmpty }
    }
    func needsReview(_ entry: Entry) -> Bool {
        let current = entryIndex[entry.id].flatMap { $0.metadataStamp == entry.metadataStamp ? $0 : nil } ?? entry
        // Product names are not identities: two classes may have the same name,
        // and a legacy names-only catalog cannot prove that all were listed.
        guard !current.metadataStamp.isEmpty,
              let enumerated = Inventory.classIDs(current.enumeratedClassIDs) else { return true }
        return !Set(enumerated).isSubset(of: Set(records(for: current).map(\.classID)))
    }
    var activeCount: Int { sessions.filter { $0.isRunning }.count }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        DispatchQueue.global(qos: .utility).async {
            let start = Date()
            let found = Inventory.scan()
            let managers = Inventory.managers()
            let searchIndex = Self.searchIndex(found + managers)
            let duration = Date().timeIntervalSince(start)
            DispatchQueue.main.async {
                let merged = found.map { Inventory.preservingClassMetadata(in: $0, from: self.entryIndex[$0.id]) }
                self.entries = merged
                self.entryIndex = Dictionary(merged.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
                self.managers = managers
                self.searchDocuments = searchIndex
                for (scanned, current) in zip(found, merged) where scanned.aliases != current.aliases {
                    self.searchDocuments[current.id] = current.searchText
                }
                // Serialize cache updates with host metadata on the main queue,
                // so an older background scan cannot overwrite learned classes.
                self.saveInventoryCache()
                self.scanSeconds = duration
                self.scanning = false
            }
        }
    }

    func toggleFavorite(_ e: Entry) {
        if favorites.contains(e.id) { favorites.remove(e.id) } else { favorites.insert(e.id) }
        UserDefaults.standard.set(Array(favorites), forKey: "favorites")
    }

    func openManager(_ e: Entry) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: e.path), configuration: configuration) { _, error in
            if let error = error { DispatchQueue.main.async { self.notice = "アプリを開けません: " + error.localizedDescription } }
        }
    }

    func managerFor(_ entry: Entry) -> Entry? {
        let vendor = entry.vendor.lowercased().replacingOccurrences(of: " ", with: "")
        return managers.first { e in
            let candidate = e.vendor.lowercased().replacingOccurrences(of: " ", with: "")
            return vendor.count >= 3 && (vendor == candidate || vendor.hasPrefix(candidate))
        }
    }

    @discardableResult func open(_ e: Entry, classID: String = "", forWorkflow: Bool = false, automatic: Bool = false) -> UUID? {
        notice = ""
        if e.format == "APP" { openManager(e); return nil }
        guard !automaticScanner.isBusy || automatic else { notice = "自動チェック中です。プラグインを操作する場合は一時停止してください。"; return nil }
        guard workflow == nil || forWorkflow else { notice = "順番に確認中です。続けるか「中断」で終了してください。"; return nil }
        if let s = sessions.first(where: { $0.entry.id == e.id && (classID.isEmpty || $0.classID == classID) && $0.process.isRunning && !$0.stopping }) {
            NSRunningApplication(processIdentifier: s.process.processIdentifier)?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            return s.id
        }
        guard activeCount < 3 else { notice = "開いているプラグインを1つ終了してから追加してください（同時に3つまで）。"; return nil }
        guard FileManager.default.fileExists(atPath: e.path) else {
            notice = "ファイルが見つかりません。一覧を更新してください。"; return nil
        }
        let requestedArch = !automatic && architecture == "Intel (Rosetta)" ? "x86_64" : !automatic && architecture == "Apple Silicon" ? "arm64"
            : e.architectures.contains("arm64") || e.architectures.isEmpty ? "arm64" : "x86_64"
        if !e.architectures.isEmpty && !e.architectures.contains(requestedArch) {
            notice = "この形式には選択したCPU向けのコードがありません。実行方式を変更してください。"; return nil
        }
        if requestedArch == "x86_64" && !FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime") {
            notice = "Intel版の起動にはRosetta 2が必要です。Apple Silicon版またはメーカーのアプリを使用してください。"; return nil
        }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/AuthPluginHost.app/Contents/MacOS/AuthPluginHost")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { notice = "ホスト本体が見つかりません。アプリを再ビルドしてください。"; return nil }
        let id = UUID()
        let directory = supportDirectory.appendingPathComponent("Sessions/" + id.uuidString)
        let request = directory.appendingPathComponent("request.json")
        var launchEntry = e
        // A user can launch from a v1 cache before the background refresh finishes.
        // Capture identity immediately before loading, not from that older cache.
        launchEntry.metadataStamp = Inventory.stamp(path: e.path, info: Inventory.plist(e.path + "/Contents/Info.plist"))
        if (forWorkflow || automatic) && launchEntry.metadataStamp != e.metadataStamp {
            notice = "プラグインが更新されました。一覧を更新してから改めて確認してください。"; return nil
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(withJSONObject: ["name": e.name, "format": e.format,
                "identifier": e.identifier, "path": e.path, "classID": classID,
                "mode": automatic ? "scan" : "manual", "parentPID": ProcessInfo.processInfo.processIdentifier])
            try data.write(to: request, options: .atomic)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
            // Arguments are passed as separate values, never interpolated into a shell.
            p.arguments = ["-" + requestedArch, helper.path, "--request", request.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            p.terminationHandler = { [weak self] process in
                DispatchQueue.main.async {
                    guard let self = self, let i = self.sessions.firstIndex(where: { $0.id == id }) else { return }
                    // Capture the final error even if the child exits between polls.
                    if let report = HostReportReader.object(at: self.sessions[i].directory.appendingPathComponent("status.json"),
                                                            maximumBytes: HostReportReader.statusLimit) {
                        var finalSession = self.sessions[i]
                        finalSession.lifecycle.receive(report, heartbeat: nil)
                        if self.receiveHostMetadata(report, session: &finalSession) { self.saveInventoryCache() }
                        self.sessions[i] = finalSession
                    }
                    self.sessions[i].lifecycle.exited(code: process.terminationStatus)
                    self.advanceWorkflow(afterExit: id)
                    self.prune()
                    if self.activeCount == 0 { self.timer?.invalidate(); self.timer = nil }
                }
            }
            try p.run()
            let started = Date()
            sessions.append(HostSession(id: id, entry: launchEntry, process: p, directory: directory, started: started,
                                        lifecycle: SessionLifecycle(name: e.name, startedAt: started)))
            startPolling()
            prune()
            return id
        } catch { notice = "起動できません: " + error.localizedDescription; return nil }
    }

    func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
    }

    func poll() {
        var updated = sessions
        var catalogChanged = false
        for i in sessions.indices where sessions[i].process.isRunning {
            let s = sessions[i]
            let statusURL = s.directory.appendingPathComponent("status.json")
            let report = HostReportReader.object(at: statusURL, maximumBytes: HostReportReader.statusLimit) ?? [:]
            let heartbeatURL = s.directory.appendingPathComponent("heartbeat.json")
            let beat = HostReportReader.object(at: heartbeatURL, maximumBytes: HostReportReader.heartbeatLimit)
            let heartbeat = (beat?["timestamp"] as? Double).map(Date.init(timeIntervalSince1970:))
            updated[i].lifecycle.receive(report, heartbeat: heartbeat)
            catalogChanged = receiveHostMetadata(report, session: &updated[i]) || catalogChanged
        }
        if zip(sessions, updated).contains(where: { $0.lifecycle != $1.lifecycle || $0.knownClasses != $1.knownClasses || $0.classID != $1.classID || $0.evidenceObservedAt != $1.evidenceObservedAt || $0.products != $1.products || $0.readyAt != $1.readyAt || $0.candidate != $1.candidate }) {
            sessions = updated
        }
        if catalogChanged { saveInventoryCache() }
    }

    private func receiveHostMetadata(_ report: [String: Any], session: inout HostSession) -> Bool {
        var catalogChanged = false
        var enumeratedIDs: [String]?
        if report["state"] as? String == "ready", session.readyAt == nil { session.readyAt = Date() }
        if let classID = report["classID"] as? String { session.classID = classID }
        // A first observation only extends the scan's bounded observation
        // window. It is transient and never becomes a license-state record.
        session.candidate = nil
        if let classID = report["classID"] as? String, !classID.isEmpty, classID == session.classID,
           let state = report["state"] as? String, ["loading", "ready"].contains(state),
           report["licenseEvidence"] == nil,
           let candidate = report["licenseCandidate"] as? [String: Any],
           let rule = candidate["rule"] as? String,
           let observedAt = candidate["observedAt"] as? Double,
           observedAt.isFinite, observedAt >= session.started.timeIntervalSince1970 - 1,
           observedAt <= Date().timeIntervalSince1970 + 5 {
            session.candidate = ScanCandidate(rule: rule, observedAt: Date(timeIntervalSince1970: observedAt))
        }
        if let classes = report["classEntries"] as? [[String: String]] {
            session.products = classes.compactMap {
                guard let id = $0["classID"], let name = $0["name"], !id.isEmpty,
                      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      name.utf8.count <= 1024, !name.contains("\0") else { return nil }
                return ScanProduct(classID: id, name: name)
            }
            if session.products.count == classes.count,
               let names = report["classes"] as? [String], names == session.products.map(\.name),
               session.products.contains(where: { $0.classID == session.classID }) {
                enumeratedIDs = Inventory.classIDs(session.products.map(\.classID))
            }
        }
        if let evidence = report["licenseEvidence"] as? [String: Any], let observed = evidence["observedAt"] as? Double,
           observed > session.evidenceObservedAt, receiveLicenseEvidence(report, session: session) {
            session.evidenceObservedAt = observed
        }
        if workflow?.mode == .review, workflow?.sessionID == session.id, !session.classID.isEmpty,
           let classes = report["classEntries"] as? [[String: String]] {
            let checked = Set(records(for: session.entry).map(\.classID))
            let siblings = classes.compactMap { product -> ActivationTarget? in
                guard let id = product["classID"], let name = product["name"], id != session.classID,
                      !checked.contains(id) else { return nil }
                return ActivationTarget(entry: session.entry, classID: id, productName: name)
            }
            if var updatedWorkflow = workflow, updatedWorkflow.includeUnconfirmedSiblings(siblings) {
                workflow = updatedWorkflow
            }
        }
        let newIDs = enumeratedIDs.map {
            !Set($0).isSubset(of: Set(entryIndex[session.entry.id]?.enumeratedClassIDs ?? []))
        } ?? false
        if let classes = report["classes"] as? [String], !classes.isEmpty,
           classes != session.knownClasses || newIDs {
            session.knownClasses = classes
            if let entry = Inventory.rememberClasses(for: session.entry, names: classes, classIDs: enumeratedIDs,
                                                     directory: supportDirectory),
               let index = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[index] = entry
                entryIndex[entry.id] = entry
                searchDocuments[entry.id] = entry.searchText
                catalogChanged = true
            }
        }
        return catalogChanged
    }

    private func saveInventoryCache() {
        do {
            let data = try JSONEncoder().encode(entries)
            guard data.count <= Self.maximumInventoryCacheBytes else { throw LocalFileReadError.tooLarge }
            try data.write(to: supportDirectory.appendingPathComponent("inventory.json"), options: .atomic)
            inventoryError = ""
        } catch {
            inventoryError = "一覧キャッシュを保存できません。表示中の一覧は利用できますが、次回起動時は再取得が必要です。"
        }
    }

    func stop(_ id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }), sessions[i].process.isRunning,
              !sessions[i].stopping else { return }
        sessions[i].lifecycle.requestStop()
        let process = sessions[i].process
        // Give the plug-in its normal editor/processor destruction path first.
        // This only targets a Process retained by this launcher, never saved PIDs.
        try? Data().write(to: sessions[i].directory.appendingPathComponent("quit.request"), options: .atomic)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func saveRecord(_ record: LicenseRecord) -> Bool {
        guard let store = licenseStore else { return false }
        do {
            if try store.upsert(record) {
                licenseRecords = store.records
                licenseIndex = Dictionary(grouping: licenseRecords, by: \.entryID)
            }
            licenseError = ""
            return true
        } catch {
            licenseError = "認証記録を保存できません。次へ進まずに再試行してください: " + error.localizedDescription
            return false
        }
    }

    private func receiveLicenseEvidence(_ report: [String: Any], session: HostSession) -> Bool {
        guard let evidence = report["licenseEvidence"] as? [String: Any],
              evidence["state"] as? String == "needsActivation",
              let classID = evidence["classID"] as? String, !classID.isEmpty, classID == session.classID,
              let rule = evidence["rule"] as? String,
              let name = evidence["name"] as? String,
              let observedAt = evidence["observedAt"] as? Double, observedAt.isFinite,
              observedAt >= session.started.timeIntervalSince1970 - 1, observedAt <= Date().timeIntervalSince1970 + 5 else { return false }
        return saveRecord(LicenseRecord(entryID: session.entry.id, metadataStamp: session.entry.metadataStamp,
            classID: classID, productName: name, status: .needsActivation, source: .detected,
            evidenceRule: rule, checkedAt: Date(timeIntervalSince1970: observedAt)))
    }

    @discardableResult func mark(_ session: HostSession, as status: LicenseStatus) -> Bool {
        guard !session.classID.isEmpty else { notice = "製品を選択して、画面が開くまでお待ちください。"; return false }
        guard session.entry.metadataStamp == Inventory.stamp(path: session.entry.path,
                info: Inventory.plist(session.entry.path + "/Contents/Info.plist")) else {
            notice = "確認中にファイルが変更されました。更新した製品を開き直してください。"; return false
        }
        let saved = saveRecord(LicenseRecord(entryID: session.entry.id, metadataStamp: session.entry.metadataStamp,
            classID: session.classID, productName: session.lifecycle.displayName, status: status, source: .user))
        guard saved else { return false }
        guard let applied = licenseStore?.state(for: session.entry, classID: session.classID),
              applied.status == status, applied.source == .user else {
            notice = "新しい日時の記録があるため、確認を保存できませんでした。記録を再読み込みして日時を確認してください。"
            return false
        }
        notice = "\(session.lifecycle.displayName): \(status.title)として記録しました（ユーザー確認）。"
        return true
    }

    func forget(_ record: LicenseRecord) {
        do {
            try licenseStore?.forget(entryID: record.entryID, classID: record.classID)
            licenseRecords = licenseStore?.records ?? []
            licenseIndex = Dictionary(grouping: licenseRecords, by: \.entryID)
        } catch { licenseError = "記録を変更できません: " + error.localizedDescription }
    }

    func reloadLicenseState() {
        do {
            let store = try LicenseStore(directory: supportDirectory)
            licenseStore = store
            licenseRecords = store.records
            licenseIndex = Dictionary(grouping: licenseRecords, by: \.entryID)
            licenseError = ""
        } catch { licenseError = "認証記録を読み込めません: " + error.localizedDescription }
    }

    func startActivation() {
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let targets = unactivated.compactMap { r in
            byID[r.entryID].map { ActivationTarget(entry: $0, classID: r.classID, productName: r.productName) }
        }
        startWorkflow(mode: .activate, targets: targets)
    }

    func startAutomaticScan() {
        guard workflow == nil, activeCount == 0, !scanning, licenseError.isEmpty else {
            notice = "一覧の更新と、開いているプラグインの終了を待ってから自動チェックを開始してください。"; return
        }
        // Whole inventory, independent of search, favorites and format filters.
        automaticScanner.start(tasks: entries.filter { needsReview($0) }.map { AutoScanTask(entry: $0) })
        category = "未認証"; query = ""; favoritesOnly = false; format = "すべて"
    }

    func resumeAutomaticScan() {
        guard activeCount == 0, workflow == nil, licenseError.isEmpty else {
            notice = "開いているプラグインを終了してから再開してください。"; return
        }
        automaticScanner.resume()
    }

    func startReview() {
        startWorkflow(mode: .review, targets: filtered.filter { needsReview($0) }.map {
            ActivationTarget(entry: $0, classID: "", productName: $0.name)
        })
    }

    private func startWorkflow(mode: ActivationWorkflow.Mode, targets: [ActivationTarget]) {
        guard workflow == nil, !targets.isEmpty, licenseStore != nil, !automaticScanner.isBusy else { return }
        guard activeCount == 0 else { notice = "先に、開いているプラグインを終了してください。順番の確認では1件ずつ開きます。"; return }
        workflow = ActivationWorkflow(mode: mode, targets: targets)
        launchWorkflowItem()
    }

    var workflowSession: HostSession? {
        guard let id = workflow?.sessionID else { return nil }
        return sessions.first { $0.id == id }
    }

    func launchWorkflowItem() {
        guard let item = workflow?.current, workflow?.waitingForExit == false,
              workflowSession?.process.isRunning != true, !isShuttingDown else { return }
        workflow?.sessionID = open(item.entry, classID: item.classID, forWorkflow: true)
    }

    func finishWorkflowItem(as status: LicenseStatus? = nil) {
        guard workflow != nil, workflow?.waitingForExit == false else { return }
        if let status = status {
            guard let session = workflowSession, mark(session, as: status) else { return }
        }
        workflow?.requestAdvance()
        if let s = workflowSession, s.process.isRunning { stop(s.id) }
        else { advanceWorkflow(afterExit: workflow?.sessionID) }
    }

    private func advanceWorkflow(afterExit id: UUID?) {
        guard !isShuttingDown, workflow?.advance(afterExit: id) == true else { return }
        if workflow?.isFinished == true {
            workflow = nil
            notice = "今回の順番の確認を終了しました。保留した未認証の製品は一覧に残っています。"
        } else { launchWorkflowItem() }
    }

    func cancelWorkflow() {
        let sessionID = workflow?.sessionID
        workflow = nil
        if let sessionID = sessionID { stop(sessionID) }
        notice = "順番の確認を中断しました。記録済みの状態は保存されています。"
    }

    func clearFinished() {
        let protected = automaticScanner.ownedSessionIDs
        let finished = sessions.filter { !$0.process.isRunning && $0.id != workflow?.sessionID && !protected.contains($0.id) }
        for s in finished {
            try? FileManager.default.removeItem(at: s.directory)
        }
        let ids = Set(finished.map(\.id))
        sessions.removeAll { ids.contains($0.id) }
    }

    func prune() {
        let protected = automaticScanner.ownedSessionIDs
        let finished = sessions.filter { !$0.process.isRunning && !protected.contains($0.id) }
        for s in finished.dropLast(4) {
            // Session folders are generated UUID children, not paths supplied by plugins.
            try? FileManager.default.removeItem(at: s.directory)
            sessions.removeAll { $0.id == s.id }
        }
    }
    private var isShuttingDown = false
    func shutdown(_ completion: @escaping () -> Void) {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        automaticScanner.shutdown()
        workflow = nil
        timer?.invalidate()
        timer = nil
        let active = sessions.filter { $0.process.isRunning }
        active.forEach { stop($0.id) }
        guard !active.isEmpty else { completion(); return }
        let deadline = Date().addingTimeInterval(4.5)
        func check() {
            if active.allSatisfy({ !$0.process.isRunning }) || Date() >= deadline {
                completion()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: check)
            }
        }
        check()
    }

}

struct DeskView: View {
    @ObservedObject var model: DeskModel
    private let accent = Color(red: 0.43, green: 0.36, blue: 0.89)
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "key.horizontal.fill").font(.system(size: 29)).foregroundColor(accent)
                    .frame(width: 56, height: 56).background(accent.opacity(0.10)).cornerRadius(15)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Plugin Auth Desk").font(.system(size: 24, weight: .bold))
                    Text("DAWを開かずに、プラグインの認証画面へ。").font(.system(size: 12)).foregroundColor(.secondary)
                }
                Spacer()
                Label("音声出力なし", systemImage: "speaker.slash").font(.system(size: 12)).foregroundColor(.secondary)
                Button(action: model.refresh) { Label("一覧を更新", systemImage: "arrow.clockwise") }.disabled(model.scanning)
            }.padding(24)
            Divider()
            AutomaticScanPanel(scanner: model.automaticScanner,
                start: model.startAutomaticScan, resume: model.resumeAutomaticScan,
                mayStart: model.workflow == nil && model.activeCount == 0 && !model.scanning && model.licenseError.isEmpty)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("表示", selection: $model.category) {
                        Text("未認証").tag("未認証")
                        Text("プラグイン").tag("プラグイン")
                        Text("認証アプリ").tag("認証アプリ")
                    }.pickerStyle(.segmented).labelsHidden()
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                        TextField("名前・メーカーで検索", text: $model.query)
                            .textFieldStyle(.plain).accessibilityIdentifier("plugin-search")
                        if !model.query.isEmpty {
                            Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundColor(.secondary).help("検索を消去")
                                .accessibilityLabel("検索を消去")
                        }
                    }.padding(9).background(Color(nsColor: .textBackgroundColor)).cornerRadius(8)
                    HStack {
                        if model.category != "認証アプリ" {
                            Picker("形式", selection: $model.format) {
                                Text("VST3").tag("VST3"); Text("AU").tag("AU"); Text("すべて").tag("すべて")
                            }.frame(width: 130)
                        }
                        Spacer()
                        Toggle(isOn: $model.favoritesOnly) { Image(systemName: "star.fill").foregroundColor(.yellow) }
                            .toggleStyle(.checkbox).help("お気に入りだけ表示")
                            .accessibilityLabel("お気に入りだけ表示")
                    }
                    if model.category == "未認証" {
                        Text("未認証の表示を検出した製品と、手動で未認証にした製品だけを表示します。")
                            .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("一覧を順番に認証（\(model.unactivated.count)件）", action: model.startActivation)
                            .buttonStyle(.borderedProminent).disabled(model.unactivated.isEmpty || model.workflow != nil || !model.licenseError.isEmpty)
                    } else if model.category == "プラグイン" {
                        Toggle("未確認を含む製品だけ", isOn: $model.unconfirmedOnly).font(.system(size: 11))
                        Button("表示中の未確認を順に開く", action: model.startReview)
                            .disabled(model.filtered.isEmpty || model.workflow != nil || !model.licenseError.isEmpty)
                    }
                    List(selection: $model.selection) {
                        if model.category == "未認証" {
                            ForEach(model.unactivated) { record in
                                if let entry = model.entries.first(where: { $0.id == record.entryID }) {
                                    entryRow(entry, name: record.productName, caption: "未認証・" + record.source.title)
                                        .tag(record.id)
                                }
                            }
                        } else {
                            ForEach(model.filtered) { entry in
                                entryRow(entry, name: entry.name, caption: nil).tag(entry.id)
                                .contextMenu {
                                    Button("画面を開く") { model.open(entry) }
                                    Button("お気に入りを切り替え") { model.toggleFavorite(entry) }
                                    Button("Finderで表示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) }
                                }
                            }
                        }
                    }.listStyle(.inset).accessibilityIdentifier("plugin-list")
                        .overlay {
                            if model.visibleCount == 0 && !model.scanning {
                                VStack(spacing: 10) {
                                    Text(model.category == "未認証" ? "該当する未認証の記録はありません" : "該当する項目がありません").foregroundColor(.secondary)
                                    if model.category == "未認証" {
                                        Text("未確認の製品は、認証済みを意味しません。")
                                            .font(.system(size: 10)).foregroundColor(.secondary)
                                        Text("上の「未確認をすべて自動チェック」で調べられます。")
                                            .font(.system(size: 10)).foregroundColor(.secondary)
                                    }
                                    Button("絞り込みを解除") {
                                        model.query = ""; model.favoritesOnly = false; model.format = "すべて"
                                        model.unconfirmedOnly = false
                                    }
                                }.font(.system(size: 12))
                            }
                        }
                    HStack {
                        Text("\(model.visibleCount) 件").font(.system(size: 11)).foregroundColor(.secondary)
                        Spacer()
                        if model.scanning { ProgressView().scaleEffect(0.6).frame(width: 16, height: 16) }
                        Text(model.scanning ? "一覧を更新中" : "ファイル情報から取得").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                }.padding(18).frame(width: 355)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if let workflow = model.workflow { workflowPanel(workflow) }
                        if !model.licenseError.isEmpty {
                            Label(model.licenseError, systemImage: "exclamationmark.triangle").foregroundColor(.red).textSelection(.enabled)
                            Button("記録を再読み込み", action: model.reloadLicenseState)
                        }
                        if !model.inventoryError.isEmpty {
                            Label(model.inventoryError, systemImage: "exclamationmark.triangle")
                                .foregroundColor(.orange).textSelection(.enabled)
                        }
                        if let entry = model.selected {
                            detail(entry)
                        } else {
                            VStack(alignment: .leading, spacing: 15) {
                                Image(systemName: "rectangle.on.rectangle").font(.system(size: 34)).foregroundColor(accent)
                                Text(model.category == "認証アプリ" ? "メーカーの管理アプリを選択" : model.category == "未認証" ? "未認証の製品を、1件ずつ認証" : "認証状態を確認するプラグインを選択").font(.system(size: 21, weight: .semibold))
                                Text(model.category == "認証アプリ" ? "iLokやメーカーのアプリをここから開けます。ライセンスの有効化は各アプリで行ってください。" : model.category == "未認証" ? "「一覧を順番に認証」で画面を開き、メーカーの画面で認証してください。「認証できたので次へ」で記録して次の製品を開きます。「あとで」は一覧に残ります。" : "「表示中の未確認を順に開く」で1件ずつ確認できます。画面に明確な未認証表示があれば自動で記録します。判定できない場合は、画面を見て状態を選んでください。")
                                    .foregroundColor(.secondary).lineSpacing(5)
                                Text("iLok、Native Access、Arturiaなどは「認証アプリ」タブから開けます。")
                                    .foregroundColor(.secondary).lineSpacing(5)
                                Text("未確認の製品は上の自動チェックで調べられます。明示的な未認証表示を検出した製品だけがこの一覧に入り、判定できなかった製品は結果に分けて記録されます。")
                                    .font(.system(size: 11)).foregroundColor(.secondary)
                            }.padding(.vertical, 12)
                        }
                        if !model.notice.isEmpty {
                            Label(model.notice, systemImage: "exclamationmark.circle").foregroundColor(.orange).textSelection(.enabled)
                        }
                        if !model.sessions.isEmpty {
                            Divider()
                            HStack {
                                Text("開いたプラグイン").font(.system(size: 13, weight: .semibold))
                                Spacer(); Text("動作中 \(model.activeCount) / 3").font(.system(size: 11)).foregroundColor(.secondary)
                                if model.sessions.contains(where: { !$0.isRunning }) {
                                    Button("終了済みを消去", action: model.clearFinished).font(.system(size: 11))
                                }
                            }
                            ForEach(model.sessions.reversed()) { session in
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack {
                                        Circle().fill(session.state == "ready" ? Color.green : ["error", "waiting"].contains(session.state) ? Color.orange : Color.gray).frame(width: 7, height: 7)
                                        Text(session.lifecycle.displayName).font(.system(size: 13, weight: .medium))
                                        Text(session.entry.format).font(.system(size: 10)).foregroundColor(.secondary)
                                        Spacer()
                                        if session.isRunning {
                                            Button("表示") { NSRunningApplication(processIdentifier: session.process.processIdentifier)?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) }
                                            Button("終了") { model.stop(session.id) }.disabled(session.stopping)
                                        }
                                    }
                                    Text(model.automaticScanner.ownedSessionIDs.contains(session.id)
                                         && session.isRunning && !session.stopping && session.state != "error"
                                         ? "未認証の表示を自動チェック中。画面の操作は不要です。" : session.message)
                                        .font(.system(size: 11)).foregroundColor(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    if !session.classID.isEmpty && model.workflow?.sessionID != session.id && !model.automaticScanner.ownedSessionIDs.contains(session.id) {
                                        recordButtons(session)
                                    }
                                }.padding(12).background(Color(nsColor: .controlBackgroundColor)).cornerRadius(10)
                            }
                        }
                        Spacer(minLength: 15)
                    }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            HStack {
                Text("認証はメーカーの画面で操作します。未認証の明示表示を検出／認証済みはユーザー確認で記録。入力内容は保存しません。")
                Spacer()
                Button("使い方") { showHelp() }.buttonStyle(.link)
            }.font(.system(size: 10)).foregroundColor(.secondary).padding(.horizontal, 22).padding(.vertical, 11)
        }.frame(minWidth: 960, minHeight: 670).tint(accent)
            .onChange(of: model.category) { _ in model.selection = nil }
            .onChange(of: model.query) { _ in model.selection = nil }
            .onChange(of: model.format) { _ in model.selection = nil }
    }

    func entryRow(_ entry: Entry, name: String, caption: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.format == "APP" ? "app.badge.checkmark" : caption == nil ? "pianokeys" : "key")
                .foregroundColor(accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).lineLimit(1).font(.system(size: 13, weight: .medium))
                Text(caption ?? (entry.vendor.isEmpty ? "メーカー未記載" : entry.vendor))
                    .font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 2)
            if model.favorites.contains(entry.id) { Image(systemName: "star.fill").foregroundColor(.yellow).font(.system(size: 10)) }
            Text(entry.format).font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
        }.padding(.vertical, 5)
    }

    @ViewBuilder func workflowPanel(_ workflow: ActivationWorkflow) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(workflow.mode == .activate ? "順番に認証" : "順番に状態を確認").font(.headline)
                Spacer()
                Text("\(workflow.index + 1) / \(workflow.targets.count)").foregroundColor(.secondary)
                Button("中断", action: model.cancelWorkflow)
            }
            Text(model.workflowSession?.lifecycle.displayName ?? workflow.current?.productName ?? "")
                .font(.system(size: 20, weight: .semibold))
            if workflow.waitingForExit {
                Label("現在のプラグインを終了してから次を開きます…", systemImage: "hourglass")
            } else {
                Text(workflow.mode == .activate ? "メーカーの画面で認証を完了し、認証済みの表示を確認してから次へ進んでください。" : "未認証の表示は自動検出します。検出されない画面では、確認した状態を選んでください。")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                if let session = model.workflowSession, !session.classID.isEmpty {
                    statusLine(session)
                    if workflow.mode == .activate {
                        Button("認証できたので次へ") { model.finishWorkflowItem(as: .activated) }
                            .buttonStyle(.borderedProminent).disabled(!model.licenseError.isEmpty)
                    } else {
                        HStack {
                            Button("未認証として次へ") { model.finishWorkflowItem(as: .needsActivation) }
                            Button("認証済みとして次へ") { model.finishWorkflowItem(as: .activated) }
                            Button("認証不要として次へ") { model.finishWorkflowItem(as: .notRequired) }
                        }.disabled(!model.licenseError.isEmpty)
                    }
                } else {
                    Text("製品の画面が開くまでお待ちください。同梱製品の選択画面が出たら製品を選んでください。")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                HStack {
                    if let session = model.workflowSession, session.isRunning {
                        Button("プラグイン画面を表示") {
                            NSRunningApplication(processIdentifier: session.process.processIdentifier)?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                        }
                    } else { Button("この製品を開き直す", action: model.launchWorkflowItem) }
                    Button("あとで・次へ") { model.finishWorkflowItem() }
                }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(accent.opacity(0.09)).cornerRadius(12)
    }

    @ViewBuilder func statusLine(_ session: HostSession) -> some View {
        if let record = model.records(for: session.entry).first(where: { $0.classID == session.classID }) {
            Text("\(record.status.title)・\(record.source.title)・\(record.checkedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 11)).foregroundColor(record.status == .needsActivation ? .orange : .secondary)
        } else { Text("未確認（画面が開いただけでは認証済みになりません）").font(.system(size: 11)).foregroundColor(.secondary) }
    }

    func recordButtons(_ session: HostSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            statusLine(session)
            HStack {
                Button("未認証を記録") { model.mark(session, as: .needsActivation) }
                Button("認証済みを記録") { model.mark(session, as: .activated) }
                Button("認証不要を記録") { model.mark(session, as: .notRequired) }
            }.font(.system(size: 11)).disabled(!model.licenseError.isEmpty || session.stopping)
        }
    }

    @ViewBuilder func detail(_ e: Entry) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(e.vendor.isEmpty ? e.format : e.vendor).font(.system(size: 12, weight: .medium)).foregroundColor(accent)
                    Text(model.selectedRecord?.productName ?? e.name).font(.system(size: 25, weight: .bold)).textSelection(.enabled)
                }
                Spacer()
                Button { model.toggleFavorite(e) } label: {
                    Image(systemName: model.favorites.contains(e.id) ? "star.fill" : "star").font(.system(size: 18))
                }.buttonStyle(.plain).foregroundColor(model.favorites.contains(e.id) ? .yellow : .secondary).help("お気に入り")
                    .accessibilityLabel(model.favorites.contains(e.id) ? "お気に入りから削除" : "お気に入りに追加")
                    .accessibilityValue(model.favorites.contains(e.id) ? "登録済み" : "未登録")
            }
            HStack(spacing: 9) {
                Text(e.format).fontWeight(.semibold)
                if !e.version.isEmpty { Text(e.version.lowercased().hasPrefix("v") ? e.version : "v" + e.version) }
                if e.format != "APP" {
                    Text(e.architectures.contains("arm64") && e.architectures.contains("x86_64") ? "Universal" : e.architectures.joined(separator: " / "))
                }
            }.font(.system(size: 11)).foregroundColor(.secondary)
            Divider()
            if e.format == "VST3" && !e.aliases.isEmpty {
                Text("同梱のプラグイン: " + e.aliases.joined(separator: "、"))
                    .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if e.format == "APP" {
                Text("メーカーの管理アプリを開きます。サインインやライセンスの有効化は、そのアプリで行ってください。")
                    .foregroundColor(.secondary).lineSpacing(5)
                Button("認証アプリを開く") { model.open(e) }.buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                Text("プラグイン本体の画面を開きます。認証画面が自動で出ない場合は、Activate / Register / License などのメニューを選んでください。")
                    .foregroundColor(.secondary).lineSpacing(5)
                Picker("実行方式", selection: $model.architecture) {
                    Text("自動").tag("自動"); Text("Apple Silicon").tag("Apple Silicon"); Text("Intel (Rosetta)").tag("Intel (Rosetta)")
                }.frame(maxWidth: 330).help("通常は自動。Intel専用プラグインはRosettaで開きます。")
                HStack(spacing: 10) {
                    Button("プラグイン画面を開く") { model.open(e, classID: model.selectedRecord?.classID ?? "") }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.workflow != nil)
                    if let manager = model.managerFor(e) {
                        Button("メーカーアプリ") { model.openManager(manager) }.controlSize(.large).help(manager.name)
                    }
                }
                Text("音声・MIDIデバイスは接続しません。読み込みが止まった場合は、下の「終了」でこのプラグインだけを停止できます。")
                    .font(.system(size: 11)).foregroundColor(.secondary).lineSpacing(3)
                ForEach(model.records(for: e)) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.productName + ": " + record.status.title)
                            Text(record.source.title + "・" + record.checkedAt.formatted(date: .abbreviated, time: .shortened))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("未確認に戻す") { model.forget(record) }.disabled(model.workflow != nil)
                    }.font(.system(size: 11))
                }
            }
            DisclosureGroup("ファイルの場所") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(e.path).font(.system(size: 10)).foregroundColor(.secondary).textSelection(.enabled)
                    Button("Finderで表示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: e.path)]) }
                }.padding(.top, 8)
            }.font(.system(size: 11)).foregroundColor(.secondary)
        }
    }
    func showHelp() {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/使い方.md")
        NSWorkspace.shared.open(path)
    }
}

struct AutomaticScanPanel: View {
    @ObservedObject var scanner: AutomaticScanner
    let start: () -> Void
    let resume: () -> Void
    let mayStart: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Label("全プラグインの自動チェック", systemImage: "sparkle.magnifyingglass").font(.system(size: 13, weight: .semibold))
                Spacer()
                if scanner.isBusy {
                    Button(scanner.isStopping ? "停止処理中…" : "一時停止") { scanner.pause() }.disabled(scanner.isStopping)
                } else if scanner.canResume {
                    Button("続きから再開", action: resume).buttonStyle(.borderedProminent).disabled(!mayStart)
                } else {
                    Button("未確認をすべて自動チェック", action: start).buttonStyle(.borderedProminent)
                        .disabled(!mayStart || !scanner.error.isEmpty)
                }
                if !scanner.results.isEmpty {
                    Button("結果CSV") {
                        if scanner.writeReport() { NSWorkspace.shared.open(scanner.reportURL) }
                    }
                }
            }
            if scanner.totalCount > 0 {
                HStack {
                    Text("\(scanner.completedCount) / \(scanner.totalCount) 件チェック済み")
                    Text("未認証 \(scanner.unactivatedCount) 件 · 判定不可・読込失敗 \(scanner.inconclusiveCount) 件")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(scanner.isComplete ? "完了" : scanner.isStopping ? "停止中" : scanner.isRunning ? "実行中（最大2件）" : "一時停止")
                }.font(.system(size: 11))
                ProgressView(value: Double(scanner.completedCount), total: Double(max(1, scanner.totalCount)))
                if scanner.isRunning {
                    Text(scanner.runs.compactMap { $0.current.map { $0.productName + " (" + $0.entry.format + ")" } }.joined(separator: " ／ "))
                        .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                }
            }
            if !scanner.error.isEmpty {
                HStack {
                    Text(scanner.error).foregroundColor(.red).textSelection(.enabled)
                    Button("記録を再読み込み") { scanner.reload() }.disabled(scanner.hasActiveHosts)
                }.font(.system(size: 11))
            } else {
                Text(scanner.message.isEmpty ? "検索や形式の絞り込みに関係なく未確認の全製品を調べます。1件ずつの操作は不要です。判定できない製品を認証済みとは扱いません。" : scanner.message)
                    .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.horizontal, 24).padding(.vertical, 12)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var model: DeskModel!
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        model = DeskModel()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1090, height: 750),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Plugin Auth Desk"
        window.minSize = NSSize(width: 960, height: 670)
        window.contentView = NSHostingView(rootView: DeskView(model: model))
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("PluginAuthDeskMainWindow")
        window.makeKeyAndOrderFront(nil)
        buildMenu()
        NSApp.activate(ignoringOtherApps: true)
    }
    func buildMenu() {
        let main = NSMenu()
        let app = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Plugin Auth Deskについて", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Plugin Auth Deskを終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = appMenu; main.addItem(app)
        let edit = NSMenuItem(title: "編集", action: nil, keyEquivalent: ""); let em = NSMenu(title: "編集")
        for (title, selector, key) in [("取り消す", "undo:", "z"), ("カット", "cut:", "x"), ("コピー", "copy:", "c"), ("ペースト", "paste:", "v"), ("すべて選択", "selectAll:", "a")] {
            em.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        edit.submenu = em; main.addItem(edit); NSApp.mainMenu = main
    }
    @objc func about() {
        let alert = NSAlert()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "バージョン不明"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        alert.messageText = "Plugin Auth Desk " + version + (build.map { " (build \($0))" } ?? "")
        alert.informativeText = "このMac向けのプラグイン認証ランチャー。\nVST3 / AU\nランチャー: Apple Silicon\nプラグインホスト: Apple Silicon / Intel\n\nホスト: JUCE 9.0.2 (AGPLv3)\nソース・ライセンスはアプリ内のResourcesに同梱しています。"
        alert.runModal()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = model else { return .terminateNow }
        model.shutdown { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil); return true
    }
}

// A read-only inventory command provides reproducible verification without GUI
// automation or loading any plug-in binary.
if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--inventory" {
    let start = Date()
    let entries = Inventory.scan()
    let managers = Inventory.managers()
    let output = try JSONEncoder().encode(entries + managers)
    try output.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
    print("plugins=\(entries.count) managers=\(managers.count) seconds=\(Date().timeIntervalSince(start))")
    exit(0)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
