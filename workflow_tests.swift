// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

@main struct WorkflowTests {
    static func main() {
        let entry = Entry(id: "bundle", name: "Synth", vendor: "Acme", format: "VST3", path: "/tmp/Synth.vst3", identifier: "id", version: "1", architectures: ["arm64"], metadataStamp: "binary1")
        let a = ActivationTarget(entry: entry, classID: "synth1", productName: "Synth 1")
        let b = ActivationTarget(entry: entry, classID: "synth2", productName: "Synth 2")
        var q = ActivationWorkflow(mode: .activate, targets: [a, a, b])
        assert(q.targets.count == 2 && q.current?.classID == "synth1")
        let owned = UUID()
        q.sessionID = owned
        assert(!q.advance(afterExit: owned), "natural close must not activate or advance")
        q.requestAdvance()
        assert(!q.advance(afterExit: UUID()), "other session cannot advance the queue")
        assert(q.index == 0 && q.waitingForExit)
        assert(q.advance(afterExit: owned))
        assert(q.current?.classID == "synth2" && q.sessionID == nil && !q.waitingForExit)
        assert(!q.advance(afterExit: owned), "repeated termination cannot skip an item")
        q.requestAdvance()
        assert(q.advance(afterExit: nil), "launch failure can be explicitly skipped")
        assert(q.isFinished)

        let otherEntry = Entry(id: "another-bundle", name: "Other", vendor: "Acme", format: "VST3", path: "/tmp/Other.vst3", identifier: "other", version: "1", architectures: ["arm64"], metadataStamp: "other-binary")
        let root = ActivationTarget(entry: entry, classID: "", productName: "Synth bundle")
        let unrelated = ActivationTarget(entry: otherEntry, classID: "other-class", productName: "Other synth")
        var review = ActivationWorkflow(mode: .review, targets: [root, unrelated])
        review.includeUnconfirmedSiblings([a, a, b, unrelated])
        assert(review.targets.map(\.id) == [root.id, a.id, b.id, unrelated.id],
               "discover only this bundle's unconfirmed classes, once, before the next bundle")
        let expanded = review.targets.map(\.id)
        review.includeUnconfirmedSiblings([b, a])
        assert(review.targets.map(\.id) == expanded, "repeated polls must not reorder or duplicate work")
        let rootSession = UUID()
        review.sessionID = rootSession
        assert(!review.advance(afterExit: rootSession), "closing the review window alone does not confirm or advance")
        review.requestAdvance()
        review.requestAdvance()
        assert(review.advance(afterExit: rootSession), "double-next before exit remains one requested transition")
        assert(review.current?.id == a.id && review.index == 1)
        let classSession = UUID()
        review.sessionID = classSession
        review.requestAdvance()
        assert(!review.advance(afterExit: rootSession), "a late callback from the previous product cannot release the next product")
        assert(review.advance(afterExit: classSession) && review.current?.id == b.id)
        review.includeUnconfirmedSiblings([root, unrelated])
        assert(review.targets.map(\.id) == expanded, "a specific class does not expand its bundle again")

        var activation = ActivationWorkflow(mode: .activate, targets: [a, b])
        activation.includeUnconfirmedSiblings([root, unrelated])
        assert(activation.targets.map(\.id) == [a.id, b.id], "activation list never expands into unknown products")

        var selected = [a, b]
        let snapshot = ActivationWorkflow(mode: .activate, targets: selected)
        selected.reverse()
        selected.removeLast()
        assert(snapshot.targets.map(\.id) == [a.id, b.id], "later UI filtering/reordering must not mutate a running snapshot")

        let unicodeEntry = Entry(id: "synth|音", name: "音", vendor: "Acme", format: "AU", path: "/tmp/音.component", identifier: "au", version: "1", architectures: ["arm64"], metadataStamp: "au-binary")
        let unicodeA = ActivationTarget(entry: unicodeEntry, classID: "a:b", productName: "One")
        let unicodeB = ActivationTarget(entry: unicodeEntry, classID: "a", productName: "Two")
        assert(unicodeA.id != unicodeB.id && unicodeA.id != a.id, "queue keys distinguish Unicode paths, classes, and formats")
        print("PASS: workflow snapshot, class isolation, exit gating, explicit skip, double-next, late callbacks and bundle expansion")
    }
}
