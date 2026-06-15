import Foundation
import OpenCastCore
import Testing

@Suite("URL canonicalization")
struct URLCanonicalizerTests {
    @Test("Lowercases scheme and host, removes fragments, sorts query items")
    func canonicalizesFeedURL() {
        let url = URL(string: "HTTPS://Feeds.Example.com/example-current-affairs.xml?b=2&a=1#fragment")!

        #expect(URLCanonicalizer.canonicalString(for: url) == "https://feeds.example.com/example-current-affairs.xml?a=1&b=2")
    }

    @Test("Canonicalizes raw URL strings and trims invalid values")
    func canonicalizesRawString() {
        #expect(
            URLCanonicalizer.canonicalString(forRawString: " HTTPS://Feeds.Example.com/example-current-affairs.xml/?b=2&a=1#fragment ")
                == "https://feeds.example.com/example-current-affairs.xml?a=1&b=2"
        )
        #expect(URLCanonicalizer.canonicalString(forRawString: " not a url ") == "not a url")
    }

    @Test("Removes trailing slash for logical de-duping")
    func removesTrailingSlash() {
        let first = URL(string: "https://feeds.example.com/example-current-affairs.xml/")!
        let second = URL(string: "https://feeds.example.com/example-current-affairs.xml")!

        #expect(URLCanonicalizer.canonicalString(for: first) == URLCanonicalizer.canonicalString(for: second))
    }
}
