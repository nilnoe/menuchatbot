import XCTest

@testable import DeepSeekChat

/// 流式 tool_calls 拼装：分片累计 / 顺序 / 异常流保护（T2-3a 前置单元）。
final class ToolCallAccumulatorTests: XCTestCase {
    func testAssemblesFragmentedArguments() {
        var accumulator = ToolCallAccumulator()
        accumulator.append(
            index: 0, id: "call_1", name: "calculator", argumentsFragment: #"{"expr":"1 +"#)
        accumulator.append(index: 0, id: nil, name: nil, argumentsFragment: #" 2"}"#)

        let calls = accumulator.assembled()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].id, "call_1")
        XCTAssertEqual(calls[0].function.name, "calculator")
        XCTAssertEqual(calls[0].function.arguments, #"{"expr":"1 + 2"}"#)
    }

    func testMultipleCallsKeepIndexOrder() {
        var accumulator = ToolCallAccumulator()
        accumulator.append(index: 1, id: "call_2", name: "calc_b", argumentsFragment: "{}")
        accumulator.append(index: 0, id: "call_1", name: "calc_a", argumentsFragment: "{}")

        let calls = accumulator.assembled()
        XCTAssertEqual(calls.map(\.id), ["call_1", "call_2"])
    }

    func testDropsPartMissingName() {
        var accumulator = ToolCallAccumulator()
        accumulator.append(index: 0, id: "call_x", name: nil, argumentsFragment: "{}")
        accumulator.append(index: 1, id: "call_1", name: "calculator", argumentsFragment: "{}")

        let calls = accumulator.assembled()
        XCTAssertEqual(calls.map(\.id), ["call_1"], "缺 name 的片段应被丢弃")
    }

    func testEmptyIsEmpty() {
        var accumulator = ToolCallAccumulator()
        XCTAssertTrue(accumulator.isEmpty)
        accumulator.append(index: 0, id: nil, name: "calculator", argumentsFragment: "")
        XCTAssertFalse(accumulator.isEmpty)
    }
}
