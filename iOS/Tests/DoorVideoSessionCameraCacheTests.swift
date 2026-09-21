import Foundation
import Testing
import GateOpenerCore
@testable import GateOpener

/// Tests for bead gateopener-41m.19: caching the door-camera endpoint id so
/// a second and later video session in the same install performs ZERO
/// discovery requests, and a discovery FAILURE is never misreported as "No
/// camera".
///
/// Covers two independently-testable pure seams:
///  - `DoorVideoSession.resolveCameraEndpointId(cachedId:cachedEndpoints:
///    discover:persist:)` — the ordering/persistence policy, with no
///    network or `WKWebView` involved.
///  - `DoorVideoSession.shouldInvalidateCachedCamera(forHTTPStatus:)` — the
///    stale-cache self-heal decision for a `rtc/offer` HTTP status.
@MainActor
struct DoorVideoSessionCameraCacheTests {
    private let cameraEndpoint = Endpoint(
        endpointId: "apt_VIP#EN#SB100001",
        friendlyName: "Entry camera"
    )
    private let gateEndpoint = Endpoint(
        endpointId: "apt_LOCK#1",
        friendlyName: "Front Gate",
        capabilities: ["PowerController"],
        displayCategories: ["LOCK_GENERIC"]
    )

    /// Thread-safe call counter, mirroring `TestDoubles.swift`'s
    /// `LockedCounter` (kept local so this file has no dependency ordering
    /// on that file's private types).
    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        func increment() {
            lock.lock(); defer { lock.unlock() }
            _count += 1
        }
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return _count
        }
    }

    /// Thread-safe recorder of the single `String` a test's `persist`
    /// closure was called with (or never called).
    private final class PersistRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [String] = []
        func record(_ value: String) {
            lock.lock(); defer { lock.unlock() }
            _values.append(value)
        }
        var values: [String] {
            lock.lock(); defer { lock.unlock() }
            return _values
        }
    }

    private enum FakeDiscoverError: Error, Equatable {
        case boom
    }

    // MARK: - cached id present -> zero discover calls

    /// A non-nil `cachedId` is returned IMMEDIATELY: `discover` must never be
    /// invoked, and `persist` must never be invoked (nothing changed, so
    /// nothing needs re-persisting). This is the core fix for the bead's
    /// field report -- a SECOND (and later) video session in the same
    /// install must perform ZERO discovery requests.
    ///
    /// MUTATION CHECK: if the seam checked `cachedEndpoints` before
    /// `cachedId`, or called `discover` unconditionally, `discoverCalls.count`
    /// would become 1 instead of 0.
    @Test func cachedIdPresentReturnsImmediatelyWithZeroDiscoverCalls() async throws {
        let discoverCalls = CallCounter()
        let persisted = PersistRecorder()

        let result = try await DoorVideoSession.resolveCameraEndpointId(
            cachedId: "cached-camera-id",
            cachedEndpoints: [],
            discover: {
                discoverCalls.increment()
                return []
            },
            persist: { persisted.record($0) }
        )

        #expect(result == "cached-camera-id")
        #expect(discoverCalls.count == 0)
        #expect(persisted.values.isEmpty)
    }

    // MARK: - cache miss -> exactly one discover call, persisted

    /// `cachedId == nil` and `cachedEndpoints` has no camera match: falls
    /// through to `discover`, which finds a camera -- `discover` is called
    /// exactly once, and the found id is persisted before returning.
    ///
    /// MUTATION CHECK: if `persist` were never called on a successful live
    /// discovery, `persisted.values` would stay empty.
    @Test func cacheMissCallsDiscoverExactlyOnceAndPersistsResult() async throws {
        let discoverCalls = CallCounter()
        let persisted = PersistRecorder()

        let result = try await DoorVideoSession.resolveCameraEndpointId(
            cachedId: nil,
            cachedEndpoints: [gateEndpoint],
            discover: {
                discoverCalls.increment()
                return [gateEndpoint, cameraEndpoint]
            },
            persist: { persisted.record($0) }
        )

        #expect(result == cameraEndpoint.endpointId)
        #expect(discoverCalls.count == 1)
        #expect(persisted.values == [cameraEndpoint.endpointId])
    }

    /// `cachedEndpoints` (the `appSettings.cachedGates` fallback) already
    /// contains a camera match: returned immediately, with `discover` never
    /// called. Documents the harmless-but-currently-dead second check in the
    /// ordering (see the seam's doc comment on why this can't happen with
    /// today's `candidateGates` filtering, but is kept as a cheap, no-cost
    /// fallback).
    @Test func cachedEndpointsMatchIsUsedBeforeLiveDiscovery() async throws {
        let discoverCalls = CallCounter()
        let persisted = PersistRecorder()

        let result = try await DoorVideoSession.resolveCameraEndpointId(
            cachedId: nil,
            cachedEndpoints: [gateEndpoint, cameraEndpoint],
            discover: {
                discoverCalls.increment()
                return []
            },
            persist: { persisted.record($0) }
        )

        #expect(result == cameraEndpoint.endpointId)
        #expect(discoverCalls.count == 0)
        #expect(persisted.values.isEmpty)
    }

    // MARK: - no camera anywhere -> throws cameraNotFound, nothing persisted

    /// Live discovery succeeds but returns no camera match: throws
    /// `DoorVideoSessionError.cameraNotFound`, and `persist` is never called
    /// -- an existing (stale) cached value, if any, must be left untouched
    /// by a "no camera this time" result.
    ///
    /// MUTATION CHECK: if the "no match" branch persisted an empty string or
    /// otherwise called `persist`, `persisted.values` would be non-empty.
    @Test func discoveryWithNoCameraMatchThrowsCameraNotFoundAndPersistsNothing() async {
        let persisted = PersistRecorder()

        await #expect(throws: DoorVideoSessionError.cameraNotFound) {
            _ = try await DoorVideoSession.resolveCameraEndpointId(
                cachedId: nil,
                cachedEndpoints: [],
                discover: { [gateEndpoint] },
                persist: { persisted.record($0) }
            )
        }

        #expect(persisted.values.isEmpty)
    }

    // MARK: - discover throws -> propagates, nothing persisted

    /// `discover` itself throws (network/server/token failure): the error
    /// propagates UNCHANGED to the caller, and `persist` is never called.
    /// This is the seam `start()`'s error mapping (STEP 4) relies on to
    /// distinguish "no camera" from "failed to find out".
    ///
    /// MUTATION CHECK: if the seam swallowed `discover`'s error and threw
    /// `cameraNotFound` instead, the `#expect(throws:)` below would fail
    /// (wrong error type) even though something was still thrown.
    @Test func discoverThrowingPropagatesErrorAndPersistsNothing() async {
        let persisted = PersistRecorder()

        await #expect(throws: FakeDiscoverError.boom) {
            _ = try await DoorVideoSession.resolveCameraEndpointId(
                cachedId: nil,
                cachedEndpoints: [],
                discover: { throw FakeDiscoverError.boom },
                persist: { persisted.record($0) }
            )
        }

        #expect(persisted.values.isEmpty)
    }

    // MARK: - shouldInvalidateCachedCamera(forHTTPStatus:)

    /// `404` (endpoint unknown) must invalidate the cache.
    @Test func status404InvalidatesCache() {
        #expect(DoorVideoSession.shouldInvalidateCachedCamera(forHTTPStatus: 404) == true)
    }

    /// `410` (endpoint gone) is treated identically to 404 per this bead's
    /// brief.
    @Test func status410InvalidatesCache() {
        #expect(DoorVideoSession.shouldInvalidateCachedCamera(forHTTPStatus: 410) == true)
    }

    /// `500` (door busy -- a normal transient condition per
    /// `DoorVideoBusyPolicy`) must NOT invalidate the cache: the endpoint id
    /// itself is still valid, the door is just refusing a new session right
    /// now.
    ///
    /// MUTATION CHECK: if `shouldInvalidateCachedCamera` invalidated on ANY
    /// non-2xx status, this would wrongly become `true`, and a normal
    /// busy-door retry loop would keep re-discovering for no reason.
    @Test func status500DoesNotInvalidateCache() {
        #expect(DoorVideoSession.shouldInvalidateCachedCamera(forHTTPStatus: 500) == false)
    }

    /// A `nil` status (timeout/network failure, never reached the door) must
    /// NOT invalidate the cache -- it says nothing about the endpoint id's
    /// validity.
    @Test func nilStatusDoesNotInvalidateCache() {
        #expect(DoorVideoSession.shouldInvalidateCachedCamera(forHTTPStatus: nil) == false)
    }

    /// An unrelated 4xx/5xx status (e.g. 401/403 unauthorized, or a generic
    /// 502) must NOT invalidate the cache -- only 404/410 do.
    @Test func otherStatusesDoNotInvalidateCache() {
        #expect(DoorVideoSession.shouldInvalidateCachedCamera(forHTTPStatus: 401) == false)
        #expect(DoorVideoSession.shouldInvalidateCachedCamera(forHTTPStatus: 403) == false)
        #expect(DoorVideoSession.shouldInvalidateCachedCamera(forHTTPStatus: 502) == false)
    }
}
