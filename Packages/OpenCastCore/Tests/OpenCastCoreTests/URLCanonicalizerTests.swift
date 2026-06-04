import Foundation
import OpenCastCore
import Testing

@Suite("URL canonicalization")
struct URLCanonicalizerTests {
    @Test("Lowercases scheme and host, removes fragments, sorts query items")
    func canonicalizesFeedURL() {
        let url = URL(string: "HTTPS://Example.com/american-prestige.xml?b=2&a=1#fragment")!

        #expect(URLCanonicalizer.canonicalString(for: url) == "https://example.com/american-prestige.xml?a=1&b=2")
    }

    @Test("Canonicalizes raw URL strings and trims invalid values")
    func canonicalizesRawString() {
        #expect(
            URLCanonicalizer.canonicalString(forRawString: " HTTPS://Example.com/american-prestige.xml/?b=2&a=1#fragment ")
                == "https://example.com/american-prestige.xml?a=1&b=2"
        )
        #expect(URLCanonicalizer.canonicalString(forRawString: " not a url ") == "not a url")
    }

    @Test("Removes trailing slash for logical de-duping")
    func removesTrailingSlash() {
        let first = URL(string: "https://example.com/american-prestige.xml/")!
        let second = URL(string: "https://example.com/american-prestige.xml")!

        #expect(URLCanonicalizer.canonicalString(for: first) == URLCanonicalizer.canonicalString(for: second))
    }
}
