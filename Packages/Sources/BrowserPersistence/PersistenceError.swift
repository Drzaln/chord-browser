import BrowserLogging
import Foundation

enum Log {
    static let db = AppLog.category("persistence")
}

public enum PersistenceError: Error, CustomStringConvertible {
    case openFailed(path: String, underlying: Error)
    case migrationFailed(name: String, underlying: Error)
    case backupFailed(underlying: Error)

    public var description: String {
        switch self {
        case .openFailed(let path, let underlying):
            "failed to open database at \(path): \(underlying)"
        case .migrationFailed(let name, let underlying):
            "migration \(name) failed: \(underlying)"
        case .backupFailed(let underlying):
            "pre-migration backup failed: \(underlying)"
        }
    }
}
