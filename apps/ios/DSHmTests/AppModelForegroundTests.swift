import XCTest
@testable import DSHm

/// task-2: `AppModel.foregroundAction` decision matrix, including the new
/// "network path changed since the last connect" input (handoff §2.3(1)/§2.4).
///
/// Acceptance guard: a connected link with a **short** background episode must
/// still reuse the mux (no teardown, no `connectOnce`) — the reconnect workstream
/// must not regress P0-5.
final class AppModelForegroundTests: XCTestCase {

    // MARK: - First activation / no background episode

    func testNoBackgroundEpisodeNeverActs() {
        XCTAssertEqual(
            AppModel.foregroundAction(phase: .connected, backgroundedSeconds: nil),
            .none
        )
        XCTAssertEqual(
            AppModel.foregroundAction(
                phase: .connected,
                backgroundedSeconds: nil,
                networkPathChanged: true
            ),
            .none,
            "a first activation cannot have a path change since the last connect"
        )
    }

    // MARK: - Connected: reuse unless the path changed

    func testConnectedShortBlipStillDoesNothing() {
        XCTAssertEqual(
            AppModel.foregroundAction(phase: .connected, backgroundedSeconds: 0.4),
            .none
        )
        XCTAssertEqual(
            AppModel.foregroundAction(
                phase: .connected,
                backgroundedSeconds: LinkServiceForegroundBoundary.boundary - 0.01
            ),
            .none
        )
    }

    func testConnectedRealResumeReusesMux() {
        XCTAssertEqual(
            AppModel.foregroundAction(phase: .connected, backgroundedSeconds: 8),
            .reuseMux
        )
        XCTAssertEqual(
            AppModel.foregroundAction(phase: .connected, backgroundedSeconds: 1),
            .reuseMux,
            "1s is the documented reuse boundary"
        )
    }

    func testConnectedButPathChangedReconnectsEvenAfterShortBlip() {
        // The socket was dialed on the previous network; the OS does not report it
        // dead. Reusing it would wait for the TCP timeout (the 10s+ failure mode).
        XCTAssertEqual(
            AppModel.foregroundAction(
                phase: .connected,
                backgroundedSeconds: 0.4,
                networkPathChanged: true
            ),
            .reconnect
        )
        XCTAssertEqual(
            AppModel.foregroundAction(
                phase: .connected,
                backgroundedSeconds: 8,
                networkPathChanged: true
            ),
            .reconnect
        )
    }

    // MARK: - Bringing up

    func testConnectingRoundIsNotRestartedWithoutAPathChange() {
        XCTAssertEqual(
            AppModel.foregroundAction(phase: .connecting, backgroundedSeconds: 8),
            .none,
            "an in-flight bring-up must not be cancelled and restarted (P0-5)"
        )
    }

    func testConnectingRoundIsRestartedWhenItPredatesAPathChange() {
        XCTAssertEqual(
            AppModel.foregroundAction(
                phase: .connecting,
                backgroundedSeconds: 8,
                networkPathChanged: true
            ),
            .reconnect,
            "a round dialing the old network must be retried on the new one"
        )
    }

    // MARK: - Transport already down

    func testDownTransportReconnectsImmediately() {
        XCTAssertEqual(
            AppModel.foregroundAction(phase: .disconnected, backgroundedSeconds: 8),
            .reconnect
        )
        XCTAssertEqual(
            AppModel.foregroundAction(phase: .reconnecting(attempt: 3), backgroundedSeconds: 8),
            .reconnect,
            "a resumed app must not wait out the 0.5-10s backoff"
        )
        XCTAssertEqual(
            AppModel.foregroundAction(
                phase: .reconnecting(attempt: 3),
                backgroundedSeconds: 8,
                networkPathChanged: true
            ),
            .reconnect
        )
    }

    // MARK: - Pairing states are user-driven

    func testPairingStatesNeverReconnectAutomatically() {
        for phase: LinkService.Phase in [.unpaired, .needsRepair("repair")] {
            XCTAssertEqual(
                AppModel.foregroundAction(phase: phase, backgroundedSeconds: 8),
                .none
            )
            XCTAssertEqual(
                AppModel.foregroundAction(
                    phase: phase,
                    backgroundedSeconds: 8,
                    networkPathChanged: true
                ),
                .none
            )
        }
    }
}

/// The documented "real background" boundary (`foregroundAction` reuses only after
/// >= 1s); kept as a named value so the matrix reads as the product rule.
private enum LinkServiceForegroundBoundary {
    static let boundary: TimeInterval = 1
}
