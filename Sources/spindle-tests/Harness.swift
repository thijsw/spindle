import Foundation

// Minimal test harness: the Command Line Tools toolchain ships neither
// XCTest nor Swift Testing, so tests run as a plain executable. The #expect
// spelling matches Swift Testing for an easy migration once Xcode is around.

@MainActor
enum Harness {
    static var passed = 0
    static var failed = 0
    private(set) static var currentSuite = ""

    static func suite(_ name: String, _ body: () throws -> Void) {
        currentSuite = name
        print("— \(name)")
        do {
            try body()
        } catch {
            failed += 1
            print("  ✗ suite threw: \(error)")
        }
    }

    static func expect(
        _ condition: @autoclosure () -> Bool,
        _ label: String,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        if condition() {
            passed += 1
            print("  ✓ \(label)")
        } else {
            failed += 1
            print("  ✗ \(label)  (\(file):\(line))")
        }
    }

    static func expectThrows<T>(
        _ label: String,
        file: StaticString = #fileID,
        line: UInt = #line,
        _ body: () throws -> T
    ) {
        do {
            _ = try body()
            failed += 1
            print("  ✗ \(label) — expected an error  (\(file):\(line))")
        } catch {
            passed += 1
            print("  ✓ \(label)")
        }
    }

    static func finish() -> Never {
        print("\n\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
