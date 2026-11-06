// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

struct ActivationTarget: Identifiable {
    let entry: Entry
    let classID: String
    let productName: String
    var id: String { "\(entry.id.utf8.count):\(entry.id)\(classID.utf8.count):\(classID)" }
}

/// A fixed snapshot: filtering and newly recorded statuses never reorder a run.
/// Closing/crashing alone does not count as a completed activation.
struct ActivationWorkflow {
    enum Mode { case review, activate }
    let mode: Mode
    private(set) var targets: [ActivationTarget]
    private var expandedBundles = Set<String>()
    private(set) var index = 0
    var sessionID: UUID?
    private(set) var waitingForExit = false
    var current: ActivationTarget? { targets.indices.contains(index) ? targets[index] : nil }
    var isFinished: Bool { current == nil }

    init(mode: Mode, targets: [ActivationTarget]) {
        self.mode = mode
        var seen = Set<String>()
        self.targets = targets.filter { seen.insert($0.id).inserted }
    }

    mutating func requestAdvance() { waitingForExit = true }

    @discardableResult mutating func includeUnconfirmedSiblings(_ siblings: [ActivationTarget]) -> Bool {
        guard mode == .review, let current = current, current.classID.isEmpty,
              expandedBundles.insert(current.entry.id).inserted else { return false }
        var seen = Set(targets.map(\.id))
        let additions = siblings.filter { $0.entry.id == current.entry.id && seen.insert($0.id).inserted }
        targets.insert(contentsOf: additions, at: index + 1)
        return true
    }

    /// Only the retained session can release the next item. The caller confirms
    /// the owned Process has exited (or no process was launched for this item).
    @discardableResult mutating func advance(afterExit id: UUID?) -> Bool {
        guard waitingForExit, sessionID == id else { return false }
        index += 1
        sessionID = nil
        waitingForExit = false
        return true
    }
}
