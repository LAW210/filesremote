import Foundation

/// The stacking side of the capture flow, as `CameraViewModel` sees it.
///
/// The same seam as `CameraControlling`, for the same reason. `StackingService` reaches the
/// real filesystem and the real photo library, so a view model holding it directly made the
/// whole post-capture path — auto-save, `resultSavedToPhotos`, and the deliberate rule that
/// a Photos failure is reported but still leaves the stack `.done` — reachable only by
/// running a bracket on a phone. That is the last significant region of the view model with
/// no test at all, and it is the region where a mistake loses a finished photo rather than
/// producing a visibly wrong one.
///
/// Deliberately only the three members the view model uses. `mergedImage`, `depthMapImage`
/// and `captureLogURL` stay off it: the Library reads those from `StackingService` directly,
/// is independent of the view model by design, and widening this protocol to cover it would
/// make every fake implement members no test needs.
protocol StackPersisting {

    /// Stacks the set, writes the result beside its frames, records it in the manifest, and
    /// returns the updated set. Progress is reported 0–1 and may be called from any thread.
    func stackAndPersist(_ set: StackSet,
                         outputFormat: AppConfig.Stacking.OutputFormat,
                         deleteFramesAfter: Bool,
                         progress: @escaping (Double) -> Void) async throws -> (set: StackSet, output: StackOutput)

    /// URL of the set's merged file on disk, or nil if it has not been stacked.
    func mergedFileURL(for set: StackSet) -> URL?

    /// Adds an already-encoded file to the photo library as-is.
    func saveFileToPhotos(_ url: URL) async throws

    /// Removes the set and everything in its folder.
    ///
    /// Needed because stacking is cancellable and there is no re-stack path: a cancelled
    /// stack that kept its frames would leave a row in the Library that says "not stacked"
    /// forever, consuming the storage of a full bracket with no way to finish or read it.
    /// A cancelled bracket already deletes its own directory, so this keeps the two
    /// cancellation paths behaving the same way.
    func discard(_ set: StackSet)
}

extension StackingService: StackPersisting {}
