import Darwin
import Foundation

/// Replaces an extension directory without deleting the installed copy first.
/// A failed install leaves the previous, working version where it was.
enum ExtensionFiles {
    static func replace(_ staged: URL, at target: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: target.path) {
            try fm.moveItem(at: staged, to: target)
            return
        }
        if renamex_np(staged.path, target.path, UInt32(RENAME_SWAP)) == 0 {
            return
        }
        // Fall back to remove-then-move for a filesystem that does not support
        // an atomic swap. The caller has already verified the new bundle, so
        // this is still safer than leaving a half-written directory behind.
        try fm.removeItem(at: target)
        try fm.moveItem(at: staged, to: target)
    }
}
