import Foundation
import os

/// Logging, so a silent failure leaves a trace.
///
/// Revision 1 of the plan had no observability at all, while documenting five separate
/// silent failure modes: a privacy grant that denies without a dialog, synthesis that
/// produces zero frames without a run loop, an encoder that yields an unplayable file with
/// no error, a playback rate change ignored with no error, and a sample rate silently
/// dropped when passed as the wrong type. Item 13 then forbade showing raw error text, so
/// there was nowhere at all for the detail to go.
///
/// The rule: a catch site logs the full error and shows only `AppFailure.userMessage`.
public enum Log {
    public static let subsystem = "com.zackzhang.oralenglish"

    public static let store = Logger(subsystem: subsystem, category: "store")
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let speech = Logger(subsystem: subsystem, category: "speech")
    public static let export = Logger(subsystem: subsystem, category: "export")
    public static let app = Logger(subsystem: subsystem, category: "app")

    /// Logs a failure with its underlying detail, which is the part the UI is not allowed
    /// to show. Call this at every catch site.
    public static func failure(_ logger: Logger, _ failure: AppFailure, context: String = "") {
        let detail = failure.underlying.map { String(describing: $0) } ?? "none"
        logger.error("""
            failure=\(failure.key, privacy: .public) \
            context=\(context, privacy: .public) \
            detail=\(detail, privacy: .public)
            """)
    }

    /// Logs an arbitrary error that has not been mapped yet.
    public static func unexpected(_ logger: Logger, _ error: Error, context: String = "") {
        logger.error("""
            failure=unexpected context=\(context, privacy: .public) \
            detail=\(String(describing: error), privacy: .public)
            """)
    }

    /// Reads back recent entries for the "Copy diagnostics" menu item. Shelling out to
    /// `log show` is the only way to read the unified log from inside the process.
    public static func diagnosticsCommand(minutes: Int = 30) -> [String] {
        [
            "/usr/bin/log", "show",
            "--predicate", "subsystem == \"\(subsystem)\"",
            "--last", "\(minutes)m",
            "--style", "compact",
        ]
    }
}
