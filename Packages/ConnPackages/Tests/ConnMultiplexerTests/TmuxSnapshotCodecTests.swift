import ConnMultiplexer
import Foundation
import Testing

@Suite("tmux snapshot codecs")
struct TmuxSnapshotCodecTests {
    @Test("workspace catalog framing decodes identity and sessions")
    func decodesWorkspaceCatalogFraming() throws {
        let output = Data(
            ("\"I\" \"/tmp/tmux-1000/default\" \"1234\" \"987654\"\n"
                + "\"S\" \"$7\" \"ops\" \"\"").utf8
        )
        #expect(try TmuxQuotedSnapshotCodec().decode(
            commandOutputLines: [output],
            expectedFieldCount: 4
        ) == [
            ["I", "/tmp/tmux-1000/default", "1234", "987654"],
            ["S", "$7", "ops", ""],
        ])
    }

    @Test("quoted codec decodes empty fields, Unicode, spaces, quotes, backslashes and tabs")
    func decodesQuotedFields() throws {
        let wireString = "\"$1\" \"\" \"开发\\ session\" "
            + "\"say\\ \\\"hi\\\"\\ and\\ \\\\path\" \"a\\\tb\""
        let wire = Data(wireString.utf8)

        #expect(try TmuxQuotedSnapshotCodec().decode(
            commandOutputLines: [wire],
            expectedFieldCount: 5
        ) == [["$1", "", "开发 session", "say \"hi\" and \\path", "a\tb"]])
    }

    @Test("escaped physical newline remains inside a field while unescaped newline ends a record")
    func distinguishesEscapedNewlinesFromRecords() throws {
        let lines = [
            Data(#""$1" "first\"#.utf8),
            Data(#"line""#.utf8),
            Data(#""$2" "second""#.utf8),
        ]

        #expect(try TmuxQuotedSnapshotCodec().decode(
            commandOutputLines: lines,
            expectedFieldCount: 2
        ) == [
            ["$1", "first\nline"],
            ["$2", "second"],
        ])
    }

    @Test("quoted codec rejects malformed framing, escapes, UTF-8 and field counts")
    func rejectsMalformedQuotedRecords() {
        assertQuotedError(#""$1" "unterminated"#, .unterminatedField, fields: 2)
        assertQuotedError(#""$1" "escape\"#, .unterminatedEscape, fields: 2)
        assertQuotedError(#""$1"x "name""#, .invalidRecord, fields: 2)
        assertQuotedError(#""$1"  "name""#, .invalidRecord, fields: 2)
        assertQuotedError(#""$1""#, .fieldCountMismatch(expected: 2, actual: 1), fields: 2)

        var invalidUTF8 = Data(#""$1" ""#.utf8)
        invalidUTF8.append(0xFF)
        invalidUTF8 += Data(#"""#.utf8)
        #expect(throws: TmuxSnapshotCodecError.invalidUTF8) {
            try TmuxQuotedSnapshotCodec().decode(
                commandOutputLines: [invalidUTF8],
                expectedFieldCount: 2
            )
        }
    }

    @Test("quoted codec bounds wire bytes, fields, records and decoded field bytes")
    func enforcesQuotedLimits() {
        let outputLimit = TmuxQuotedSnapshotCodec(limits: .init(
            maxOutputBytes: 8,
            maxRecords: 2,
            maxFieldsPerRecord: 2,
            maxFieldBytes: 4
        ))
        #expect(throws: TmuxSnapshotCodecError.outputTooLarge(limit: 8)) {
            try outputLimit.decode(
                commandOutputLines: [Data(#""123456789""#.utf8)],
                expectedFieldCount: 1
            )
        }

        let fieldLimit = TmuxQuotedSnapshotCodec(limits: .init(
            maxOutputBytes: 128,
            maxRecords: 2,
            maxFieldsPerRecord: 2,
            maxFieldBytes: 4
        ))
        #expect(throws: TmuxSnapshotCodecError.fieldTooLong(limit: 4)) {
            try fieldLimit.decode(
                commandOutputLines: [Data(#""12345""#.utf8)],
                expectedFieldCount: 1
            )
        }
        #expect(throws: TmuxSnapshotCodecError.tooManyFields(limit: 2)) {
            try fieldLimit.decode(
                commandOutputLines: [Data(#""1" "2" "3""#.utf8)],
                expectedFieldCount: 3
            )
        }
        #expect(throws: TmuxSnapshotCodecError.tooManyRecords(limit: 2)) {
            try fieldLimit.decode(
                commandOutputLines: [Data("\"1\"\n\"2\"\n\"3\"".utf8)],
                expectedFieldCount: 1
            )
        }
    }

    @Test("legacy codec decodes exactly one independently queried text field")
    func decodesLegacySingleField() throws {
        let codec = TmuxLegacySnapshotCodec()

        #expect(try codec.decodeSingleField(commandOutputLines: [Data()]) == "")
        #expect(try codec.decodeSingleField(commandOutputLines: [
            Data("first".utf8),
            Data("second | \t \"quoted\"".utf8),
        ]) == "first\nsecond | \t \"quoted\"")
    }

    @Test("legacy codec rejects absent, invalid and oversized single-field output")
    func rejectsInvalidLegacyField() {
        let codec = TmuxLegacySnapshotCodec(maxFieldBytes: 4)
        #expect(throws: TmuxSnapshotCodecError.missingLegacyField) {
            try codec.decodeSingleField(commandOutputLines: [])
        }
        #expect(throws: TmuxSnapshotCodecError.fieldTooLong(limit: 4)) {
            try codec.decodeSingleField(commandOutputLines: [Data("12345".utf8)])
        }
        #expect(throws: TmuxSnapshotCodecError.invalidUTF8) {
            try codec.decodeSingleField(commandOutputLines: [Data([0xFF])])
        }
    }

    private func assertQuotedError(
        _ value: String,
        _ expected: TmuxSnapshotCodecError,
        fields: Int
    ) {
        #expect(throws: expected) {
            try TmuxQuotedSnapshotCodec().decode(
                commandOutputLines: [Data(value.utf8)],
                expectedFieldCount: fields
            )
        }
    }
}
