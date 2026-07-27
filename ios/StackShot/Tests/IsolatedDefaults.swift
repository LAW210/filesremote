import Foundation
import XCTest
@testable import StackShot

extension XCTestCase {

    /// A `UserDefaults` store of this test's own, emptied at teardown.
    ///
    /// Pass it to `CameraViewModel(defaults:)`. What this replaces is worth remembering: the
    /// view model used to read and write `UserDefaults.standard` with no seam, so every test
    /// that built one had to snapshot nine `capture.*` keys, clear them, and put them back
    /// afterwards. That workaround shipped as a bug once — an early version cleared without
    /// restoring, which would have wiped the real settings of whatever app hosted the bundle
    /// — and even when correct it could only ever be as reliable as its own teardown.
    ///
    /// A per-test suite is stronger than a careful save-and-restore: nothing shared is
    /// touched in the first place, so a crashed or interrupted test cannot leave the owner's
    /// EV bias and neutral measurement in whatever state it happened to reach.
    func makeIsolatedDefaults(_ label: String = #function,
                              file: StaticString = #filePath,
                              line: UInt = #line) -> UserDefaults {
        // Unique per call, not merely per test: some tests build a second view model to
        // check that the first one's writes are visible to a fresh load, and a name reused
        // across tests in the same process would let one test's leftovers seed another's
        // "nothing stored yet" expectations.
        let suite = "test.stackshot.\(sanitizedSuiteComponent(label)).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("could not create an isolated defaults suite", file: file, line: line)
            return .standard
        }
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        return defaults
    }

    /// Strips what `#function` contributes that a suite name should not carry.
    private func sanitizedSuiteComponent(_ label: String) -> String {
        String(label.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }
}
