import Foundation
import XCTest
@testable import StackShot

extension XCTestCase {

    /// Isolates the `capture.*` defaults for one test.
    ///
    /// `CameraViewModel` reads and writes `UserDefaults.standard` through
    /// `CaptureDefaults` and never passes a `defaults:` — there is no injection seam — so
    /// every test that builds one touches whatever store the tests run against. Clearing
    /// gives the documented defaults (EV 0, 5000 K, tint 0, 8 frames); the snapshot is
    /// what makes it safe, because a suite that only cleared would wipe the real settings
    /// of whichever app hosts the bundle. Nothing outside the `capture.` prefix is read
    /// or written.
    func isolatePersistedCaptureDefaults() {
        let defaults = UserDefaults.standard
        var saved: [String: Any] = [:]
        for key in CaptureDefaults.allKeys {
            if let value = defaults.object(forKey: key) { saved[key] = value }
            defaults.removeObject(forKey: key)
        }
        addTeardownBlock {
            for key in CaptureDefaults.allKeys {
                if let value = saved[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
    }
}
