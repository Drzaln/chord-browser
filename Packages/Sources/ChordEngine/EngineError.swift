import ChordLogging
import Foundation

enum Log {
    static let engine = AppLog.category("engine")
    static let favicon = AppLog.category("favicon")
}

public enum EngineError: Error, CustomStringConvertible {
    case unknownPane(UUID)
    case navigationFailed(url: URL?, underlying: Error)

    public var description: String {
        switch self {
        case .unknownPane(let id): "no live web view for pane \(id)"
        case .navigationFailed(let url, let underlying):
            "navigation to \(url?.absoluteString ?? "<none>") failed: \(underlying)"
        }
    }
}
