// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

// UI state is separate from the plug-in's last status report. A plug-in may
// fail to load while its error window is still running, then exit later.
struct SessionLifecycle: Equatable {
    let startedAt: Date
    var displayName: String
    private(set) var isRunning = true
    private(set) var stopping = false
    private(set) var state = "loading"
    private(set) var message = "選択したプラグインを読み込み中"
    private(set) var failure: String?

    init(name: String, startedAt: Date = Date()) {
        self.displayName = name
        self.startedAt = startedAt
    }

    mutating func receive(_ report: [String: Any], heartbeat: Date?, now: Date = Date()) {
        guard isRunning else { return }
        if let name = report["name"] as? String, !name.isEmpty { displayName = name }
        if let error = report["error"] as? String, !error.isEmpty { failure = String(error.prefix(2048)) }
        let phase = report["state"] as? String ?? "loading"
        if phase == "error", let error = report["message"] as? String, !error.isEmpty {
            failure = String(error.prefix(2048))
        }
        guard !stopping else { return }
        state = phase
        switch phase {
        case "ready": message = "画面を開きました • 認証状態はプラグイン内で確認"
        case "selecting": message = "別ウインドウでバンドル内のプラグインを選択"
        case "error": message = "読み込みエラー: " + (failure ?? "メーカーのアプリまたは別形式をお試しください。")
        case "closed", "stopping":
            state = "closing"
            message = "プラグインを終了処理中…"
        default:
            state = "loading"
            message = "読み込み中（\(max(0, Int(now.timeIntervalSince(startedAt))))秒）"
        }
        if ["ready", "selecting", "loading"].contains(state), let heartbeat = heartbeat,
           now.timeIntervalSince(heartbeat) > 8 {
            state = "waiting"
            message = "画面の応答を待っています。認証ダイアログを確認するか「終了」で停止してください。"
        } else if state == "loading" && now.timeIntervalSince(startedAt) > 30 {
            message = "読み込みに時間がかかっています。認証ダイアログを確認するか「終了」で停止してください。"
        }
    }

    mutating func requestStop() {
        guard isRunning, !stopping else { return }
        stopping = true
        state = "closing"
        message = "プラグインを終了中…"
    }

    mutating func exited(code: Int32) {
        guard isRunning else { return }
        let requested = stopping
        isRunning = false
        stopping = false
        if !requested && code != 0 && failure == nil {
            failure = "プラグインが予期せず終了しました（コード \(code)）。別形式・実行方式をお試しください。"
        }
        state = failure == nil ? "closed" : "error"
        message = failure.map { "終了済み • " + $0 } ?? "終了しました"
    }
}
