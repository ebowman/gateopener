import Foundation
import Testing
@testable import GateOpener

/// Tests for `ReachabilityWaiter` (bead gateopener-6qa.2) and the intent's
/// press deadline constant.
struct ReachabilityWaiterTests {
    @Test func alreadyReachableReturnsTrueImmediately() async {
        let waiter = ReachabilityWaiter(initiallyReachable: true)
        let start = ContinuousClock.now
        let result = await waiter.wait(timeout: .seconds(10))
        #expect(result == true)
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(waiter.pendingWaitCount == 0)
    }

    @Test func satisfiedBeforeTimeoutReturnsTrueQuickly() async {
        let waiter = ReachabilityWaiter(initiallyReachable: false)
        let start = ContinuousClock.now
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            waiter.update(true)
        }
        let result = await waiter.wait(timeout: .seconds(10))
        #expect(result == true)
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(waiter.pendingWaitCount == 0)
    }

    @Test func timeoutReturnsFalseAndCleansUp() async {
        let waiter = ReachabilityWaiter(initiallyReachable: false)
        let start = ContinuousClock.now
        let result = await waiter.wait(timeout: .milliseconds(200))
        #expect(result == false)
        #expect(ContinuousClock.now - start >= .milliseconds(150))
        #expect(waiter.pendingWaitCount == 0)
    }

    @Test func repeatedWaitsDoNotAccumulateAndLateUpdateIsHarmless() async {
        let waiter = ReachabilityWaiter(initiallyReachable: false)
        for _ in 0..<5 {
            #expect(await waiter.wait(timeout: .milliseconds(30)) == false)
            #expect(waiter.pendingWaitCount == 0)
        }
        waiter.update(true)
        #expect(await waiter.wait(timeout: .seconds(5)) == true)
    }

    @Test func cancellationResolvesPromptly() async {
        let waiter = ReachabilityWaiter(initiallyReachable: false)
        let task = Task { await waiter.wait(timeout: .seconds(30)) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let start = ContinuousClock.now
        let result = await task.value
        #expect(result == false)
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(waiter.pendingWaitCount == 0)
    }
}
