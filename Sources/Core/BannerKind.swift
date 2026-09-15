import Foundation

/// Banner kinds with an explicit priority order.
///
/// Revision 1 had four items writing to one banner with no owner and no precedence, and
/// specified its lifetime twice inconsistently — so a dismissed voice nag could hide a
/// permission problem. Permission kinds are never dismissible.
public enum BannerKind: Sendable, Equatable, Comparable {
    case micDenied
    case recognitionDenied
    case offlineModelMissing
    case librarySynced
    case voiceQuality

    /// Lower sorts first and wins.
    var priority: Int {
        switch self {
        case .micDenied: return 0
        case .recognitionDenied: return 1
        case .offlineModelMissing: return 2
        case .librarySynced: return 3
        case .voiceQuality: return 4
        }
    }

    public static func < (a: BannerKind, b: BannerKind) -> Bool { a.priority < b.priority }

    public var isDismissible: Bool {
        switch self {
        case .micDenied, .recognitionDenied, .offlineModelMissing: return false
        case .librarySynced, .voiceQuality: return true
        }
    }
}
