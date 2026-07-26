import XCTest
@testable import StackShot

final class FocusBracketPlanTests: XCTestCase {

    func testInclusiveEndpoints() {
        let plan = FocusBracketController.Plan(near: 0.2, far: 0.9, stepCount: 8)
        let positions = plan.positions
        XCTAssertEqual(positions.first!, plan.near, accuracy: 1e-6)
        XCTAssertEqual(positions.last!, plan.far, accuracy: 1e-6)
    }

    func testCountAndEvenSpacingForEightSteps() {
        let plan = FocusBracketController.Plan(near: 0.1, far: 0.8, stepCount: 8)
        let positions = plan.positions
        XCTAssertEqual(positions.count, plan.stepCount)

        let expectedDelta = (plan.far - plan.near) / Float(plan.stepCount - 1)
        for i in 1..<positions.count {
            let delta = positions[i] - positions[i - 1]
            XCTAssertEqual(delta, expectedDelta, accuracy: 1e-5)
        }
    }

    func testStepCountOneReturnsOnlyNear() {
        let plan = FocusBracketController.Plan(near: 0.4, far: 0.9, stepCount: 1)
        let positions = plan.positions
        XCTAssertEqual(positions.count, 1)
        XCTAssertEqual(positions[0], 0.4, accuracy: 1e-6)
    }

    func testStepCountTwoReturnsNearAndFar() {
        let plan = FocusBracketController.Plan(near: 0.3, far: 0.7, stepCount: 2)
        let positions = plan.positions
        XCTAssertEqual(positions.count, 2)
        XCTAssertEqual(positions[0], 0.3, accuracy: 1e-6)
        XCTAssertEqual(positions[1], 0.7, accuracy: 1e-6)
    }

    func testReversedRangeIsMonotonicallyDecreasing() {
        let plan = FocusBracketController.Plan(near: 0.8, far: 0.2, stepCount: 6)
        let positions = plan.positions
        XCTAssertEqual(positions.first!, plan.near, accuracy: 1e-6)
        XCTAssertEqual(positions.last!, plan.far, accuracy: 1e-6)
        for i in 1..<positions.count {
            XCTAssertLessThan(positions[i], positions[i - 1])
        }
    }
}
