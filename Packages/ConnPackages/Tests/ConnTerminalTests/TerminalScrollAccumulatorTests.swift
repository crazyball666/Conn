import Testing
@testable import ConnTerminal

@Suite("Terminal scroll accumulation")
struct TerminalScrollAccumulatorTests {
    @Test("fractional touch rows are retained")
    func fractionalRetention() {
        var accumulator = TerminalScrollAccumulator(rowHeight: 20)

        #expect(accumulator.consume(deltaPixels: 9, source: .touch, generation: 1) == 0)
        #expect(accumulator.consume(deltaPixels: 11, source: .touch, generation: 1) == 1)
    }

    @Test("direction reversal discards opposite fractional momentum")
    func directionReversal() {
        var accumulator = TerminalScrollAccumulator(rowHeight: 20)

        #expect(accumulator.consume(deltaPixels: 15, source: .touch, generation: 1) == 0)
        #expect(accumulator.consume(deltaPixels: -10, source: .touch, generation: 1) == 0)
        #expect(accumulator.consume(deltaPixels: -10, source: .touch, generation: 1) == -1)
    }

    @Test("per-frame output and retained pending rows are bounded")
    func caps() {
        var accumulator = TerminalScrollAccumulator(
            rowHeight: 10,
            maximumRowsPerFrame: 4,
            maximumPendingRows: 9
        )

        #expect(accumulator.consume(deltaPixels: 1_000, source: .touch, generation: 1) == 4)
        #expect(accumulator.pendingRows == 5)
        #expect(accumulator.consume(deltaPixels: 0, source: .touch, generation: 1) == 4)
        #expect(accumulator.pendingRows == 1)
    }

    @Test("discrete physical wheel emits at least one row")
    func physicalWheelMinimum() {
        var accumulator = TerminalScrollAccumulator(rowHeight: 40)

        #expect(accumulator.consume(deltaPixels: 1, source: .discreteWheel, generation: 1) == 1)
        #expect(accumulator.consume(deltaPixels: -1, source: .discreteWheel, generation: 1) == -1)
    }

    @Test("generation change cancels fractional and pending work")
    func generationCancellation() {
        var accumulator = TerminalScrollAccumulator(
            rowHeight: 10,
            maximumRowsPerFrame: 2,
            maximumPendingRows: 8
        )

        #expect(accumulator.consume(deltaPixels: 55, source: .touch, generation: 1) == 2)
        #expect(accumulator.pendingRows == 3)
        #expect(accumulator.consume(deltaPixels: 5, source: .touch, generation: 2) == 0)
        #expect(accumulator.pendingRows == 0)
    }
}
