// © 2026 High Gain Design. All rights reserved.
import XCTest
@testable import HiDockKit

final class CausalRegisterTests: XCTestCase {
    private let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let c = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    // Catches attributing consumed causal clocks to a currently displayed value.
    func testCurrentValueWritersExcludeConsumedContext() throws {
        var original = CausalRegister<String>(); try original.assign("old", by: a)
        var left = original, right = original
        try left.assign("local", by: a); try right.assign("peer", by: b)
        try left.merge(right)
        XCTAssertEqual(left.writers(for: "local"), [a])
        XCTAssertEqual(left.writers(for: "peer"), [b])
        XCTAssertEqual(left.writers(for: "old"), [])
        try left.assign("chosen", by: c)
        try left.merge(right)
        XCTAssertEqual(left.writers(for: "chosen"), [c])
        XCTAssertEqual(left.writers(for: "peer"), [])
        XCTAssertTrue(left.causalContext.contains { $0.writer == b }, "Observed peer remains in context but is not the current author")
    }
    // Catches losing a contributor when identical concurrent values coalesce.
    func testIdenticalValueWritersSurviveRoundTripAndMerge() throws {
        var left = CausalRegister<String>(), right = CausalRegister<String>(), third = CausalRegister<String>()
        try left.assign("same", by: a); try right.assign("same", by: b); try third.assign("different", by: c)
        try left.merge(right); try left.merge(third); try left.merge(right)
        let decoded = try JSONDecoder().decode(CausalRegister<String>.self, from: JSONEncoder().encode(left))
        XCTAssertEqual(decoded.writers(for: "same"), [a, b])
        XCTAssertEqual(decoded.writers(for: "different"), [c])
        let compacted = try decoded.applyingCausalFloor([.init(writer: a, counter: 1)])
        XCTAssertEqual(compacted.writers(for: "same"), [b])
        XCTAssertEqual(compacted.writers(for: "different"), [c])
    }

    // Catches retaining an overwritten local value or dropping the new assignment.
    func testSequentialAssignmentSupersedesObservedValue() throws {
        var value = CausalRegister<String>()
        try value.assign("red", by: a)
        try value.assign("blue", by: a)
        XCTAssertEqual(value.values, ["blue"])
        XCTAssertEqual(value.resolvedValue, "blue")
        XCTAssertFalse(value.isConflicted)
    }

    // Catches a timestamp/arrival-order winner that silently discards another Mac's edit.
    func testConcurrentDifferentValuesRemainAConflict() throws {
        var left = CausalRegister<String>()
        var right = CausalRegister<String>()
        try left.assign("red", by: a)
        try right.assign("blue", by: b)
        try left.merge(right)
        XCTAssertEqual(left.values, ["red", "blue"])
        XCTAssertNil(left.resolvedValue)
        XCTAssertTrue(left.isConflicted)
    }

    func testObservedRemoteValueIsSupersededByLaterAssignment() throws {
        var original = CausalRegister<String>()
        try original.assign("red", by: a)
        var edited = original
        try edited.assign("blue", by: b)
        try original.merge(edited)
        XCTAssertEqual(original.values, ["blue"])
    }

    func testIdenticalConcurrentValuesDoNotAskForResolution() throws {
        var left = CausalRegister<String>()
        var right = CausalRegister<String>()
        try left.assign("same", by: a)
        try right.assign("same", by: b)
        try left.merge(right)
        XCTAssertEqual(left.values, ["same"])
        XCTAssertEqual(left.resolvedValue, "same")
        XCTAssertFalse(left.isConflicted)
        // Both writers' causal information must survive the displayed coalescing.
        try left.assign("resolved", by: c)
        try left.merge(right)
        XCTAssertEqual(left.values, ["resolved"])
    }

    // Catches discarding context during cleanup and resurrecting a losing edit on reconnect.
    func testResolutionCannotBeUndoneByOldReplicaDelivery() throws {
        var left = CausalRegister<String>()
        var right = CausalRegister<String>()
        try left.assign("red", by: a)
        try right.assign("blue", by: b)
        let oldLeft = left
        let oldRight = right
        try left.merge(right)
        try left.assign("purple", by: a)
        try left.merge(oldLeft)
        try left.merge(oldRight)
        XCTAssertEqual(left.values, ["purple"])
        XCTAssertEqual(left.resolvedValue, "purple")
    }

    func testJoinIsOrderIndependentAssociativeAndIdempotent() throws {
        var red = CausalRegister<String>()
        var blue = CausalRegister<String>()
        var green = CausalRegister<String>()
        try red.assign("red", by: a)
        try blue.assign("blue", by: b)
        try green.assign("green", by: c)
        let orders = [[red, blue, green], [red, green, blue], [blue, red, green],
                      [blue, green, red], [green, red, blue], [green, blue, red]]
        var reference = red
        try reference.merge(blue)
        try reference.merge(green)
        XCTAssertEqual(reference.values, ["red", "blue", "green"])
        for order in orders {
            var result = CausalRegister<String>()
            for input in order { try result.merge(input) }
            XCTAssertEqual(result.values, ["red", "blue", "green"])
            XCTAssertEqual(result, reference)
            let beforeRepeat = result
            for input in order { try result.merge(input) }
            XCTAssertEqual(result, beforeRepeat)
        }
        var grouped = blue
        try grouped.merge(green)
        var other = red
        try other.merge(grouped)
        XCTAssertEqual(other, reference)
    }

    func testCodableRoundTripRetainsResolutionContext() throws {
        var original = CausalRegister<String>()
        try original.assign("old", by: a)
        let stale = original
        try original.assign("current", by: b)
        let bytes = try JSONEncoder().encode(original)
        var decoded = try JSONDecoder().decode(CausalRegister<String>.self, from: bytes)
        try decoded.merge(stale)
        XCTAssertEqual(decoded.values, ["current"])
        XCTAssertEqual(decoded, original)
    }

    func testOppositeMergeOrdersEncodeToTheSameBytes() throws {
        var left = CausalRegister<String>()
        var right = CausalRegister<String>()
        try left.assign("red", by: a)
        try right.assign("blue", by: b)
        var lr = left
        var rl = right
        try lr.merge(right)
        try rl.merge(left)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(lr), try encoder.encode(rl))
    }

    func testDifferentValuesForTheSameDotAreRejectedWithoutChangingState() throws {
        var left = CausalRegister<String>()
        var forged = CausalRegister<String>()
        try left.assign("red", by: a)
        try forged.assign("blue", by: a)
        let before = left
        XCTAssertThrowsError(try left.merge(forged))
        XCTAssertEqual(left, before)
        XCTAssertEqual(left.values, ["red"])
    }

    func testDecoderRejectsDotsMissingFromTheObservedContext() {
        let bytes = Data("""
        {"entries":[{"dot":{"writer":"00000000-0000-0000-0000-000000000001","counter":2},"value":"red"}],
         "context":[{"writer":"00000000-0000-0000-0000-000000000001","counter":1}]}
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(CausalRegister<String>.self, from: bytes))
    }

    func testDecoderRejectsDuplicateDotsInsteadOfChoosingOne() {
        let bytes = Data("""
        {"entries":[{"dot":{"writer":"00000000-0000-0000-0000-000000000001","counter":1},"value":"red"},
                    {"dot":{"writer":"00000000-0000-0000-0000-000000000001","counter":1},"value":"blue"}],
         "context":[{"writer":"00000000-0000-0000-0000-000000000001","counter":1}]}
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(CausalRegister<String>.self, from: bytes))
    }

    func testDecoderRejectsZeroDotsAndDuplicateClockRows() {
        let fixtures = [
            """
            {"entries":[{"dot":{"writer":"00000000-0000-0000-0000-000000000001","counter":0},"value":"red"}],
             "context":[{"writer":"00000000-0000-0000-0000-000000000001","counter":0}]}
            """,
            """
            {"entries":[],"context":[{"writer":"00000000-0000-0000-0000-000000000001","counter":1},
                                    {"writer":"00000000-0000-0000-0000-000000000001","counter":2}]}
            """
        ]
        for fixture in fixtures {
            XCTAssertThrowsError(try JSONDecoder().decode(CausalRegister<String>.self, from: Data(fixture.utf8)))
        }
    }

    // Catches accepting a stale value already superseded by its own writer.
    func testDecoderRejectsAValueSupersededByItsOwnContext() {
        let bytes = Data("""
        {"entries":[{"dot":{"writer":"00000000-0000-0000-0000-000000000001","counter":1},"value":"stale"}],
         "context":[{"writer":"00000000-0000-0000-0000-000000000001","counter":2}]}
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(CausalRegister<String>.self, from: bytes))
    }

    func testCounterExhaustionThrowsAndPreservesTheAcceptedValue() throws {
        let bytes = Data("""
        {"entries":[{"dot":{"writer":"00000000-0000-0000-0000-000000000001","counter":18446744073709551615},"value":"last"}],
         "context":[{"writer":"00000000-0000-0000-0000-000000000001","counter":18446744073709551615}]}
        """.utf8)
        var register = try JSONDecoder().decode(CausalRegister<String>.self, from: bytes)
        let before = register
        XCTAssertThrowsError(try register.assign("wrapped", by: a))
        XCTAssertEqual(register, before)
        XCTAssertEqual(register.values, ["last"])
    }
}
