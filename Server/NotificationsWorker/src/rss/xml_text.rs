//! XML text/entity decoding for the RSS parser.
//!
//! Adapted from the MIT-licensed `feed-rs` crate (© 2019 Hiroki Kumamoto),
//! upstream `feed-rs/src/xml/mod.rs` (`XmlEvent::text` / `text_from_cdata`). The
//! full crate is not linked because it pulls in chrono/url/regex/serde_json/
//! mediatype/uuid/siphasher, bloating this Cloudflare Workers wasm target.
//!
//! feed-rs targets quick-xml 0.37, where entity references arrive inside
//! `Event::Text` and are resolved with `quick_xml::escape::unescape`. This crate
//! is on quick-xml 0.38, which emits character/general entity references as a
//! separate `Event::GeneralRef`; `Event::Text` no longer carries them. The
//! `GeneralRef` handling here is the local adaptation feed-rs predates. Decoding
//! semantics still match feed-rs: the five predefined XML entities and valid
//! numeric references resolve to characters (malformed numeric refs such as
//! `&#0;` are dropped), CDATA is taken verbatim, and any other named entity
//! (e.g. `&nbsp;`) is preserved for the downstream cleaner.

use quick_xml::events::{BytesRef, Event};

/// Appends the decoded text of a text-bearing event to `buffer`; ignores others.
pub(super) fn push_event_text(buffer: &mut String, event: &Event<'_>) {
    match event {
        // 0.38 `Text` carries no entity refs (they arrive as `GeneralRef`), so
        // decoding to UTF-8 is enough — we skip feed-rs's 0.37-era `unescape`,
        // which would no-op here and error on the dangling `&` we tolerate.
        Event::Text(text) => {
            if let Ok(value) = text.decode() {
                buffer.push_str(&value);
            }
        }
        // CDATA is raw per the XML spec: decode bytes, never unescape.
        Event::CData(cdata) => {
            if let Ok(value) = cdata.decode() {
                buffer.push_str(&value);
            }
        }
        Event::GeneralRef(reference) => push_general_ref(buffer, reference),
        _ => {}
    }
}

fn push_general_ref(buffer: &mut String, reference: &BytesRef<'_>) {
    match reference.resolve_char_ref() {
        // Numeric reference (`&#60;` / `&#x3C;`) resolved to its character.
        Ok(Some(character)) => {
            buffer.push(character);
            return;
        }
        // Not a character reference; resolve it as a named entity below.
        Ok(None) => {}
        // Malformed/illegal numeric char ref (`&#0;`, a lone surrogate, or a
        // codepoint past U+10FFFF): drop it. Preserving it verbatim would let
        // the downstream cleaner re-parse `&#0;` into a literal NUL.
        Err(_) => return,
    }
    let Ok(name) = reference.decode() else {
        return;
    };
    match quick_xml::escape::resolve_xml_entity(name.as_ref()) {
        Some(resolved) => buffer.push_str(resolved), // lt gt amp apos quot
        None => {
            // Unknown named entity (&nbsp;, &mdash;, …): preserve verbatim so
            // the downstream cleaner in apns.rs can decode it — matching how
            // such entities survive untouched inside CDATA.
            buffer.push('&');
            buffer.push_str(name.as_ref());
            buffer.push(';');
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Reader harness mirroring feed-rs's `source.root().children_as_string()`:
    /// drive the 0.38 reader and feed every event through `push_event_text`.
    fn decode_snippet(xml: &str) -> String {
        let mut reader = quick_xml::Reader::from_str(xml);
        reader.config_mut().allow_dangling_amp = true;
        let mut buffer = String::new();
        loop {
            match reader.read_event() {
                Ok(Event::Eof) => break,
                Ok(event) => push_event_text(&mut buffer, &event),
                Err(e) => panic!("snippet should parse: {e:?}"),
            }
        }
        buffer
    }

    #[test]
    fn decodes_feed_rs_entity_vectors() {
        // Vectors taken verbatim from feed-rs `src/xml/tests.rs::test_rss_decoding`.
        let cases = [
            ("<title>AT&#x26;T</title>", "AT&T"),
            (
                "<title>Bill &#x26; Ted's Excellent Adventure</title>",
                "Bill & Ted's Excellent Adventure",
            ),
            ("<title>The &#x26;amp; entity</title>", "The &amp; entity"),
            (
                "<title>I &#x3C;3 Phil Ringnalda</title>",
                "I <3 Phil Ringnalda",
            ),
            ("<title>A &#x3C; B</title>", "A < B"),
            ("<title>A&#x3C;B</title>", "A<B"),
            (
                "<title>Nice &#x3C;gorilla&#x3E;, what's he weigh?</title>",
                "Nice <gorilla>, what's he weigh?",
            ),
        ];
        for (xml, expected) in cases {
            assert_eq!(decode_snippet(xml), expected, "input: {xml}");
        }
    }

    #[test]
    fn reassembles_escaped_html() {
        assert_eq!(
            decode_snippet("<description>&lt;p&gt;Hello &amp; bye&lt;/p&gt;</description>"),
            "<p>Hello & bye</p>"
        );
    }

    #[test]
    fn cdata_is_raw() {
        // feed-rs keeps CDATA verbatim, so `&deg;` is preserved, not decoded.
        assert_eq!(
            decode_snippet("<x><![CDATA[<p>21.9072&deg;</p>]]></x>"),
            "<p>21.9072&deg;</p>"
        );
    }

    #[test]
    fn general_ref_entity_matrix() {
        let decode = |name: &str| {
            let mut buffer = String::new();
            push_general_ref(&mut buffer, &BytesRef::new(name));
            buffer
        };
        assert_eq!(decode("lt"), "<");
        assert_eq!(decode("gt"), ">");
        assert_eq!(decode("amp"), "&");
        assert_eq!(decode("apos"), "'");
        assert_eq!(decode("quot"), "\"");
        assert_eq!(decode("#60"), "<"); // decimal numeric reference
        assert_eq!(decode("#x3C"), "<"); // hex numeric reference
                                         // Unknown named entity is preserved for the downstream cleaner.
        assert_eq!(decode("nbsp"), "&nbsp;");
        // Malformed/illegal numeric char refs are dropped, not emitted as text
        // (otherwise the downstream cleaner turns "&#0;" into a literal NUL).
        assert_eq!(decode("#0"), "");
        assert_eq!(decode("#x0"), "");
        assert_eq!(decode("#xD800"), ""); // lone surrogate
        assert_eq!(decode("#x110000"), ""); // beyond U+10FFFF
    }
}
