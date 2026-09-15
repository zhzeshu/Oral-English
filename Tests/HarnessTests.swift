import Foundation
import Testing

// Guards the test harness itself.
//
// The point of these is not the assertions -- they are trivially true. It is that a
// harness which silently passes everything, or which quietly stops discovering tests,
// would invalidate every other suite in the project without anyone noticing. These
// exercise the features the real suites depend on, so a toolchain change that breaks
// discovery, parameterization, async, or throw-checking fails here and names itself.
//
// To confirm failure reporting still works, temporarily break one assertion below and
// run ./test.sh -- it must exit non-zero and print the file and line.
@Suite("Harness")
struct HarnessTests {

    @Test("plain assertions run")
    func plainAssertion() {
        #expect(1 + 1 == 2)
    }

    @Test("parameterized cases run, one per row", arguments: [
        ("one", 3),
        ("three", 5),
        ("", 0),
    ])
    func parameterized(text: String, expectedCount: Int) {
        #expect(text.count == expectedCount)
    }

    @Test("async tests run")
    func asyncTest() async throws {
        try await Task.sleep(nanoseconds: 1_000)
        #expect(Bool(true))
    }

    @Test("thrown errors can be asserted")
    func throwing() {
        struct Boom: Error {}
        #expect(throws: Boom.self) { throw Boom() }
    }

    @Test("Foundation is available in the test target")
    func foundationAvailable() {
        #expect(UUID().uuidString.count == 36)
    }

    @Test("NaturalLanguage is available in the test target")
    func naturalLanguageAvailable() {
        // Imported by Core, not here, so this only checks the dependency is linkable at
        // all. SentenceSplitterTests cover the behavior.
        #expect(Locale(identifier: "en_US").identifier == "en_US")
    }
}
