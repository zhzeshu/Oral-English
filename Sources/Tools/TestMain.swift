import Testing

// Entry point for the test binary that test.sh builds.
//
// swift-testing ships with Command Line Tools, so Xcode is not needed. What is needed is
// this explicit entry point plus the framework, plugin and rpath flags in test.sh --
// SwiftPM would normally supply all of that, but it looks for Xcode's Platforms directory
// and so cannot here. Driving swiftc directly works.
@main
struct TestMain {
    static func main() async {
        await Testing.__swiftPMEntryPoint() as Never
    }
}
