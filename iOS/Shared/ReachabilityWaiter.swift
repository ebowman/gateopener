import Foundation

/// Lock-protected "wait until reachable, or time out" primitive, split out
/// of `NWPathMonitorReachability` so it is unit-testable without a real
/// `NWPathMonitor` (bead gateopener-6qa.2).
///
/// DESIGN
/// - It keeps its OWN waiter table and never touches
///   `NWPathMonitorReachability.setOnChange` (which REPLACES, not appends,
///   its single handler): waiting can therefore neither clobber a
///   `GateController` handler nor stack handlers across repeated waits.
/// - Every waiter is a `CheckedContinuation` stored under a UUID. It is
///   resumed exactly once because whoever resumes it (path update, timeout,
///   or cancellation) must first REMOVE it from the table under the lock.
/// - Each waiter's timeout timer is cancelled as soon as it is resolved, so
///   nothing lingers after `wait` returns.
///
/// THREADING: `update(_:)` is called from `NWPathMonitor`'s utility queue;
/// `wait(timeout:)` from any task. All state is guarded by `NSLock`;
/// continuations are resumed outside the lock.
final class ReachabilityWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var reachable: Bool
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var timers: [UUID: Task<Void, Never>] = [:]

    init(initiallyReachable: Bool = true) {
        reachable = initiallyReachable
    }

    var isReachable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reachable
    }

    /// Number of currently pending waits (test visibility: must return to 0).
    var pendingWaitCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    /// Feeds a new path status. A `true` update resumes every pending waiter
    /// with `true` and cancels their timers.
    func update(_ isReachable: Bool) {
        lock.lock()
        reachable = isReachable
        var resumed: [CheckedContinuation<Bool, Never>] = []
        var cancelled: [Task<Void, Never>] = []
        if isReachable {
            resumed = Array(waiters.values)
            cancelled = Array(timers.values)
            waiters.removeAll()
            timers.removeAll()
        }
        lock.unlock()
        cancelled.forEach { $0.cancel() }
        resumed.forEach { $0.resume(returning: true) }
    }

    /// Returns `true` immediately if already reachable; otherwise suspends
    /// until the path becomes reachable (`true`) or `timeout` elapses
    /// (`false`). Task cancellation resolves it promptly with the current
    /// reachability.
    func wait(timeout: Duration) async -> Bool {
        if isReachable { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                lock.lock()
                if reachable {
                    lock.unlock()
                    continuation.resume(returning: true)
                    return
                }
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: false)
                    return
                }
                waiters[id] = continuation
                timers[id] = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.resolve(id)
                }
                lock.unlock()
            }
        } onCancel: {
            self.resolve(id)
        }
    }

    /// Timeout/cancel path: remove (so no one else can resume) then resume
    /// with the current reachability. No-op if already resolved.
    private func resolve(_ id: UUID) {
        lock.lock()
        let continuation = waiters.removeValue(forKey: id)
        let timer = timers.removeValue(forKey: id)
        let current = reachable
        lock.unlock()
        timer?.cancel()
        continuation?.resume(returning: current)
    }
}
