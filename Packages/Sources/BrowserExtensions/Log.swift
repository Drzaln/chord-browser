import Foundation
import os

/// One category per package (BROWSER_SPEC 3.7), so Instruments traces read
/// without instrumentation work.
enum Log {
    static let subsystem = "com.rizal.browser"
    static let extensions = Logger(subsystem: subsystem, category: "extensions")
}
