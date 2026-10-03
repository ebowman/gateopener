import Foundation
import Testing
import UIKit
import UserNotifications
@testable import GateOpener

@MainActor
@Suite struct OpenResultNotificationHandlerTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private final class Probe {
        var sources: [String] = []
        var hostBeginsAtFlow = 0
        var hostEndsAtFlow = 0
    }

    private func make(
        pressedAt: Date?, action: String = OpenResultNotifier.retryActionIdentifier, age: TimeInterval,
        flowDelay: Duration = .zero
    ) async -> (probe: Probe, host: FakeBackgroundTaskHost, notifier: FakeNotifier) {
        let probe = Probe()
        let host = FakeBackgroundTaskHost()
        let notifier = FakeNotifier()
        let handler = OpenResultNotificationHandler(
            now: { [t0] in t0.addingTimeInterval(age) },
            runFlow: { source in
                probe.sources.append(source)
                probe.hostBeginsAtFlow = host.beginCallCount
                probe.hostEndsAtFlow = host.endCallCount
                try? await Task.sleep(for: flowDelay)
            },
            host: host, notifier: notifier
        )
        var info: [AnyHashable: Any] = [:]
        if let pressedAt { info[OpenResultNotifier.pressedAtUserInfoKey] = pressedAt.timeIntervalSince1970 }
        await handler.handle(actionIdentifier: action, userInfo: info)
        return (probe, host, notifier)
    }

    @Test func freshRetryRunsFlowOnceWithRetrySource() async {
        let r = await make(pressedAt: t0, age: 30)
        #expect(r.probe.sources == ["notification-retry"])
        #expect(r.notifier.expiredCount == 0)
    }

    @Test func staleRetryDoesNotOpenAndPostsExpiry() async {
        let r = await make(pressedAt: t0, age: 6 * 60)
        #expect(r.probe.sources.isEmpty)
        #expect(r.notifier.expiredCount == 1)
        #expect(r.host.beginCallCount == 0)
    }

    @Test func missingPressedAtDoesNotOpenAndPostsExpiry() async {
        let r = await make(pressedAt: nil, age: 1)
        #expect(r.probe.sources.isEmpty)
        #expect(r.notifier.expiredCount == 1)
    }

    @Test func defaultTapDoesNothing() async {
        let r = await make(pressedAt: t0, action: UNNotificationDefaultActionIdentifier, age: 1)
        #expect(r.probe.sources.isEmpty)
        #expect(r.notifier.expiredCount == 0)
        #expect(r.host.beginCallCount == 0)
    }

    @Test func backgroundTaskBracketsTheFlow() async {
        let r = await make(pressedAt: t0, age: 1, flowDelay: .milliseconds(50))
        #expect(r.probe.hostBeginsAtFlow == 1)
        #expect(r.probe.hostEndsAtFlow == 0)
        #expect(r.host.beginCallCount == 1)
        #expect(r.host.endCallCount == 1)
    }

    @Test func expirationHandlerEndsTaskSynchronouslyExactlyOnce() async {
        let host = FakeBackgroundTaskHost()
        let notifier = FakeNotifier()
        let flowStarted = AsyncStream<Void>.makeStream()
        let flowGate = AsyncStream<Void>.makeStream()
        let handler = OpenResultNotificationHandler(
            now: { [t0] in t0.addingTimeInterval(1) },
            runFlow: { _ in
                flowStarted.continuation.yield()
                for await _ in flowGate.stream { break }
            },
            host: host, notifier: notifier
        )
        let info: [AnyHashable: Any] = [OpenResultNotifier.pressedAtUserInfoKey: t0.timeIntervalSince1970]
        var completions = 0
        let task = Task { @MainActor in
            await handler.handle(actionIdentifier: OpenResultNotifier.retryActionIdentifier, userInfo: info)
            completions += 1
        }
        for await _ in flowStarted.stream { break }
        #expect(host.beginCallCount == 1)
        #expect(host.endCallCount == 0)

        // Fire expiration while the flow is still running; end must have
        // happened by the time the handler returns (no async hop).
        host.lastExpirationHandler?()
        #expect(host.endCallCount == 1)
        #expect(completions == 0)

        // Flow later finishes: no second end, completion happens once.
        flowGate.continuation.yield()
        await task.value
        #expect(host.endCallCount == 1)
        #expect(completions == 1)
    }

    @Test func handleReturnsOnlyAfterFlowCompletes() async {
        let start = Date()
        _ = await make(pressedAt: t0, age: 1, flowDelay: .milliseconds(200))
        #expect(Date().timeIntervalSince(start) >= 0.19)
    }

    @Test func foregroundPresentationShowsBannerSoundList() {
        #expect(OpenResultNotificationHandler.foregroundPresentationOptions == [.banner, .sound, .list])
    }
}
