import Foundation

enum MediaItemState: Equatable {
    case idle
    case loading
    case ready
    case transcoding(Double)    // 0.0 – 1.0 progress
    case unsupported
    case failed(String)

    static func == (lhs: MediaItemState, rhs: MediaItemState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.ready, .ready), (.unsupported, .unsupported):
            return true
        case (.transcoding(let a), .transcoding(let b)):
            return a == b
        case (.failed(let a), .failed(let b)):
            return a == b
        default:
            return false
        }
    }

    var displayLabel: String {
        switch self {
        case .idle:                return ""
        case .loading:             return "Loading…"
        case .ready:               return ""
        case .transcoding(let p):  return String(format: "%.0f%%", p * 100)
        case .unsupported:         return "Unsupported"
        case .failed:              return "Failed"
        }
    }

    var errorDescription: String? {
        if case .failed(let msg) = self { return msg }
        return nil
    }

    /// Whether no further automatic state transition is expected.
    var isTerminal: Bool {
        switch self {
        case .ready, .unsupported, .failed: return true
        default: return false
        }
    }
}
