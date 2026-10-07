import Foundation

/// Tiny assertion helper for the *Checks executables (XCTest / swift-testing are unavailable).
public enum Check {
    nonisolated(unsafe) private static var failures = 0
    nonisolated(unsafe) private static var passes = 0

    public static func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String,
                              file: StaticString = #fileID, line: UInt = #line) {
        if condition() { passes += 1 } else { failures += 1; print("FAIL \(file):\(line): \(message())") }
    }

    public static func equal<T: Equatable>(_ a: T, _ b: T, _ message: @autoclosure () -> String = "",
                                           file: StaticString = #fileID, line: UInt = #line) {
        expect(a == b, "\(message()) expected \(b), got \(a)", file: file, line: line)
    }

    /// Prints a summary and exits with status 1 if anything failed.
    public static func finish() -> Never {
        print(failures == 0 ? "OK: \(passes) checks passed" : "FAILED: \(failures) of \(passes + failures) checks")
        exit(failures == 0 ? 0 : 1)
    }
}
