import XCTest
@testable import StackShot

final class AspectFitTests: XCTestCase {

    private let accuracy: CGFloat = 0.0001

    private func assertRect(_ rect: CGRect,
                            _ expected: CGRect,
                            file: StaticString = #filePath,
                            line: UInt = #line) {
        XCTAssertEqual(rect.minX, expected.minX, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(rect.minY, expected.minY, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(rect.width, expected.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(rect.height, expected.height, accuracy: accuracy, file: file, line: line)
    }

    /// A 4:3 camera image in a tall phone viewfinder: bars above and below.
    func testWideImageInTallViewLetterboxes() {
        let rect = CGRect.aspectFit(CGSize(width: 400, height: 300),
                                    in: CGSize(width: 400, height: 800))
        assertRect(rect, CGRect(x: 0, y: 250, width: 400, height: 300))
    }

    /// The portrait-oriented buffer case: bars left and right.
    func testTallImageInWideViewPillarboxes() {
        let rect = CGRect.aspectFit(CGSize(width: 300, height: 400),
                                    in: CGSize(width: 800, height: 400))
        assertRect(rect, CGRect(x: 250, y: 0, width: 300, height: 400))
    }

    func testMatchingAspectFillsTheViewExactly() {
        let rect = CGRect.aspectFit(CGSize(width: 1200, height: 1600),
                                    in: CGSize(width: 300, height: 400))
        assertRect(rect, CGRect(x: 0, y: 0, width: 300, height: 400))
    }

    func testFittedRectIsAlwaysCenteredInTheView() {
        let view = CGSize(width: 390, height: 844)
        for image in [CGSize(width: 4032, height: 3024),
                      CGSize(width: 3024, height: 4032),
                      CGSize(width: 1000, height: 1000)] {
            let rect = CGRect.aspectFit(image, in: view)
            XCTAssertEqual(rect.midX, view.width / 2, accuracy: accuracy)
            XCTAssertEqual(rect.midY, view.height / 2, accuracy: accuracy)
        }
    }

    func testAspectRatioIsPreserved() {
        let image = CGSize(width: 4032, height: 3024)
        let rect = CGRect.aspectFit(image, in: CGSize(width: 390, height: 844))
        XCTAssertEqual(rect.width / rect.height, image.width / image.height, accuracy: accuracy)
    }

    func testFittedRectNeverExceedsTheView() {
        let view = CGSize(width: 390, height: 844)
        let rect = CGRect.aspectFit(CGSize(width: 8000, height: 200), in: view)
        XCTAssertLessThanOrEqual(rect.width, view.width + accuracy)
        XCTAssertLessThanOrEqual(rect.height, view.height + accuracy)
    }

    /// Guards the first frames after launch, when the viewfinder has laid out but no
    /// image has arrived: dividing by zero here would put NaN into the loupe mapping.
    func testZeroSizedImageReturnsZeroRatherThanNaN() {
        XCTAssertEqual(CGRect.aspectFit(.zero, in: CGSize(width: 390, height: 844)), .zero)
        XCTAssertEqual(CGRect.aspectFit(CGSize(width: 0, height: 300),
                                        in: CGSize(width: 390, height: 844)), .zero)
        XCTAssertEqual(CGRect.aspectFit(CGSize(width: 400, height: 0),
                                        in: CGSize(width: 390, height: 844)), .zero)
    }

    /// A zero-sized *view* is legal input (SwiftUI hands one out pre-layout) and must
    /// collapse to an empty rect rather than producing negative geometry.
    func testZeroSizedViewCollapsesToEmpty() {
        let rect = CGRect.aspectFit(CGSize(width: 400, height: 300), in: .zero)
        assertRect(rect, .zero)
    }
}
