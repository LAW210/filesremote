import Foundation

/// Plain-text diagnostic log written into a StackSet's own folder, where it's already
/// visible in the Files app. When a stack comes out soft or banded, this is the only
/// record of what actually happened frame-by-frame — lens settle timing, retries,
/// which format each frame landed as — without which the owner has just the depth map
/// to go on.
///
/// Deliberately dependency-free and unable to affect the capture path: every failure
/// mode here is swallowed. A logging bug must never turn into a bracket failure.
final class CaptureLog {
    private let url: URL
    private let start: Date
    private var lines: [String] = []

    /// `directory` is the StackSet folder; the log always lands at
    /// "<directory>/capture-log.txt". If that file already exists — the bracket
    /// wrote one and stacking is now appending to it — its contents are loaded so
    /// `flush()` rewrites the whole file instead of clobbering what's there. This
    /// keeps the writer dead simple (no append-mode file handle to manage) while
    /// still behaving like an append across separate CaptureLog instances.
    init(directory: URL) {
        self.url = directory.appendingPathComponent("capture-log.txt")
        self.start = Date()
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if lines.last == "" { lines.removeLast() }   // trailing newline, not a blank line
        }
    }

    /// Appends one line, prefixed with the elapsed time since the log was created.
    /// The prefix is fixed-width so columns line up when the file is read as plain text.
    func line(_ text: String) {
        let elapsed = Date().timeIntervalSince(start)
        let prefix = String(format: "%7.3f", elapsed)
        lines.append("\(prefix)  \(text)")
    }

    /// Writes the buffered lines to disk. Buffering in memory and flushing at natural
    /// checkpoints (end of bracket, end of stacking) keeps disk I/O out of the
    /// per-frame timing this log exists to measure. Silent on failure — a log write
    /// must never be the thing that throws.
    func flush() {
        // Nothing buffered means nothing to say. Writing anyway would leave a file
        // containing a lone newline, which the next instance over this folder would
        // seed as one empty line — putting a blank line above the first real entry.
        // It also keeps `captureLogURL(for:)` honest: no file means no log.
        guard !lines.isEmpty else { return }

        let text = lines.joined(separator: "\n") + "\n"
        guard let data = text.data(using: .utf8) else { return }
        try? data.write(to: url)
    }
}
