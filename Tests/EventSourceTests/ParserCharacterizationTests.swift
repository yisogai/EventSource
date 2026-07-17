import Foundation
import Testing
@testable import EventSource

/// Pins down `EventBuffer` parsing behavior against the WHATWG SSE spec.
///
/// History: this suite began as a characterization baseline of the pre-rewrite
/// parser. Tests named `spec_<area>_<condition>_was<old>_now<new>` mark inputs
/// whose observable behavior CHANGED in the spec-compliance rewrite; their
/// comments describe the old behavior. They map 1:1 to BEHAVIOR_CHANGES.md.
@Suite("EventBuffer parsing (WHATWG-conformant)")
struct ParserCharacterizationTests {

    // MARK: - 1. Single-line data

    @Test func singleLineData_typeIsMessage() {
        let recorder = ParseRecorder()
        recorder.feed("data: hello\n\n")
        #expect(recorder.events == [MessageEvent(lastEventId: nil, type: "message", data: "hello")])
    }

    // MARK: - 2. Multiple data lines are newline-joined

    @Test func multipleDataLines_areJoinedWithNewline() {
        let recorder = ParseRecorder()
        recorder.feed("data: a\ndata: b\ndata: c\n\n")
        #expect(recorder.events == [MessageEvent(lastEventId: nil, type: "message", data: "a\nb\nc")])
    }

    // MARK: - 3. Empty data value alone

    // NOT a spec diff (an earlier analysis got the step order backwards):
    // WHATWG's dispatch checks for an empty data buffer BEFORE stripping the
    // trailing LF. A lone "data:" line leaves the buffer as "\n" (not empty),
    // so the spec dispatches an event with data "" — matching this behavior.
    @Test func emptyDataValue_alone() {
        let recorder = ParseRecorder()
        recorder.feed("data:\n\n")
        #expect(recorder.events == [MessageEvent(lastEventId: nil, type: "message", data: "")])
    }

    // MARK: - 4. Non-empty data line followed by empty data line

    @Test func dataLine_followedByEmptyDataLine() {
        let recorder = ParseRecorder()
        recorder.feed("data: a\ndata:\n\n")
        #expect(recorder.events == [MessageEvent(lastEventId: nil, type: "message", data: "a\n")])
    }

    // MARK: - 5. id-only event: not delivered, but lastEventIdHandler still fires

    @Test func idOnly_noData_notDelivered_butLastEventIdHandlerFires() {
        let recorder = ParseRecorder()
        recorder.feed("id: 9\n\n")
        #expect(recorder.events.isEmpty)
        #expect(recorder.lastEventIdUpdates == ["9"])
    }

    // MARK: - 6. event: + data: sets type

    @Test func eventField_setsType() {
        let recorder = ParseRecorder()
        recorder.feed("event: update\ndata: x\n\n")
        #expect(recorder.events == [MessageEvent(lastEventId: nil, type: "update", data: "x")])
    }

    // MARK: - 7. type resets between events

    @Test func type_resetsBetweenEvents() {
        let recorder = ParseRecorder()
        recorder.feed("event: a\ndata: 1\n\n")
        recorder.feed("data: 2\n\n")
        #expect(recorder.events == [
            MessageEvent(lastEventId: nil, type: "a", data: "1"),
            MessageEvent(lastEventId: nil, type: "message", data: "2"),
        ])
    }

    // MARK: - 8. empty event: value does not change type

    @Test func emptyEventValue_doesNotChangeType() {
        let recorder = ParseRecorder()
        recorder.feed("event:\ndata: x\n\n")
        #expect(recorder.events == [MessageEvent(lastEventId: nil, type: "message", data: "x")])
    }

    // MARK: - 9. id: sets lastEventId, which persists to later events

    @Test func idField_setsLastEventId_andPersistsAcrossEvents() {
        let recorder = ParseRecorder()
        recorder.feed("id: 42\ndata: x\n\n")
        recorder.feed("data: y\n\n")
        #expect(recorder.events == [
            MessageEvent(lastEventId: "42", type: "message", data: "x"),
            MessageEvent(lastEventId: "42", type: "message", data: "y"),
        ])
        #expect(recorder.lastEventIdUpdates == ["42"])
    }

    // MARK: - 10. empty id: resets lastEventId to nil

    // BEHAVIOR CHANGE (f): an "id" field with an empty value sets the ID buffer
    // to the empty string, per spec. The old regex-based parser collapsed the
    // empty value to Swift `nil`, so lastEventId used to become nil here.
    @Test func spec_id_emptyValue_wasNil_nowEmptyString() {
        let recorder = ParseRecorder()
        recorder.feed("id: 42\ndata: x\n\n")
        recorder.feed("id:\ndata: y\n\n")
        #expect(recorder.events == [
            MessageEvent(lastEventId: "42", type: "message", data: "x"),
            MessageEvent(lastEventId: "", type: "message", data: "y"),
        ])
        #expect(recorder.lastEventIdUpdates == ["42", ""])
    }

    // MARK: - 11. id containing NUL is accepted by the current implementation

    // BEHAVIOR CHANGE (f): an "id" field whose value contains U+0000 NULL is
    // ignored, per spec. The old parser had no NUL check and accepted it.
    @Test func spec_id_withNUL_wasAccepted_nowIgnored() {
        let recorder = ParseRecorder()
        recorder.feed("id: a\u{0000}b\ndata: x\n\n")
        #expect(recorder.lastEventIdUpdates.isEmpty)
        #expect(recorder.events == [MessageEvent(lastEventId: nil, type: "message", data: "x")])
    }

    // MARK: - 12. retry: converts milliseconds to seconds

    @Test func retryField_convertsMillisecondsToSeconds() {
        let recorder = ParseRecorder()
        recorder.feed("retry: 5000\n\n")
        #expect(recorder.retryTimeUpdates == [5.0])
    }

    // MARK: - 13. negative retry value is accepted

    // BEHAVIOR CHANGE (e): the "retry" value must consist entirely of ASCII
    // digits, per spec; a leading '-' makes the field ignored. The old parser
    // used `Int(value)` and accepted "-1" as a negative retry time.
    @Test func spec_retry_negative_wasAccepted_nowIgnored() {
        let recorder = ParseRecorder()
        recorder.feed("retry: -1\n\n")
        #expect(recorder.retryTimeUpdates.isEmpty)
    }

    // MARK: - 14. non-numeric / empty retry values are ignored

    @Test(arguments: ["retry: abc\n\n", "retry:\n\n"])
    func invalidRetryValue_isIgnored(input: String) {
        let recorder = ParseRecorder()
        recorder.feed(input)
        #expect(recorder.retryTimeUpdates.isEmpty)
    }

    // MARK: - 15. comment lines

    @Test func commentLine_isIgnored() {
        let recorder = ParseRecorder()
        recorder.feed(": comment\ndata: x\n\n")
        #expect(recorder.events == [MessageEvent(lastEventId: nil, type: "message", data: "x")])
    }

    @Test func commentLineWithEmbeddedColons_currentBehavior() {
        let recorder = ParseRecorder()
        recorder.feed(": a:b:c\ndata: x\n\n")
        #expect(recorder.events == [MessageEvent(lastEventId: nil, type: "message", data: "x")])
    }

    // MARK: - 16. data value retains embedded colons

    @Test func dataValue_retainsEmbeddedColons() {
        let recorder = ParseRecorder()
        recorder.feed("data: a:b:c\n\n")
        #expect(recorder.events == [MessageEvent(lastEventId: nil, type: "message", data: "a:b:c")])
    }

    // MARK: - 17. field line without a colon is ignored

    // BEHAVIOR CHANGE (c): a line with no ':' is a field whose name is the
    // whole line and whose value is "", per spec — a bare "data" line now
    // contributes an empty data line, so this dispatches an empty-data event.
    // The old regex required a ':' and silently dropped the line (no event).
    @Test func spec_line_noColon_wasIgnored_nowFieldWithEmptyValue() {
        let recorder = ParseRecorder()
        recorder.feed("data\n\n")
        #expect(recorder.events == [MessageEvent(lastEventId: nil, type: "message", data: "")])
    }

    // MARK: - 18. two spaces after colon: only one is stripped

    @Test func dataValue_twoSpacesAfterColon_onlyOneStripped() {
        let recorder = ParseRecorder()
        recorder.feed("data:  x\n\n")
        #expect(recorder.events == [MessageEvent(lastEventId: nil, type: "message", data: " x")])
    }

    // MARK: - 19. tab after colon is stripped by \s?

    // BEHAVIOR CHANGE (d): only a single leading U+0020 SPACE is stripped from
    // a field value, per spec; a leading tab stays in the value. The old
    // parser's `\s?` regex stripped a leading tab too.
    @Test func spec_value_leadingTab_wasStripped_nowPreserved() {
        let recorder = ParseRecorder()
        recorder.feed("data:\tx\n\n")
        #expect(recorder.events == [MessageEvent(lastEventId: nil, type: "message", data: "\tx")])
    }

    // MARK: - 20. no space after colon

    @Test func dataValue_noSpaceAfterColon() {
        let recorder = ParseRecorder()
        recorder.feed("data:x\n\n")
        #expect(recorder.events == [MessageEvent(lastEventId: nil, type: "message", data: "x")])
    }

    // The leading-space strip works at the byte level: a combining character
    // right after the space must not prevent the strip (grapheme-level
    // `value.first == " "` would see one combined cluster and fail).
    @Test func dataValue_leadingSpaceBeforeCombiningChar_isStripped() {
        let recorder = ParseRecorder()
        recorder.feed("data: \u{0301}x\n\n")
        #expect(recorder.events == [MessageEvent(lastEventId: nil, type: "message", data: "\u{0301}x")])
    }

    // MARK: - 21. leading BOM
    //
    // The parser now strips a single leading UTF-8 BOM at the byte level, per
    // spec. (The old parser produced the same result only incidentally, via a
    // side effect of `String(data:encoding:.utf8)`.) A BOM split across chunk
    // boundaries is also handled: the parser waits until 3 bytes are available.
    @Test func leadingBOM_isStrippedOncePerStream() {
        let recorder = ParseRecorder()
        recorder.feed("\u{FEFF}data: x\n\n")
        #expect(recorder.events == [MessageEvent(lastEventId: nil, type: "message", data: "x")])
    }

    @Test func leadingBOM_splitAcrossChunks_isStillStripped() {
        let recorder = ParseRecorder()
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        recorder.feed(Data(bom.prefix(1)))
        recorder.feed(Data(bom.dropFirst(1)))
        recorder.feed("data: x\n\n")
        #expect(recorder.events == [MessageEvent(lastEventId: nil, type: "message", data: "x")])
    }

    // Only the FIRST BOM is stripped; a second one is stream content. It lands
    // in the field name ("\u{FEFF}data"), which is unknown and ignored.
    @Test func secondBOM_isNotStripped() {
        let recorder = ParseRecorder()
        recorder.feed("\u{FEFF}\u{FEFF}data: a\ndata: b\n\n")
        #expect(recorder.events == [MessageEvent(lastEventId: nil, type: "message", data: "b")])
    }

    // MARK: - 22. delimiter variants, each in isolation

    @Test func delimiter_LFLF() {
        let recorder = ParseRecorder()
        recorder.feed("data: a\n\n")
        #expect(recorder.events == [MessageEvent(lastEventId: nil, type: "message", data: "a")])
    }

    // BEHAVIOR CHANGE (j): a trailing CR cannot be classified yet (a LF might
    // follow to form CRLF), so the line it terminates is held back until the
    // next byte arrives or the stream ends. The old delimiter search dispatched
    // "data: a\r\r" immediately; the new parser dispatches once the next byte
    // or end-of-stream disambiguates. Chromium behaves the same way.
    @Test func spec_delimiter_CRCR_wasImmediate_nowHeldUntilNextByteOrEOF() {
        let recorder = ParseRecorder()
        recorder.feed("data: a\r\r")
        #expect(recorder.events.isEmpty)
        recorder.finishStream()
        #expect(recorder.events == [MessageEvent(lastEventId: nil, type: "message", data: "a")])
    }

    @Test func delimiter_CRCR_unblockedByNextByte() {
        let recorder = ParseRecorder()
        recorder.feed("data: a\r\rdata: b\r\r")
        #expect(recorder.events == [MessageEvent(lastEventId: nil, type: "message", data: "a")])
        recorder.finishStream()
        #expect(recorder.events == [
            MessageEvent(lastEventId: nil, type: "message", data: "a"),
            MessageEvent(lastEventId: nil, type: "message", data: "b"),
        ])
    }

    @Test func delimiter_CRLFCRLF() {
        let recorder = ParseRecorder()
        recorder.feed("data: a\r\n\r\n")
        #expect(recorder.events == [MessageEvent(lastEventId: nil, type: "message", data: "a")])
    }

    // MARK: - 23. mixed delimiter sequences

    // BEHAVIOR CHANGE (b): the stream is now parsed line-by-line (CR, LF, or
    // CRLF each terminate a line) with a blank line dispatching, per spec.
    // "data: a" (LF) + blank line (CR) + "data: b" is two events. The old
    // fixed-priority delimiter search joined this into one event "a\nb".
    @Test func spec_boundary_mixedLFCR_wasJoined_nowTwoEvents() {
        let recorder = ParseRecorder()
        recorder.feed("data: a\n\rdata: b\n\n")
        #expect(recorder.events == [
            MessageEvent(lastEventId: nil, type: "message", data: "a"),
            MessageEvent(lastEventId: nil, type: "message", data: "b"),
        ])
    }

    // Same observable outcome as before the rewrite (the old delimiter search
    // happened to find the right boundary here), kept to pin the case down.
    @Test func mixedDelimiters_CRLFthenLF_currentBehavior() {
        let recorder = ParseRecorder()
        recorder.feed("data: a\r\n\ndata: b\n\n")
        #expect(recorder.events == [
            MessageEvent(lastEventId: nil, type: "message", data: "a"),
            MessageEvent(lastEventId: nil, type: "message", data: "b"),
        ])
    }

    // MARK: - 24. CRLF line endings within a single event

    @Test func crlfLineEndings_withinEvent() {
        let recorder = ParseRecorder()
        recorder.feed("data: a\r\ndata: b\r\n\r\n")
        #expect(recorder.events == [MessageEvent(lastEventId: nil, type: "message", data: "a\nb")])
    }

    // MARK: - 25. U+2028 / U+2029 inside a data value

    // BEHAVIOR CHANGE (g): only CR, LF, and CRLF are line terminators, per
    // spec; U+2028 stays in the data value verbatim. The old parser's
    // `enumerateLines` split on U+2028 and then dropped the colonless
    // remainder, truncating the value to "a".
    @Test func spec_lineSep_u2028_wasTruncated_nowPreserved() {
        let recorder = ParseRecorder()
        recorder.feed("data: a\u{2028}b\n\n")
        #expect(recorder.events == [MessageEvent(lastEventId: nil, type: "message", data: "a\u{2028}b")])
    }

    // BEHAVIOR CHANGE (g): same as above, for U+2029 (PARAGRAPH SEPARATOR).
    @Test func spec_lineSep_u2029_wasTruncated_nowPreserved() {
        let recorder = ParseRecorder()
        recorder.feed("data: a\u{2029}b\n\n")
        #expect(recorder.events == [MessageEvent(lastEventId: nil, type: "message", data: "a\u{2029}b")])
    }

    // MARK: - 26. unknown field is ignored

    @Test func unknownField_isIgnored() {
        let recorder = ParseRecorder()
        recorder.feed("foo: bar\n\n")
        #expect(recorder.events.isEmpty)
    }

    // MARK: - 27. field names are case-sensitive

    // Not a SPEC-DIFF: WHATWG field-name matching is case-sensitive too ("Data" is
    // not "data"), so this already matches the spec. Included to pin the behavior
    // down explicitly rather than leave it implicit.
    @Test func fieldName_isCaseSensitive() {
        let recorder = ParseRecorder()
        recorder.feed("Data: x\n\n")
        #expect(recorder.events.isEmpty)
    }

    // MARK: - 28. empty input / blank-lines-only input

    @Test func emptyInput_producesNoEvents() {
        let recorder = ParseRecorder()
        recorder.feed(Data())
        #expect(recorder.events.isEmpty)
    }

    @Test func blankLinesOnly_producesNoEvents() {
        let recorder = ParseRecorder()
        recorder.feed("\n\n\n\n")
        #expect(recorder.events.isEmpty)
    }

    // MARK: - 29. unterminated event is buffered until the delimiter arrives

    @Test func unterminatedEvent_isDeliveredOnceDelimiterArrives() {
        let recorder = ParseRecorder()
        recorder.feed("data: a")
        #expect(recorder.events.isEmpty)
        recorder.feed("\n\n")
        #expect(recorder.events == [MessageEvent(lastEventId: nil, type: "message", data: "a")])
    }

    // MARK: - 30. multibyte data values

    @Test func multibyteData_japaneseAndEmoji() {
        let recorder = ParseRecorder()
        recorder.feed("data: 日本語😀\n\n")
        #expect(recorder.events == [MessageEvent(lastEventId: nil, type: "message", data: "日本語😀")])
    }

    @Test func multibyteData_zwjEmoji() {
        let recorder = ParseRecorder()
        recorder.feed("data: 👨‍👩‍👧‍👦\n\n")
        #expect(recorder.events == [MessageEvent(lastEventId: nil, type: "message", data: "👨‍👩‍👧‍👦")])
    }

    // MARK: - 31. chunked delivery split mid-multibyte-character

    @Test func chunkedDelivery_splitMidMultibyteCharacter_matchesSingleShotResult() {
        let full = "data: 日本語😀\n\n"
        let fullData = Data(full.utf8)

        // Split inside the multi-byte encoding of "😀" (which starts partway
        // through the byte sequence), so neither chunk is valid UTF-8 on its own.
        let emojiStartIndex = full.range(of: "😀")!.lowerBound
        let emojiByteOffset = full.utf8.distance(from: full.utf8.startIndex, to: emojiStartIndex.samePosition(in: full.utf8)!)
        let splitPoint = emojiByteOffset + 1
        #expect(splitPoint > 0 && splitPoint < fullData.count)

        let firstChunk = fullData.subdata(in: 0..<splitPoint)
        let secondChunk = fullData.subdata(in: splitPoint..<fullData.count)

        let recorder = ParseRecorder()
        recorder.feed(firstChunk)
        #expect(recorder.events.isEmpty)
        recorder.feed(secondChunk)

        #expect(recorder.events == [MessageEvent(lastEventId: nil, type: "message", data: "日本語😀")])
    }

    // MARK: - 32. delimiter itself split across two appends

    @Test func delimiter_CRLFCRLF_splitAcrossTwoAppends() {
        let recorder = ParseRecorder()
        recorder.feed("data: a\r\n")
        #expect(recorder.events.isEmpty)
        recorder.feed("\r\n")
        #expect(recorder.events == [MessageEvent(lastEventId: nil, type: "message", data: "a")])
    }

    // MARK: - 33. invalid UTF-8 bytes are silently discarded

    // BEHAVIOR CHANGE (i): malformed UTF-8 byte sequences are replaced with
    // U+FFFD REPLACEMENT CHARACTER and decoding continues, per the Encoding
    // Standard. The old parser's all-or-nothing `String(data:encoding:)`
    // silently discarded the entire event on any invalid byte.
    @Test func spec_invalidUTF8_wasDiscarded_nowReplacementCharacter() {
        let recorder = ParseRecorder()
        // "data: " + 0xFF 0xFE + LF LF
        recorder.feed(Data([0x64, 0x61, 0x74, 0x61, 0x3A, 0x20, 0xFF, 0xFE, 0x0A, 0x0A]))
        #expect(recorder.events == [MessageEvent(lastEventId: nil, type: "message", data: "\u{FFFD}\u{FFFD}")])
    }
}
