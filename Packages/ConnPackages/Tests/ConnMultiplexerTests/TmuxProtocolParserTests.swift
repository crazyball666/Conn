import ConnMultiplexer
import Foundation
import Testing

@Suite("tmux Control Mode incremental protocol parser")
struct TmuxProtocolParserTests {
    @Test("三字段 dialect 解析 marker、command block、通知、pane bytes 与退出")
    func parsesCompleteThreeFieldProtocol() throws {
        var parser = makeParser()
        let protocolLines = "%begin 10 22 1\r\n"
            + "first line\n"
            + "%end 10 22 1\n"
            + "%window-add @2\n"
            + "%future-event alpha beta\n"
            + "%output %3 hi\\134there\\015\\012\\377\n"
            + "%exit normal\n"
        var input = Data("shell preamble".utf8)
        input += TmuxProtocolMarker.start
        input += Data(protocolLines.utf8)
        input += TmuxProtocolMarker.end

        let events = try parser.feed(input)
        let expected: [TmuxProtocolEvent] = [
            .protocolStarted,
            .commandBegin(.init(time: 10, commandNumber: 22, flags: 1)),
            .commandOutput(Data("first line".utf8)),
            .commandEnd(.init(time: 10, commandNumber: 22, flags: 1)),
            .notification(.known(.windowAdd, payload: Data("@2".utf8))),
            .notification(.unknown(name: "future-event", payload: Data("alpha beta".utf8))),
            .notification(.paneOutput(
                try #require(TmuxPaneID(rawValue: "%3")),
                Data([104, 105, 92, 116, 104, 101, 114, 101, 13, 10, 255])
            )),
            .notification(.exit(reason: Data("normal".utf8))),
            .protocolEnded,
        ]

        #expect(events == expected)
        #expect(try parser.finish().isEmpty)
    }

    @Test("两字段 tmux 2.6 guard 支持空输出与 error block")
    func parsesTwoFieldErrorBlock() throws {
        var parser = makeParser(commandGuardShape: .twoFields)
        let input = TmuxProtocolMarker.start
            + Data("%begin 11 23\n%error 11 23\n%exit\n".utf8)
            + TmuxProtocolMarker.end

        #expect(try parser.feed(input) == [
            .protocolStarted,
            .commandBegin(.init(time: 11, commandNumber: 23, flags: nil)),
            .commandError(.init(time: 11, commandNumber: 23, flags: nil)),
            .notification(.exit(reason: Data())),
            .protocolEnded,
        ])
    }

    @Test("marker、CRLF 与半行可跨任意 chunk，所有二分位置结果一致")
    func everyTwoChunkPartitionProducesSameEvents() throws {
        let protocolLines = "%begin 1 2 0\r\nvalue\r\n%end 1 2 0\r\n"
            + "%sessions-changed\r\n%exit bye\r\n"
        var input = Data("rc-noise".utf8)
        input += TmuxProtocolMarker.start
        input += Data(protocolLines.utf8)
        input += TmuxProtocolMarker.end
        let expected = try parse([input])

        for split in 0 ... input.count {
            let chunks = [Data(input.prefix(split)), Data(input.dropFirst(split))]
            #expect(try parse(chunks) == expected)
        }
        #expect(try parse(input.map { Data([$0]) }) == expected)
    }

    @Test("命令输出块内以百分号开头的普通输出不会误判为异步通知")
    func percentLinesInsideCommandBlockRemainOutput() throws {
        let protocolLines = "%begin 1 9 0\n"
            + "%window-add this-is-command-output\n"
            + "%end 1 9 0\n%exit\n"
        let input = TmuxProtocolMarker.start
            + Data(protocolLines.utf8)
            + TmuxProtocolMarker.end

        #expect(try parse([input]).contains(
            .commandOutput(Data("%window-add this-is-command-output".utf8))
        ))
    }

    @Test("命令输出块内以百分号开头的非 UTF-8 bytes 仍保持原样")
    func nonUTF8PercentLinesInsideCommandBlockRemainOutput() throws {
        let rawOutput = Data([UInt8(ascii: "%"), 0xFF, UInt8(ascii: "x")])
        var input = TmuxProtocolMarker.start
            + Data("%begin 1 9 0\n".utf8)
        input += rawOutput
        input += Data("\n%end 1 9 0\n%exit\n".utf8)
        input += TmuxProtocolMarker.end

        #expect(try parse([input]).contains(.commandOutput(rawOutput)))
    }

    @Test("extended-output 解码 pane、延迟与冒号后的非 UTF-8 数据")
    func parsesExtendedPaneOutput() throws {
        let input = TmuxProtocolMarker.start
            + Data("%extended-output %8 1234 : a\\000b\\377\n%exit\n".utf8)
            + TmuxProtocolMarker.end

        #expect(try parse([input]).contains(
            .notification(.extendedPaneOutput(
                try #require(TmuxPaneID(rawValue: "%8")),
                ageMilliseconds: 1234,
                data: Data([97, 0, 98, 255])
            ))
        ))
    }

    @Test("dialect 严格区分两字段与三字段 guard")
    func rejectsWrongGuardShape() throws {
        var two = makeParser(commandGuardShape: .twoFields)
        _ = try two.feed(TmuxProtocolMarker.start)
        #expect(throws: TmuxProtocolParserError.invalidCommandGuard) {
            try two.feed(Data("%begin 1 2 0\n".utf8))
        }

        var three = makeParser()
        _ = try three.feed(TmuxProtocolMarker.start)
        #expect(throws: TmuxProtocolParserError.invalidCommandGuard) {
            try three.feed(Data("%begin 1 2\n".utf8))
        }
    }

    @Test("nested block、无起点终止与 guard mismatch 都触发协议错误")
    func rejectsInvalidBlockSequences() throws {
        try expectError(
            "%begin 1 2 0\n%begin 1 3 0\n",
            .nestedCommandBlock
        )
        try expectError("%end 1 2 0\n", .unmatchedCommandTerminator)
        try expectError(
            "%begin 1 2 0\n%end 1 3 0\n",
            .commandGuardMismatch(
                expected: .init(time: 1, commandNumber: 2, flags: 0),
                actual: .init(time: 1, commandNumber: 3, flags: 0)
            )
        )
    }

    @Test("pane output 拒绝非法 ID、截断八进制和非八进制 escape")
    func rejectsInvalidPaneOutput() throws {
        for line in [
            "%output @1 abc\n",
            "%output %1 abc\\12\n",
            "%output %1 abc\\xyz\n",
            "%output %1 abc\\777\n",
        ] {
            try expectError(line, .invalidPaneOutput)
        }

        var rawControl = TmuxProtocolMarker.start + Data("%output %1 a".utf8)
        rawControl.append(0x01)
        rawControl += Data("b\n".utf8)
        var parser = makeParser()
        #expect(throws: TmuxProtocolParserError.invalidPaneOutput) {
            try parser.feed(rawControl)
        }
    }

    @Test("空 pane 输出合法且协议结束后拒绝残留 bytes")
    func acceptsEmptyPaneOutputAndRejectsTrailingData() throws {
        let paneID = try #require(TmuxPaneID(rawValue: "%1"))
        let input = TmuxProtocolMarker.start
            + Data("%output %1 \n%exit\n".utf8)
            + TmuxProtocolMarker.end
        var parser = makeParser()

        #expect(try parser.feed(input).contains(.notification(.paneOutput(paneID, Data()))))
        #expect(throws: TmuxProtocolParserError.unexpectedDataAfterEnd) {
            try parser.feed(Data("trailing".utf8))
        }
        #expect(throws: TmuxProtocolParserError.parserFailed) {
            try parser.feed(Data())
        }
    }

    @Test("command block 外的普通文本不是合法 Control Mode 记录")
    func rejectsPlainTextOutsideCommandBlock() throws {
        var parser = makeParser()
        _ = try parser.feed(TmuxProtocolMarker.start)

        #expect(throws: TmuxProtocolParserError.unexpectedProtocolData) {
            try parser.feed(Data("shell noise\n".utf8))
        }
    }

    @Test("preamble 与 pending line 都有硬上限")
    func enforcesPreambleAndLineLimits() throws {
        var preamble = TmuxProtocolParser(
            dialect: .init(commandGuardShape: .threeFields, snapshotCodec: .quoted),
            limits: .init(maxPreambleBytes: 4, maxLineBytes: 8)
        )
        #expect(throws: TmuxProtocolParserError.preambleTooLong(limit: 4)) {
            try preamble.feed(Data("12345".utf8))
        }

        var line = TmuxProtocolParser(
            dialect: .init(commandGuardShape: .threeFields, snapshotCodec: .quoted),
            limits: .init(maxPreambleBytes: 4, maxLineBytes: 8)
        )
        _ = try line.feed(TmuxProtocolMarker.start)
        #expect(throws: TmuxProtocolParserError.lineTooLong(limit: 8)) {
            try line.feed(Data("123456789".utf8))
        }

        var exactPreamble = TmuxProtocolParser(
            dialect: .init(commandGuardShape: .threeFields, snapshotCodec: .quoted),
            limits: .init(maxPreambleBytes: 4, maxLineBytes: 8)
        )
        #expect(try exactPreamble.feed(
            Data("1234".utf8) + TmuxProtocolMarker.start
        ) == [.protocolStarted])
    }

    @Test("EOF 会区分缺 marker、半行、未闭合 block 与缺 ST")
    func finishRejectsIncompleteStates() throws {
        var missingStart = makeParser()
        #expect(throws: TmuxProtocolParserError.missingProtocolStart) {
            try missingStart.finish()
        }

        var partialLine = makeParser()
        _ = try partialLine.feed(TmuxProtocolMarker.start + Data("partial".utf8))
        #expect(throws: TmuxProtocolParserError.incompleteLine) {
            try partialLine.finish()
        }

        var openBlock = makeParser()
        _ = try openBlock.feed(TmuxProtocolMarker.start + Data("%begin 1 2 0\n".utf8))
        #expect(throws: TmuxProtocolParserError.incompleteCommandBlock) {
            try openBlock.finish()
        }

        var missingST = makeParser()
        _ = try missingST.feed(TmuxProtocolMarker.start + Data("%exit\n".utf8))
        #expect(throws: TmuxProtocolParserError.missingProtocolEnd) {
            try missingST.finish()
        }
    }

    @Test("首次协议错误后 parser 进入 failed，禁止继续消费不可信流")
    func failureIsTerminal() throws {
        var parser = makeParser()
        _ = try parser.feed(TmuxProtocolMarker.start)
        #expect(throws: TmuxProtocolParserError.unmatchedCommandTerminator) {
            try parser.feed(Data("%end 1 2 0\n".utf8))
        }
        #expect(throws: TmuxProtocolParserError.parserFailed) {
            try parser.feed(Data("%sessions-changed\n".utf8))
        }
    }

    private func parse(_ chunks: [Data]) throws -> [TmuxProtocolEvent] {
        var parser = makeParser()
        var events: [TmuxProtocolEvent] = []
        for chunk in chunks {
            events += try parser.feed(chunk)
        }
        events += try parser.finish()
        return events
    }

    private func expectError(
        _ protocolLines: String,
        _ expected: TmuxProtocolParserError
    ) throws {
        var parser = makeParser()
        _ = try parser.feed(TmuxProtocolMarker.start)
        #expect(throws: expected) {
            try parser.feed(Data(protocolLines.utf8))
        }
    }

    private func makeParser(
        commandGuardShape: TmuxCommandGuardShape = .threeFields
    ) -> TmuxProtocolParser {
        TmuxProtocolParser(dialect: .init(
            commandGuardShape: commandGuardShape,
            snapshotCodec: .quoted
        ))
    }
}
