import Foundation

enum MediaItemState: Equatable {
    case idle
    case loading
    case ready
    case unsupported
    case failed(String)

    static func == (lhs: MediaItemState, rhs: MediaItemState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.ready, .ready), (.unsupported, .unsupported):
            return true
        case (.failed(let a), .failed(let b)):
            return a == b
        default:
            return false
        }
    }

    var displayLabel: String {
        switch self {
        case .idle:        return ""
        case .loading:     return "Loading…"
        case .ready:       return ""
        case .unsupported: return "Unsupported"
        case .failed:      return "Failed"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .ready, .unsupported, .failed: return true
        default: return false
        }
    }
}
