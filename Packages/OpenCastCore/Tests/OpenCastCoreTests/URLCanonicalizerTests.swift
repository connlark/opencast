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

    @Test(
        "Canonicalization is idempotent across the corpus",
        arguments: [
            "HTTPS://Feeds.Example.com/example-current-affairs.xml?b=2&a=1#fragment",
            "https://example.com:443/feed.xml",
            "http://example.com:80/feed.xml",
            "https://example.com/feed.xml?",
            "https://example.com/feed.xml?b=2&a=1&a=0",
            "https://xn--bcher-kva.example.com/feed.xml",
            "https://example.com/f//nested///feed.xml/",
            "http://example.com/feed.xml"
        ]
    )
    func canonicalizationIsIdempotent(rawValue: String) {
        let once = URLCanonicalizer.canonicalString(forRawString: rawValue)
        #expect(URLCanonicalizer.canonicalString(forRawString: once) == once)
    }

    @Test("Explicit default ports are preserved as distinct identities")
    func explicitDefaultPortsArePreserved() {
        // Stripping :443 would re-key the podcast and episode IDs of every library that subscribed with the port.
        #expect(
            URLCanonicalizer.canonicalString(forRawString: "https://example.com:443/feed.xml")
                == "https://example.com:443/feed.xml"
        )
    }

    @Test("Empty query strings survive canonicalization")
    func emptyQueryStringsSurvive() {
        let canonical = URLCanonicalizer.canonicalString(forRawString: "https://example.com/feed.xml?")
        #expect(canonical == "https://example.com/feed.xml?")
    }

    @Test("Punycode hosts lowercase without further normalization")
    func punycodeHostsLowercase() {
        #expect(
            URLCanonicalizer.canonicalString(forRawString: "https://XN--BCHER-KVA.example.com/feed.xml")
                == "https://xn--bcher-kva.example.com/feed.xml"
        )
    }

    @Test("Duplicate query keys sort by name then value")
    func duplicateQueryKeysSortDeterministically() {
        #expect(
            URLCanonicalizer.canonicalString(forRawString: "https://example.com/feed.xml?b=2&a=1&a=0")
                == "https://example.com/feed.xml?a=0&a=1&b=2"
        )
    }
}
