// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

@main enum LifecycleTests {
    static func main() {
        let epoch = Date(timeIntervalSince1970: 1000)
        var s = SessionLifecycle(name: "Bundle", startedAt: epoch)
        s.receive(["state": "error", "message": "license app required"], heartbeat: epoch, now: epoch)
        precondition(s.isRunning && s.failure != nil)
        s.requestStop()
        s.receive(["state": "closed", "error": "license app required"], heartbeat: epoch, now: epoch)
        s.exited(code: 0)
        precondition(!s.isRunning && !s.stopping && s.message.contains("終了済み"), "error window must not remain stuck at closing")

        var ready = SessionLifecycle(name: "Bundle", startedAt: epoch)
        ready.receive(["state": "ready", "name": "Child instrument"], heartbeat: epoch, now: epoch)
        precondition(ready.displayName == "Child instrument" && ready.state == "ready")
        ready.receive(["state": "ready"], heartbeat: epoch, now: epoch.addingTimeInterval(9))
        precondition(ready.state == "waiting" && ready.isRunning)
        ready.receive(["state": "ready"], heartbeat: epoch.addingTimeInterval(10), now: epoch.addingTimeInterval(10))
        precondition(ready.state == "ready", "responsive plug-in must recover from stale heartbeat")
        ready.exited(code: 9)
        precondition(!ready.isRunning && ready.state == "error")
        ready.receive(["state": "ready"], heartbeat: epoch, now: epoch)
        precondition(!ready.isRunning && ready.state == "error", "late status cannot resurrect a dead child")

        var stopped = SessionLifecycle(name: "Test", startedAt: epoch)
        stopped.requestStop()
        stopped.exited(code: 15)
        precondition(stopped.state == "closed" && !stopped.stopping)
        var slow = SessionLifecycle(name: "Slow", startedAt: epoch)
        slow.receive([:], heartbeat: nil, now: epoch.addingTimeInterval(31))
        precondition(slow.message.contains("時間がかかって"))
        print("PASS: error-close transition, child name, stale/recovered heartbeat, crash, late report, explicit stop, slow startup")
    }
}
