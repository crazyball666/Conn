public enum TerminalScrollInputSource: Sendable, Equatable {
    case touch
    case continuousWheel
    case discreteWheel
}

public struct TerminalScrollAccumulator: Sendable {
    public private(set) var pendingRows = 0

    private let rowHeight: Double
    private let maximumRowsPerFrame: Int
    private let maximumPendingRows: Int
    private var fractionalRows = 0.0
    private var generation: UInt64?

    public init(
        rowHeight: Double,
        maximumRowsPerFrame: Int = 8,
        maximumPendingRows: Int = 32
    ) {
        self.rowHeight = max(rowHeight, 1)
        self.maximumRowsPerFrame = max(maximumRowsPerFrame, 1)
        self.maximumPendingRows = max(maximumPendingRows, 1)
    }

    public mutating func consume(
        deltaPixels: Double,
        source: TerminalScrollInputSource,
        generation newGeneration: UInt64
    ) -> Int {
        if generation != newGeneration {
            reset(generation: newGeneration)
        }

        let incomingSign = deltaPixels == 0 ? 0 : (deltaPixels > 0 ? 1 : -1)
        let fractionalSign = fractionalRows == 0 ? 0 : (fractionalRows > 0 ? 1 : -1)
        let pendingSign = pendingRows == 0 ? 0 : (pendingRows > 0 ? 1 : -1)
        if incomingSign != 0 {
            if fractionalSign != 0, incomingSign != fractionalSign {
                fractionalRows = 0
            }
            if pendingSign != 0, incomingSign != pendingSign {
                pendingRows = 0
            }
        }

        var wholeRows = 0
        if source == .discreteWheel, incomingSign != 0 {
            wholeRows = incomingSign
            fractionalRows = 0
        } else {
            let accumulated = fractionalRows + deltaPixels / rowHeight
            wholeRows = Int(accumulated.rounded(.towardZero))
            fractionalRows = accumulated - Double(wholeRows)
        }

        pendingRows = min(max(pendingRows + wholeRows, -maximumPendingRows), maximumPendingRows)
        let emitted = min(max(pendingRows, -maximumRowsPerFrame), maximumRowsPerFrame)
        pendingRows -= emitted
        return emitted
    }

    public mutating func reset(generation newGeneration: UInt64? = nil) {
        generation = newGeneration
        pendingRows = 0
        fractionalRows = 0
    }
}
