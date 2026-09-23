import Foundation
@testable import OpenCastCore
import Testing

@Suite("Episode share token encoder")
struct EpisodeShareTokenEncoderTests {
    @Test("Every fixture vector encodes byte for byte")
    func vectorsEncodeByteForByte() throws {
        let fixture = try EpisodeShareTokenVectors.load()
        #expect(fixture.format == "opencast-episode-share-token")
        #expect(fixture.version == "1")
        #expect(fixture.vectors.count >= 7)

        for vector in fixture.vectors {
            // Byte arrays, not Strings: Swift equates canonically equivalent
            // strings, the worker compares code units.
            let payload = try vector.payload.sharePayload()
            #expect(payload.tupleFields.map { Array($0.utf8) } == vector.payload.fields.map { Array($0.utf8) },
                    "\(vector.name) payload is not sanitised")

            let token = try EpisodeShareTokenEncoder.token(for: payload)
            #expect(token == vector.token, "\(vector.name) token drifted")
            #expect(token.utf8.count <= vector.maxTokenLength, "\(vector.name) exceeds maxTokenLength")
            #expect(try EpisodeShareTokenDecoder.tupleFields(from: token).map { Array($0.utf8) }
                == vector.payload.fields.map { Array($0.utf8) })
        }
    }

    @Test("The dictionary vector's length cap fails an encoder without the dictionary")
    func dictionaryVectorCatchesMissingDictionary() throws {
        let fixture = try EpisodeShareTokenVectors.load()
        let vector = try #require(fixture.vectors.first {
            $0.name == EpisodeShareTokenVectors.dictionarySensitivityVectorName
        })

        let withoutDictionary = try EpisodeShareTokenDecoder.tokenWithoutDictionary(for: vector.payload.sharePayload())

        #expect(withoutDictionary.utf8.count > vector.maxTokenLength)
    }

    @Test("Generated payloads round-trip through raw inflate with the dictionary")
    func generatedPayloadsRoundTrip() throws {
        let incompressibleURL = "https://example.com/" + (0..<2000).map { _ in
            String(Int.random(in: 0..<16), radix: 16)
        }.joined()
        let payloads = try [
            #require(EpisodeSharePayload(
                audioURL: incompressibleURL,
                title: "Incompressible",
                podcastTitle: "",
                artworkURL: nil,
                feedURL: nil,
                guid: nil,
                duration: nil,
                publishedAt: nil
            )),
            #require(EpisodeSharePayload(
                audioURL: "https://example.com/a.mp3",
                title: "Tiny",
                podcastTitle: "T",
                artworkURL: "https://example.com/a.jpg",
                feedURL: "https://example.com/feed.xml",
                guid: "g",
                duration: 9_999_999,
                publishedAt: Date(timeIntervalSince1970: 9_999_999_999)
            ))
        ]

        for payload in payloads {
            let token = try EpisodeShareTokenEncoder.token(for: payload)
            #expect(token.first == "1")
            #expect(token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
            #expect(try EpisodeShareTokenDecoder.tupleFields(from: token) == payload.tupleFields)
        }
    }

    @Test("A tuple that deflates past the length cap throws instead of minting a token")
    func oversizedTupleThrowsTokenTooLong() throws {
        func randomURL() -> String {
            let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
            return "https://example.com/" + String((0..<2020).map { _ in alphabet.randomElement()! })
        }
        let payload = try #require(EpisodeSharePayload(
            audioURL: randomURL(),
            title: "Oversized",
            podcastTitle: "Oversized",
            artworkURL: randomURL(),
            feedURL: randomURL(),
            guid: nil,
            duration: nil,
            publishedAt: nil
        ))
        #expect(payload.tupleFields.joined(separator: "\n").count > 6000)

        #expect(throws: EpisodeShareTokenEncoder.Error.tokenTooLong) {
            try EpisodeShareTokenEncoder.token(for: payload)
        }
    }

    @Test("A tuple past the worker's 16 KiB inflate cap throws even when it deflates small")
    func oversizedTupleThrowsBeforeDeflating() throws {
        let wideURL = "https://example.com/" + String(repeating: "日", count: 2028)
        let payload = try #require(EpisodeSharePayload(
            audioURL: wideURL,
            title: "Wide",
            podcastTitle: "",
            artworkURL: wideURL,
            feedURL: wideURL,
            guid: nil,
            duration: nil,
            publishedAt: nil
        ))
        #expect(payload.tupleFields.joined(separator: "\n").utf8.count > EpisodeShareTokenEncoder.maximumTupleBytes)

        #expect(throws: EpisodeShareTokenEncoder.Error.tokenTooLong) {
            try EpisodeShareTokenEncoder.token(for: payload)
        }
    }

    @Test("The largest text fields still inflate within the worker's cap")
    func largestTextFieldsRoundTrip() throws {
        let payload = try #require(EpisodeSharePayload(
            audioURL: "https://example.com/" + String(repeating: "a", count: 2028),
            title: String(repeating: "界", count: 400),
            podcastTitle: String(repeating: "🎧", count: 400),
            artworkURL: nil,
            feedURL: nil,
            guid: String(repeating: "g", count: 600),
            duration: 1,
            publishedAt: nil
        ))
        let token = try EpisodeShareTokenEncoder.token(for: payload)

        #expect(try EpisodeShareTokenDecoder.tupleFields(from: token) == payload.tupleFields)
    }

    /// Swift is the reference encoder. Run with `OPENCAST_MINT_SHARE_VECTORS=1`
    /// after changing a vector payload, and paste the printed JSON over the
    /// fixture. The ShareWorker's tests import that same file.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENCAST_MINT_SHARE_VECTORS"] == "1"))
    func mintVectors() throws {
        let fixture = try EpisodeShareTokenVectors.load()
        var minted: [EpisodeShareTokenVectors.Vector] = []
        for vector in fixture.vectors {
            let payload = try vector.payload.sharePayload()
            let token = try EpisodeShareTokenEncoder.token(for: payload)
            let url = try EpisodeShareURL.url(
                base: EpisodeShareTokenVectors.shareBaseURL,
                payload: payload,
                startSeconds: vector.startTime
            )
            // Headroom for zlib builds that pick slightly different matches
            // (Node ships Chromium's fork); the worker checks its own encoder
            // against this cap.
            let maxTokenLength = token.utf8.count + max(16, token.utf8.count / 20)
            if vector.name == EpisodeShareTokenVectors.dictionarySensitivityVectorName {
                let withoutDictionary = try EpisodeShareTokenDecoder.tokenWithoutDictionary(for: payload)
                try #require(withoutDictionary.utf8.count > maxTokenLength)
            }
            minted.append(EpisodeShareTokenVectors.Vector(
                name: vector.name,
                payload: vector.payload,
                token: token,
                startTime: vector.startTime,
                url: url.absoluteString,
                maxTokenLength: maxTokenLength
            ))
        }

        let output = EpisodeShareTokenVectors(
            format: fixture.format,
            version: fixture.version,
            dictionary: .init(utf8Bytes: EpisodeShareDictionary.v1.count, sha256: EpisodeShareDictionary.v1SHA256),
            vectors: minted
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = try #require(String(data: encoder.encode(output), encoding: .utf8))
        print("BEGIN EpisodeShareTokenVectors.json\n\(json)\nEND EpisodeShareTokenVectors.json")
    }
}
