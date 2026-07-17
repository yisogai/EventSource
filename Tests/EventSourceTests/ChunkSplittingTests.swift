import Foundation
import Testing
@testable import EventSource

/// Invariant: however a byte stream is split into chunks, the parsed event
/// sequence (and id/retry updates) must be identical to single-shot parsing.
@Suite("Chunk splitting invariance")
struct ChunkSplittingTests {
    static let fixtures: [(name: String, bytes: [UInt8])] = [
        ("multibyteInData", Array("data: 日本😀語\n\n".utf8)),
        ("zwjEmoji", Array("data: 👨‍👩‍👧‍👦\n\n".utf8)),
        ("crlfDelimiters", Array("data: a\r\n\r\ndata: b\r\n\r\n".utf8)),
        ("crOnlyDelimiters", Array("data: a\r\rdata: b\r\r".utf8)),
        ("bomThenData", [0xEF, 0xBB, 0xBF] + Array("data: x\n\n".utf8)),
        ("idThenData", Array("id: 100\ndata: y\n\n".utf8)),
        ("multiEvent", Array("event: e1\ndata: 1\n\nretry: 250\n: c\ndata: 2\ndata: 3\n\n".utf8)),
    ]

    private func parse(_ chunks: [[UInt8]]) -> ([MessageEvent], [String?], [TimeInterval]) {
        let recorder = ParseRecorder()
        for chunk in chunks {
            recorder.feed(Data(chunk))
        }
        recorder.finishStream()
        return (recorder.events, recorder.lastEventIdUpdates, recorder.retryTimeUpdates)
    }

    @Test(arguments: fixtures.map(\.name))
    func twoChunkSplit_atEveryBytePosition_matchesSingleShot(fixtureName: String) {
        let bytes = Self.fixtures.first { $0.name == fixtureName }!.bytes
        let expected = parse([bytes])
        #expect(!expected.0.isEmpty)

        for split in 1..<bytes.count {
            let actual = parse([Array(bytes[..<split]), Array(bytes[split...])])
            #expect(actual == expected, "split at byte \(split)")
        }
    }

    @Test(arguments: fixtures.map(\.name))
    func threeChunkSplit_atEveryBytePositionPair_matchesSingleShot(fixtureName: String) {
        let bytes = Self.fixtures.first { $0.name == fixtureName }!.bytes
        let expected = parse([bytes])

        for i in 1..<bytes.count {
            for j in (i + 1)..<bytes.count {
                let actual = parse([Array(bytes[..<i]), Array(bytes[i..<j]), Array(bytes[j...])])
                #expect(actual == expected, "split at bytes \(i), \(j)")
            }
        }
    }

    // Seeded fuzz: random streams, random chunking. Reproducible via the seed
    // logged on failure.
    @Test func randomStreams_randomChunking_matchesSingleShot() {
        var rng = LCG(seed: 0x5EED_2026)
        let lineEndings = ["\n", "\r", "\r\n"]
        let linePool = [
            "data: hello", "data:", "data",  "data: 日本語😀", "data:  padded",
            "event: tick", "event:", "id: 7", "id:", "id: a\u{0000}b",
            "retry: 120", "retry: -3", ": comment", "junk", "foo: bar", "",
        ]

        for iteration in 0..<200 {
            var stream = ""
            if rng.next(bound: 4) == 0 { stream += "\u{FEFF}" }
            for _ in 0..<rng.next(bound: 12) {
                stream += linePool[Int(rng.next(bound: UInt64(linePool.count)))]
                stream += lineEndings[Int(rng.next(bound: 3))]
            }
            let bytes = Array(stream.utf8)
            guard bytes.count >= 2 else { continue }

            var chunks: [[UInt8]] = []
            var start = 0
            while start < bytes.count {
                let len = 1 + Int(rng.next(bound: 6))
                let end = min(start + len, bytes.count)
                chunks.append(Array(bytes[start..<end]))
                start = end
            }

            let expected = parse([bytes])
            let actual = parse(chunks)
            #expect(actual == expected, "iteration \(iteration), seed 0x5EED_2026, stream: \(stream.debugDescription)")
        }
    }
}

/// Deterministic linear congruential generator (Numerical Recipes constants).
private struct LCG {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }

    mutating func next(bound: UInt64) -> UInt64 {
        next() % bound
    }
}
