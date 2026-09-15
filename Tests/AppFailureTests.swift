import Foundation
import Testing

/// Makes the error-copy rules from item 13 machine-checked instead of hand-checked.
@Suite("AppFailure copy")
struct AppFailureTests {

    @Test("every case has a message")
    func allHaveMessages() {
        for f in AppFailure.allCasesForCopyCheck {
            #expect(!f.userMessage.isEmpty, "\(f.key) has no message")
        }
    }

    @Test("no message leaks raw error text")
    func noRawErrorText() {
        for f in AppFailure.allCasesForCopyCheck {
            let m = f.userMessage
            #expect(!m.contains("NSError"), "\(f.key): \(m)")
            #expect(!m.contains("Error Domain"), "\(f.key): \(m)")
            #expect(!m.contains("OSStatus"), "\(f.key): \(m)")
            #expect(!m.lowercased().contains("nil"), "\(f.key): \(m)")
        }
    }

    @Test("no message speaks in the first person")
    func noFirstPerson() {
        for f in AppFailure.allCasesForCopyCheck {
            let m = " \(f.userMessage) "
            #expect(!m.contains(" I "), "\(f.key): \(m)")
            #expect(!m.contains(" my "), "\(f.key): \(m)")
            #expect(!m.contains(" we "), "\(f.key): \(m)")
        }
    }

    @Test("no message shouts")
    func noExclamation() {
        for f in AppFailure.allCasesForCopyCheck {
            #expect(!f.userMessage.contains("!"), "\(f.key)")
        }
    }

    /// Say what happened, then what to do. The second sentence is the action.
    @Test("every message names an action")
    func namesAnAction() {
        let actionVerbs = [
            "turn", "download", "check", "record", "move", "free", "reveal",
            "update", "use", "try", "choose", "inspect", "repair", "remove",
        ]
        for f in AppFailure.allCasesForCopyCheck {
            let m = f.userMessage.lowercased()
            let hasAction = actionVerbs.contains { m.contains($0) }
                || m.contains("still works")
                || m.contains("nothing changed")
            #expect(hasAction, "\(f.key) does not tell the user what to do: \(f.userMessage)")
        }
    }

    @Test("every message is short enough to read at a glance")
    func messagesAreShort() {
        for f in AppFailure.allCasesForCopyCheck {
            #expect(f.userMessage.count <= 140, "\(f.key) is \(f.userMessage.count) characters")
        }
    }

    @Test("keys are unique and stable for logging")
    func keysUnique() {
        let keys = AppFailure.allCasesForCopyCheck.map(\.key)
        #expect(Set(keys).count == keys.count)
        for k in keys {
            #expect(k == k.lowercased())
            #expect(!k.contains(" "))
        }
    }
}
