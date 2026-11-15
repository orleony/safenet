// Tiny XCTest replacement (XCTest is unavailable without Xcode).
// Test files expose `func registerXxxTests()` which call `test("name") { ... }`.
// A generated main.swift (scripts/test.sh) calls every register function, then runAllTests().
import Foundation

struct TestKitFailure: Error, CustomStringConvertible {
    let description: String
}

private var registeredTests: [(name: String, body: () throws -> Void)] = []
private var currentFailures: [String] = []

public func test(_ name: String, _ body: @escaping () throws -> Void) {
    registeredTests.append((name, body))
}

public func expect(_ cond: @autoclosure () throws -> Bool, _ msg: String = "",
                   file: StaticString = #file, line: UInt = #line) rethrows {
    if !(try cond()) {
        currentFailures.append("\((String(describing: file) as NSString).lastPathComponent):\(line) expectation failed \(msg)")
    }
}

public func expectEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ msg: String = "",
                                      file: StaticString = #file, line: UInt = #line) rethrows {
    let x = try a(), y = try b()
    if x != y {
        currentFailures.append("\((String(describing: file) as NSString).lastPathComponent):\(line) expected equal: \(x) vs \(y) \(msg)")
    }
}

public func expectThrows(_ body: () throws -> Void, _ msg: String = "",
                         file: StaticString = #file, line: UInt = #line) {
    do {
        try body()
        currentFailures.append("\((String(describing: file) as NSString).lastPathComponent):\(line) expected throw, none thrown \(msg)")
    } catch {}
}

public func runAllTests() -> Never {
    let filter: String? = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
    var executed = 0, failed = 0
    for t in registeredTests {
        if let f = filter, !t.name.contains(f) { continue }
        executed += 1
        currentFailures = []
        do { try t.body() } catch { currentFailures.append("threw \(error)") }
        if currentFailures.isEmpty {
            print("PASS \(t.name)")
        } else {
            failed += 1
            print("FAIL \(t.name): \(currentFailures.joined(separator: "; "))")
        }
    }
    print("Executed \(executed) tests, \(failed) failures")
    exit(failed == 0 ? 0 : 1)
}
