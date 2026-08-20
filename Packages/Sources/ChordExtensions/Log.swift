import ChordLogging
import Foundation

/// One category per package (BROWSER_SPEC 3.7), so Instruments traces read
/// without instrumentation work.
enum Log {
    static let extensions = AppLog.category("extensions")
}
