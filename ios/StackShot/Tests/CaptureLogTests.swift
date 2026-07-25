import XCTest
@testable import StackShot

final class CaptureLogTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureLogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try super.tearDownWithError()
    }

    private var logURL: URL { directory.appendingPathComponent("capture-log.txt") }

    private func readLines() throws -> [String] {
        let text = try String(contentsOf: logURL, encoding: .utf8)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    func testNothingIsWrittenUntilFlush() {
        let log = CaptureLog(directory: directory)
        log.line("frame 1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path))

        log.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path))
    }

    func testLinesAreWrittenInOrderWithAnElapsedPrefix() throws {
        let log = CaptureLog(directory: directory)
        log.line("first")
        log.line("second")
        log.flush()

        let lines = try readLines()
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("  first"))
        XCTAssertTrue(lines[1].hasSuffix("  second"))

        // "%7.3f" plus a two-space separator: the elapsed column is fixed-width so
        // the file stays readable as plain text.
        for line in lines {
            XCTAssertEqual(String(line.prefix(9)).count, 9)
            let elapsed = Double(line.prefix(7).trimmingCharacters(in: .whitespaces))
            XCTAssertNotNil(elapsed)
            XCTAssertGreaterThanOrEqual(elapsed ?? -1, 0)
            XCTAssertEqual(String(line.dropFirst(7).prefix(2)), "  ")
        }
    }

    /// The behaviour the capture path depends on: `FocusBracketController` writes the
    /// bracket's lines, then `StackingService` opens a *separate* CaptureLog over the
    /// same folder. The second must extend the file, not replace it.
    func testASecondInstanceAppendsRatherThanClobbering() throws {
        let bracketLog = CaptureLog(directory: directory)
        bracketLog.line("frame 1")
        bracketLog.line("frame 2")
        bracketLog.flush()

        let stackingLog = CaptureLog(directory: directory)
        stackingLog.line("stack: engine=native")
        stackingLog.flush()

        let lines = try readLines()
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasSuffix("  frame 1"))
        XCTAssertTrue(lines[1].hasSuffix("  frame 2"))
        XCTAssertTrue(lines[2].hasSuffix("  stack: engine=native"))
    }

    /// Flushing twice from one instance must not duplicate the earlier lines — the
    /// writer rewrites the whole file each time rather than appending to it.
    func testRepeatedFlushesDoNotDuplicateLines() throws {
        let log = CaptureLog(directory: directory)
        log.line("first")
        log.flush()
        log.line("second")
        log.flush()

        XCTAssertEqual(try readLines().count, 2)
    }

    /// Every seed/append round trip must be stable, or a long shoot's log would grow
    /// a blank line per stage from the trailing newline.
    func testNoBlankLinesAccumulateAcrossInstances() throws {
        for index in 0..<4 {
            let log = CaptureLog(directory: directory)
            log.line("stage \(index)")
            log.flush()
        }

        let lines = try readLines()
        XCTAssertEqual(lines.count, 4)
        XCTAssertFalse(lines.contains(""))
    }

    /// A log write must never be the thing that fails a capture, so an unwritable
    /// destination is swallowed rather than thrown or trapped.
    func testAnUnwritableDirectoryFailsSilently() {
        let missing = directory.appendingPathComponent("does/not/exist", isDirectory: true)
        let log = CaptureLog(directory: missing)
        log.line("frame 1")
        log.flush()      // must not throw or crash

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: missing.appendingPathComponent("capture-log.txt").path))
    }

    func testFlushingWithNoLinesLeavesAnEmptyLogRatherThanFailing() throws {
        CaptureLog(directory: directory).flush()
        XCTAssertEqual(try readLines(), [])
    }
}
