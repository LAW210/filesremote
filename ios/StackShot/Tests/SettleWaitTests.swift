import XCTest
@testable import StackShot

/// The settle poll loop, which `CameraService` uses to wait for metering to stop hunting
/// and for the lens to reach a target before a frame is shot.
///
/// These assertions exist because the loop's worst failure is invisible from the outside:
/// it does not produce a wrong value, it produces the right one while burning a core. That
/// happened for real — both waits slept with `try? await Task.sleep(...)`, and because
/// `Task.sleep` throws *immediately* on a cancelled task, swallowing the throw left the
/// deadline as the only brake. A cancelled settle then stopped sleeping and spun as fast as
/// it could read a device property for the rest of its 1.5 s budget, on a tripod-mounted
/// phone sealed in a light box. `CameraService` itself can only run on a device, which is
/// why the loop was extracted to be reachable from here at all.
final class SettleWaitTests: XCTestCase {

    /// A deadline far enough out that nothing here reaches it by accident. Every test that
    /// wants a timeout asks for one explicitly instead.
    private var farDeadline: Date { Date().addingTimeInterval(60) }

    // MARK: - Cancellation

    /// The regression. A tick reporting "stop" must end the wait immediately, rather than
    /// letting the deadline run down without sleeping.
    ///
    /// Asserting on the *sample count* is the whole point: a wait that returns `false`
    /// proves nothing on its own, because a timeout returns `false` too. The bug was never
    /// about the return value — it was about how many times the loop went round to get
    /// there. One sample, then stop.
    func testATickThatReportsStopEndsTheWaitInsteadOfSpinning() async {
        var samples = 0
        var ticks = 0

        let settled = await SettleWait.poll(
            deadline: farDeadline,
            tick: {
                ticks += 1
                return false        // what a cancelled Task.sleep reports
            },
            isSettled: {
                samples += 1
                return false        // never settles, so only the tick can stop this
            })

        XCTAssertFalse(settled, "a wait that was told to stop has not settled")
        XCTAssertEqual(ticks, 1, "the loop must not tick again after being told to stop")
        XCTAssertEqual(samples, 1,
                       "one sample, then out — the pre-fix loop spun here until the deadline")
    }

    /// The same guarantee through the real production tick, rather than a hand-written one:
    /// a cancelled task must make `sleepTick` report stop. This is what connects the loop's
    /// contract to `Task.sleep`'s actual cancellation behaviour, which is the mechanism the
    /// bug turned on. A `try?` swallowing that throw would make this return true.
    func testSleepTickReportsStopOnACancelledTask() async {
        let task = Task { () -> Bool in
            await SettleWait.sleepTick(nanoseconds: 5_000_000_000)
        }
        task.cancel()
        let keptWaiting = await task.value

        XCTAssertFalse(keptWaiting,
                       "a cancelled sleep must be reported as stop, not swallowed as success")
    }

    /// And the tick must report *continue* when nothing is cancelled, or the loop above
    /// would exit on its first pass and every settle in the app would silently give up.
    /// Without this the previous test would pass against a `sleepTick` hardcoded to false.
    func testSleepTickReportsContinueWhenNotCancelled() async {
        let kept = await SettleWait.sleepTick(nanoseconds: 1_000)
        XCTAssertTrue(kept)
    }

    // MARK: - Settling

    /// Stability must be consecutive. The loop requires N in a row specifically so a value
    /// passing *through* the target is not mistaken for arrival — which for focus is the
    /// difference between shooting a frame at the planned distance and shooting it mid-rack.
    func testAWobbleResetsTheCountRatherThanDecrementingIt() async {
        // settled, settled, NOT settled, then settled forever. With a reset, the run of
        // three only completes after the wobble. With a decrement, it would complete one
        // sample earlier — which is exactly the bug this shape exists to prevent.
        let pattern = [true, true, false, true, true, true]
        var index = 0
        var samples = 0

        let settled = await SettleWait.poll(
            stableTicksRequired: 3,
            deadline: farDeadline,
            tick: { true },
            isSettled: {
                samples += 1
                defer { index += 1 }
                return index < pattern.count ? pattern[index] : true
            })

        XCTAssertTrue(settled)
        XCTAssertEqual(samples, 6,
                       "the run of three must restart after the wobble, not resume from two")
    }

    /// The ordinary case: three consecutive stable samples and it reports settled, without
    /// waiting out the deadline.
    func testThreeConsecutiveStableSamplesSettle() async {
        var samples = 0
        let settled = await SettleWait.poll(
            stableTicksRequired: 3,
            deadline: farDeadline,
            tick: { true },
            isSettled: {
                samples += 1
                return true
            })

        XCTAssertTrue(settled)
        XCTAssertEqual(samples, 3, "it must return on the third sample, not keep polling")
    }

    // MARK: - The deadline

    /// A deadline already in the past must not sample at all. The clock is injected so this
    /// is exact rather than a race against real time.
    func testAnExpiredDeadlineReturnsWithoutSampling() async {
        var samples = 0
        let now = Date()

        let settled = await SettleWait.poll(
            deadline: now,
            now: { now },
            tick: {
                XCTFail("an expired deadline must not tick")
                return true
            },
            isSettled: {
                samples += 1
                return true
            })

        XCTAssertFalse(settled)
        XCTAssertEqual(samples, 0)
    }

    /// A value that never settles ends at the deadline reporting false — the `settle=timeout`
    /// the capture log records. Driven by an injected clock that advances per tick, so the
    /// test neither sleeps nor depends on machine speed.
    ///
    /// The virtual clock steps by whole seconds deliberately. Ten steps of 0.01 do not sum
    /// to exactly 0.1 in binary floating point, so a sub-second step could leave the clock a
    /// hair under the deadline after the last one and buy an eleventh sample — a test that
    /// fails once in a while for a reason that has nothing to do with the code under test.
    /// 1.0 and 10.0 are both exact, so this comparison is not a coin flip.
    func testAValueThatNeverSettlesTimesOutAtTheDeadline() async {
        let start = Date()
        var current = start
        let deadline = start.addingTimeInterval(10)      // 10 ticks of 1 virtual second
        var samples = 0

        let settled = await SettleWait.poll(
            deadline: deadline,
            now: { current },
            tick: {
                current = current.addingTimeInterval(1)
                return true
            },
            isSettled: {
                samples += 1
                return false
            })

        XCTAssertFalse(settled)
        XCTAssertEqual(samples, 10, "it polls until the deadline and then stops, exactly once each")
    }
}
