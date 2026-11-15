import Foundation
@testable import SafeNetCore

func registerMiniYAMLTests() {
    test("testYAMLScalarsAndNesting") {
        let v = try MiniYAML.parse("""
        a: 1
        b: true
        c: hello world
        d:
          e: 2.5
          f: ~
        """)
        expectEqual(v["a"], .number(1))
        expectEqual(v["b"], .bool(true))
        expectEqual(v["c"], .string("hello world"))
        expectEqual(v["d"]?["e"], .number(2.5))
        expectEqual(v["d"]?["f"], .null)
    }

    test("testYAMLComments") {
        let v = try MiniYAML.parse("""
        # header
        a: 1 # trailing
        b: "x # not a comment"
        c: http://host/#frag
        """)
        expectEqual(v["a"], .number(1))
        expectEqual(v["b"], .string("x # not a comment"))
        expectEqual(v["c"], .string("http://host/#frag"))
    }

    test("testYAMLQuotedStrings") {
        let v = try MiniYAML.parse("a: \"q\\\"uote\\n\"\nb: 'it''s'\nc: \"123\"\nd: \"true\"\n")
        expectEqual(v["a"], .string("q\"uote\n"))
        expectEqual(v["b"], .string("it's"))
        expectEqual(v["c"], .string("123"))
        expectEqual(v["d"], .string("true"))
    }

    test("testYAMLListOfScalarsAndMaps") {
        let v = try MiniYAML.parse("""
        apps:
          - Claude
          - "Cursor"
        same_indent:
        - x
        - y
        nets:
          - name: Home
            mac: aa:bb
          - name: Work
            mac: cc:dd
        flow: [a, b, "c d"]
        empty: []
        """)
        expectEqual(v["apps"], .list([.string("Claude"), .string("Cursor")]))
        expectEqual(v["same_indent"], .list([.string("x"), .string("y")]))
        expectEqual(v["nets"]?.listValue?.count, 2)
        expectEqual(v["nets"]?.listValue?[1]["name"], .string("Work"))
        expectEqual(v["nets"]?.listValue?[0]["mac"], .string("aa:bb"))
        expectEqual(v["flow"], .list([.string("a"), .string("b"), .string("c d")]))
        expectEqual(v["empty"], .list([]))
    }

    test("testYAMLInvalidThrows") {
        for bad in ["a: [unclosed\n", "a: 1\n   b: 2\n", "\ta: 1\n", "just text\n", "a: \"open\n",
                    "a: 1\na: 2\n", "a:\n  - x\n  b: 1\n", "a: 'x' junk\n"] {
            expectThrows({ _ = try MiniYAML.parse(bad) }, bad)
        }
    }

    test("testYAMLEmitParseRoundTrip") {
        let v: YAMLValue = .map([
            YAMLEntry("plain", .string("abc")),
            YAMLEntry("tricky", .string("a: b # c")),
            YAMLEntry("numlike", .string("123")),
            YAMLEntry("boollike", .string("true")),
            YAMLEntry("empty", .string("")),
            YAMLEntry("multi", .string("l1\nl2 \"q\"")),
            YAMLEntry("n", .number(5)),
            YAMLEntry("x", .number(0.25)),
            YAMLEntry("list", .list([.string("a"), .string("b: c")])),
            YAMLEntry("emptylist", .list([])),
            YAMLEntry("emptymap", .map([])),
            YAMLEntry("maps", .list([.map([YAMLEntry("k", .string("v")), YAMLEntry("n", .number(1))]),
                                     .map([YAMLEntry("k", .string("w"))])])),
            YAMLEntry("nested", .map([YAMLEntry("a", .map([YAMLEntry("b", .bool(false))]))])),
        ])
        try expectEqual(MiniYAML.parse(MiniYAML.emit(v)), v)
    }
}
