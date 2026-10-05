//! Feed HTML → notification prose.
//!
//! One pipeline for the candidate summary the observation scan stores and the
//! APNs alert built at send time. It cleans the whole feed text first and
//! bounds the prose afterwards, so a byte budget never lands inside a tag. On
//! 2026-09-29 production pushes carried four words of a sentence: the
//! candidate stored a 512-byte cut of raw HTML whose next `<a href>` was longer
//! than the remaining budget, and the tag stripper then dropped everything
//! after the unterminated `<`.
//!
//! The output follows what a browser renders for the markup, collapsed to one
//! line: inline elements (`a`, `strong`, `em`, …) add no whitespace, so
//! `parents</a>, and` reads "parents, and"; every other element boundary is a
//! space; comments and script/style bodies vanish; entities decode to the real
//! character (`&rsquo;` is ’, not '). Bare URLs shrink to their host so a
//! preview keeps its sentence instead of spending the width on a tracking URL.

/// Byte budget of the summary carried on a release candidate and on the wire
/// (`delivery::wire` validates `episode_summary` at this size). Applied to the
/// cleaned prose at a word boundary, never to markup.
pub const SUMMARY_BYTES: usize = 512;
/// Feed text longer than this is cut before cleaning; the parser already caps
/// item text at the same size.
const MAX_SOURCE_BYTES: usize = 16 * 1024;
const ELLIPSIS: &str = "\u{2026}";

/// Phrasing content: element boundaries that browsers render inline with the
/// surrounding text, so they contribute no whitespace.
const INLINE_ELEMENTS: &[&str] = &[
    "a", "abbr", "acronym", "b", "bdi", "bdo", "big", "cite", "code", "data", "del", "dfn", "em",
    "font", "i", "ins", "kbd", "label", "mark", "q", "s", "samp", "small", "span", "strike",
    "strong", "sub", "sup", "time", "tt", "u", "var", "wbr",
];
/// Elements whose whole content is invisible.
const HIDDEN_ELEMENTS: &[&str] = &[
    "audio", "embed", "iframe", "noscript", "object", "script", "style", "svg", "template", "video",
];
const ATTRIBUTE_DEBRIS: &[&str] = &["href=", "src=", "target=", "rel=", "class=", "style="];

/// The clean, single-line prose for a fragment of feed HTML or plain text.
pub fn plain_text(value: &str) -> String {
    prose(value).text
}

/// The notification summary for an episode: the first of the description and
/// the show notes that yields prose which is not just the title or a URL.
/// Unbounded; callers apply [`bounded`].
pub fn summary(
    summary: Option<&str>,
    show_notes_html: Option<&str>,
    episode_title: &str,
) -> Option<String> {
    let title = normalized_for_match(&plain_text(episode_title));
    [summary, show_notes_html]
        .into_iter()
        .flatten()
        .map(|value| prose(truncated_utf8(value, MAX_SOURCE_BYTES)))
        .find(|prose| {
            !prose.text.is_empty() && !prose.url_only && normalized_for_match(&prose.text) != title
        })
        .map(|prose| prose.text)
}

/// The summary stored on a release candidate: cleaned prose within
/// [`SUMMARY_BYTES`]. The observation scan calls this; it is here so the host
/// lane tests exactly what the wasm-only scan module ships.
pub fn candidate_summary(episode: &crate::rss::ParsedEpisode) -> Option<String> {
    summary(
        episode.summary.as_deref(),
        episode.show_notes_html.as_deref(),
        &episode.title,
    )
    .map(|prose| bounded(&prose, SUMMARY_BYTES))
}

/// `text` within `max_bytes`, cut at a word boundary with an ellipsis when it
/// was longer. A cut that lands on a sentence end keeps the sentence's own
/// punctuation instead.
pub fn bounded(text: &str, max_bytes: usize) -> String {
    if text.len() <= max_bytes {
        return text.to_string();
    }
    if max_bytes <= ELLIPSIS.len() {
        return truncated_utf8(text, max_bytes).to_string();
    }
    let budget = max_bytes - ELLIPSIS.len();
    let head = truncated_utf8(text, budget);
    let cut = head
        .rfind(char::is_whitespace)
        .filter(|&index| index >= budget / 2)
        .unwrap_or(head.len());
    let head = head[..cut].trim_end_matches(trailing_orphan);
    if head.is_empty() {
        return ELLIPSIS.to_string();
    }
    if head.ends_with(['.', '!', '?', '\u{2026}']) {
        head.to_string()
    } else {
        format!("{head}{ELLIPSIS}")
    }
}

struct Prose {
    text: String,
    /// Every word was a URL before shortening: not a useful summary.
    url_only: bool,
}

fn prose(value: &str) -> Prose {
    // Markup that arrived entity-escaped (or double-escaped, as some feeds
    // do) only becomes visible after decoding: repeat until the text settles.
    let mut text = value.to_string();
    for _ in 0..4 {
        let next = decode_entities(&strip_markup(&text));
        if next == text {
            break;
        }
        text = next;
    }
    let mut words: Vec<String> = Vec::new();
    let mut url_count = 0;
    let mut word_count = 0;
    for token in text.split_whitespace() {
        let (open, core, close) = split_wrapping_punctuation(token);
        if is_attribute_debris(core) {
            // A stray attribute from broken markup, usually preceded by its
            // element name.
            if words.last().is_some_and(|word| word == "a") {
                words.pop();
                word_count -= 1;
            }
            continue;
        }
        if !core.is_empty() {
            word_count += 1;
        }
        let word = match url_host(core) {
            Some(host) => {
                url_count += 1;
                format!("{open}{host}{close}")
            }
            None => token.to_string(),
        };
        if word.starts_with([',', '.', ';', ':', '!', '?']) {
            if let Some(previous) = words.last_mut() {
                // `parents</a>, and` must not read "parents , and".
                previous.push_str(&word);
                continue;
            }
        }
        words.push(word);
    }
    let joined = words.join(" ");
    Prose {
        text: joined
            .trim_start_matches(leading_orphan)
            .trim_end_matches(trailing_orphan)
            .to_string(),
        url_only: word_count > 0 && url_count == word_count,
    }
}

/// Removes tags, comments and hidden elements, mapping each element boundary
/// to whitespace or nothing. Text is copied through with control characters
/// dropped and every whitespace character reduced to a space.
fn strip_markup(input: &str) -> String {
    let mut output = String::with_capacity(input.len());
    let bytes = input.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] != b'<' {
            let character = input[index..].chars().next().expect("char boundary");
            push_text(&mut output, character);
            index += character.len_utf8();
            continue;
        }
        let rest = &input[index + 1..];
        match rest.as_bytes().first() {
            Some(b'!') => {
                let consumed = if let Some(after) = rest.strip_prefix("!--") {
                    after.find("-->").map(|end| 3 + end + 3)
                } else {
                    rest.find('>').map(|end| end + 1)
                };
                // An unterminated comment or declaration hides the rest.
                let Some(consumed) = consumed else { break };
                index += 1 + consumed;
                output.push(' ');
            }
            Some(b'?') => {
                let Some(end) = rest.find('>') else { break };
                index += 1 + end + 1;
                output.push(' ');
            }
            Some(&first) if first == b'/' || first.is_ascii_alphabetic() => {
                // An unterminated tag at the end of the text renders nothing,
                // like a browser at end of file inside a tag.
                let Some(tag) = parse_tag(rest) else { break };
                index += 1 + tag.consumed;
                if !tag.closing && HIDDEN_ELEMENTS.contains(&tag.name.as_str()) {
                    match find_closing_tag(&input[index..], &tag.name) {
                        Some(consumed) => index += consumed,
                        None => break,
                    }
                }
                if !INLINE_ELEMENTS.contains(&tag.name.as_str()) {
                    output.push(' ');
                }
            }
            _ => {
                // A lone `<` ("1 < 2", "<3") is text.
                output.push('<');
                index += 1;
            }
        }
    }
    output
}

struct Tag {
    name: String,
    closing: bool,
    /// Bytes after the `<`, through the closing `>`.
    consumed: usize,
}

fn parse_tag(rest: &str) -> Option<Tag> {
    let bytes = rest.as_bytes();
    let closing = bytes.first() == Some(&b'/');
    let name_start = usize::from(closing);
    let name_end = name_start
        + bytes[name_start..]
            .iter()
            .take_while(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b':'))
            .count();
    let name = rest[name_start..name_end].to_ascii_lowercase();
    let mut quote: Option<u8> = None;
    let mut index = name_end;
    while index < bytes.len() {
        let byte = bytes[index];
        match quote {
            Some(open) if byte == open => quote = None,
            Some(_) => {}
            None if byte == b'"' || byte == b'\'' => quote = Some(byte),
            None if byte == b'>' => {
                return Some(Tag {
                    name,
                    closing,
                    consumed: index + 1,
                });
            }
            None => {}
        }
        index += 1;
    }
    None
}

/// Bytes through the end of `</name …>` for a hidden element's content.
fn find_closing_tag(rest: &str, name: &str) -> Option<usize> {
    let lower = rest.to_ascii_lowercase();
    let mut from = 0;
    while let Some(found) = lower[from..].find("</") {
        let start = from + found;
        let after_name = start + 2 + name.len();
        if lower[start + 2..].starts_with(name)
            && lower
                .as_bytes()
                .get(after_name)
                .is_none_or(|byte| byte.is_ascii_whitespace() || *byte == b'>')
        {
            return lower[after_name..]
                .find('>')
                .map(|end| after_name + end + 1);
        }
        from = start + 2;
    }
    None
}

fn push_text(output: &mut String, character: char) {
    if character.is_whitespace() {
        output.push(' ');
    } else if !character.is_control() {
        output.push(character);
    }
}

/// Decodes named and numeric character references to their characters.
/// Unknown names stay verbatim, as does an `&` that starts no reference.
pub fn decode_entities(input: &str) -> String {
    let mut output = String::with_capacity(input.len());
    let mut rest = input;
    while let Some(start) = rest.find('&') {
        output.push_str(&rest[..start]);
        let after = &rest[start + 1..];
        let length = after
            .bytes()
            .take(32)
            .take_while(|byte| byte.is_ascii_alphanumeric() || *byte == b'#')
            .count();
        match after[length..].strip_prefix(';') {
            Some(remaining) if length > 0 => {
                let name = &after[..length];
                match decode_reference(name) {
                    Some(decoded) => output.push_str(&decoded),
                    None => {
                        output.push('&');
                        output.push_str(name);
                        output.push(';');
                    }
                }
                rest = remaining;
            }
            _ => {
                output.push('&');
                rest = after;
            }
        }
    }
    output.push_str(rest);
    output
}

fn decode_reference(name: &str) -> Option<String> {
    if let Some(digits) = name.strip_prefix('#') {
        let code = match digits.strip_prefix(['x', 'X']) {
            Some(hex) => u32::from_str_radix(hex, 16).ok()?,
            None => digits.parse::<u32>().ok()?,
        };
        return Some(
            numeric_character(code)
                .map(String::from)
                .unwrap_or_default(),
        );
    }
    named_entity(name).map(str::to_string)
}

/// Browsers map the C1 range to Windows-1252; NUL, controls, surrogates and
/// out-of-range values render nothing useful in an alert.
fn numeric_character(code: u32) -> Option<char> {
    const WINDOWS_1252: [char; 32] = [
        '\u{20AC}', '\u{81}', '\u{201A}', '\u{0192}', '\u{201E}', '\u{2026}', '\u{2020}',
        '\u{2021}', '\u{02C6}', '\u{2030}', '\u{0160}', '\u{2039}', '\u{0152}', '\u{8D}',
        '\u{017D}', '\u{8F}', '\u{90}', '\u{2018}', '\u{2019}', '\u{201C}', '\u{201D}', '\u{2022}',
        '\u{2013}', '\u{2014}', '\u{02DC}', '\u{2122}', '\u{0161}', '\u{203A}', '\u{0153}',
        '\u{9D}', '\u{017E}', '\u{0178}',
    ];
    if (0x80..=0x9F).contains(&code) {
        return Some(WINDOWS_1252[(code - 0x80) as usize]).filter(|c| !c.is_control());
    }
    char::from_u32(code).filter(|c| !c.is_control() || c.is_whitespace())
}

/// The named references seen in podcast feeds: XML's five, the Latin-1 block
/// (`&nbsp;` … `&yuml;`, in code point order) and the common typography.
fn named_entity(name: &str) -> Option<&'static str> {
    const LATIN1: [&str; 96] = [
        "nbsp", "iexcl", "cent", "pound", "curren", "yen", "brvbar", "sect", "uml", "copy", "ordf",
        "laquo", "not", "shy", "reg", "macr", "deg", "plusmn", "sup2", "sup3", "acute", "micro",
        "para", "middot", "cedil", "sup1", "ordm", "raquo", "frac14", "frac12", "frac34", "iquest",
        "Agrave", "Aacute", "Acirc", "Atilde", "Auml", "Aring", "AElig", "Ccedil", "Egrave",
        "Eacute", "Ecirc", "Euml", "Igrave", "Iacute", "Icirc", "Iuml", "ETH", "Ntilde", "Ograve",
        "Oacute", "Ocirc", "Otilde", "Ouml", "times", "Oslash", "Ugrave", "Uacute", "Ucirc",
        "Uuml", "Yacute", "THORN", "szlig", "agrave", "aacute", "acirc", "atilde", "auml", "aring",
        "aelig", "ccedil", "egrave", "eacute", "ecirc", "euml", "igrave", "iacute", "icirc",
        "iuml", "eth", "ntilde", "ograve", "oacute", "ocirc", "otilde", "ouml", "divide", "oslash",
        "ugrave", "uacute", "ucirc", "uuml", "yacute", "thorn", "yuml",
    ];
    const LATIN1_CHARS: &str = "\u{A0}\u{A1}\u{A2}\u{A3}\u{A4}\u{A5}\u{A6}\u{A7}\u{A8}\u{A9}\u{AA}\u{AB}\u{AC}\u{AD}\u{AE}\u{AF}\u{B0}\u{B1}\u{B2}\u{B3}\u{B4}\u{B5}\u{B6}\u{B7}\u{B8}\u{B9}\u{BA}\u{BB}\u{BC}\u{BD}\u{BE}\u{BF}\u{C0}\u{C1}\u{C2}\u{C3}\u{C4}\u{C5}\u{C6}\u{C7}\u{C8}\u{C9}\u{CA}\u{CB}\u{CC}\u{CD}\u{CE}\u{CF}\u{D0}\u{D1}\u{D2}\u{D3}\u{D4}\u{D5}\u{D6}\u{D7}\u{D8}\u{D9}\u{DA}\u{DB}\u{DC}\u{DD}\u{DE}\u{DF}\u{E0}\u{E1}\u{E2}\u{E3}\u{E4}\u{E5}\u{E6}\u{E7}\u{E8}\u{E9}\u{EA}\u{EB}\u{EC}\u{ED}\u{EE}\u{EF}\u{F0}\u{F1}\u{F2}\u{F3}\u{F4}\u{F5}\u{F6}\u{F7}\u{F8}\u{F9}\u{FA}\u{FB}\u{FC}\u{FD}\u{FE}\u{FF}";
    if let Some(position) = LATIN1.iter().position(|entity| *entity == name) {
        // Every Latin-1 character is two bytes in UTF-8.
        return LATIN1_CHARS.get(position * 2..position * 2 + 2);
    }
    Some(match name {
        "amp" | "AMP" => "&",
        "lt" | "LT" => "<",
        "gt" | "GT" => ">",
        "quot" | "QUOT" => "\"",
        "apos" => "'",
        "ensp" | "emsp" | "thinsp" | "numsp" | "puncsp" => " ",
        "zwnj" | "zwj" | "lrm" | "rlm" => "",
        "ndash" => "\u{2013}",
        "mdash" => "\u{2014}",
        "lsquo" => "\u{2018}",
        "rsquo" => "\u{2019}",
        "sbquo" => "\u{201A}",
        "ldquo" => "\u{201C}",
        "rdquo" => "\u{201D}",
        "bdquo" => "\u{201E}",
        "dagger" => "\u{2020}",
        "Dagger" => "\u{2021}",
        "bull" | "bullet" => "\u{2022}",
        "hellip" | "mldr" => "\u{2026}",
        "permil" => "\u{2030}",
        "prime" => "\u{2032}",
        "Prime" => "\u{2033}",
        "lsaquo" => "\u{2039}",
        "rsaquo" => "\u{203A}",
        "oline" => "\u{203E}",
        "frasl" => "\u{2044}",
        "euro" => "\u{20AC}",
        "trade" | "TRADE" => "\u{2122}",
        "larr" => "\u{2190}",
        "uarr" => "\u{2191}",
        "rarr" => "\u{2192}",
        "darr" => "\u{2193}",
        "harr" => "\u{2194}",
        "crarr" => "\u{21B5}",
        "minus" => "\u{2212}",
        "lowast" => "\u{2217}",
        "radic" => "\u{221A}",
        "infin" => "\u{221E}",
        "ne" => "\u{2260}",
        "le" => "\u{2264}",
        "ge" => "\u{2265}",
        "loz" => "\u{25CA}",
        "spades" => "\u{2660}",
        "clubs" => "\u{2663}",
        "hearts" => "\u{2665}",
        "diams" => "\u{2666}",
        "check" | "checkmark" => "\u{2713}",
        "starf" | "bigstar" => "\u{2605}",
        "star" => "\u{2606}",
        "OElig" => "\u{0152}",
        "oelig" => "\u{0153}",
        "Scaron" => "\u{0160}",
        "scaron" => "\u{0161}",
        "Yuml" => "\u{0178}",
        "fnof" => "\u{0192}",
        "circ" => "\u{02C6}",
        "tilde" => "\u{02DC}",
        _ => return None,
    })
}

/// Splits `(word)."` into its opening wrapper, core and closing punctuation.
fn split_wrapping_punctuation(token: &str) -> (&str, &str, &str) {
    let open_end = token
        .char_indices()
        .find(|(_, c)| !is_opening_wrapper(*c))
        .map_or(token.len(), |(index, _)| index);
    let close_start = token[open_end..]
        .char_indices()
        .rev()
        .find(|(_, c)| !is_closing_wrapper(*c))
        .map_or(open_end, |(index, c)| open_end + index + c.len_utf8());
    (
        &token[..open_end],
        &token[open_end..close_start],
        &token[close_start..],
    )
}

fn is_opening_wrapper(c: char) -> bool {
    matches!(
        c,
        '(' | '[' | '{' | '"' | '\'' | '\u{201C}' | '\u{2018}' | '\u{AB}' | '<'
    )
}

fn is_closing_wrapper(c: char) -> bool {
    matches!(
        c,
        ')' | ']'
            | '}'
            | '"'
            | '\''
            | '\u{201D}'
            | '\u{2019}'
            | '\u{BB}'
            | '.'
            | ','
            | ';'
            | ':'
            | '!'
            | '?'
            | '\u{2026}'
    )
}

fn is_attribute_debris(core: &str) -> bool {
    let lower = core.to_ascii_lowercase();
    ATTRIBUTE_DEBRIS
        .iter()
        .any(|prefix| lower.starts_with(prefix))
}

/// The host of a bare `http(s)://` or `www.` URL, without `www.`; `None` when
/// the word is not a URL with a dotted host ("https://" alone, "foo://").
fn url_host(core: &str) -> Option<&str> {
    let lower = core.to_ascii_lowercase();
    let host_start = if lower.starts_with("https://") {
        8
    } else if lower.starts_with("http://") {
        7
    } else if lower.starts_with("www.") {
        0
    } else {
        return None;
    };
    let authority = &core[host_start..];
    let host_end = authority
        .find(['/', '?', '#', ':'])
        .unwrap_or(authority.len());
    let host = &authority[..host_end];
    let host = host.strip_prefix("www.").unwrap_or(host);
    let valid = host.contains('.')
        && !host.starts_with('.')
        && !host.ends_with('.')
        && host
            .chars()
            .all(|c| c.is_alphanumeric() || matches!(c, '-' | '.'));
    valid.then_some(host)
}

fn leading_orphan(c: char) -> bool {
    c.is_whitespace()
        || matches!(
            c,
            ',' | ';'
                | ':'
                | '-'
                | '_'
                | '|'
                | '/'
                | '\\'
                | ')'
                | ']'
                | '}'
                | '\u{2013}'
                | '\u{2014}'
        )
}

fn trailing_orphan(c: char) -> bool {
    c.is_whitespace()
        || matches!(
            c,
            ',' | ';'
                | ':'
                | '-'
                | '_'
                | '|'
                | '/'
                | '\\'
                | '('
                | '['
                | '{'
                | '\u{2013}'
                | '\u{2014}'
                | '"'
                | '\''
                | '\u{201C}'
                | '\u{2018}'
                | '\u{AB}'
        )
}

fn normalized_for_match(value: &str) -> String {
    value
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

fn truncated_utf8(value: &str, max_bytes: usize) -> &str {
    if value.len() <= max_bytes {
        return value;
    }
    let mut end = max_bytes;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    &value[..end]
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Patreon post markup as syndicated by a hosting platform: wrapper `div`s
    /// and long tracking URLs. A 512-byte raw cut lands inside the first
    /// `<a href>`, which is how a production push came to read only "The hosts
    /// discuss the" on 2026-09-29.
    const WRAPPED_DESCRIPTION: &str = r#"<div> <div class="patreon-post-content"> <div class="PaddingTop-module__FYUbOa__paddingTopSpaceX32"> <div class="CollapsibleContent-module__7CXqlq__singleColumnMargin"> <div class="TokenOverrides-module__yhJOLG__tokensPostPage"> <div class= "RichText-module__5kju5G__root RichText-module__5kju5G__additionalStylesPostContentWrapper"> <p>The hosts discuss the <a href= "https://www.globe.example.com/2026/09/22/magazine/small-town-bar-backlash/?utm_campaign=Globe_Twitter&arch=example%3Asocialflow%3Atwitter" target="_blank" rel="noopener">small-town bar masking debacle,</a> the hot new trend of <a href= "https://www.journal.example.com/health/wellness/why-are-so-many-adults-cutting-off-their-parents-d4e1190c" target="_blank" rel="noopener">adults cutting off their parents</a>, and <a href= "https://www.times.example.com/2026/09/20/magazine/public-schools-segregation.html" target="_blank" rel="noopener">a columnist's schooling mea culpa to her daughter.</a></p> </div> </div> </div> </div> </div> </div>"#;
    /// The same episode on a mirror feed without the wrappers: the raw cut
    /// lands inside the third link and the old push read "… parents , and".
    const MIRROR_DESCRIPTION: &str = r#"<html><p>The hosts discuss the <a href="https://www.globe.example.com/2026/09/22/magazine/small-town-bar-backlash/?utm_campaign=Globe_Twitter&amp;arch=example%3Asocialflow%3Atwitter" target="_blank">small-town bar masking debacle,</a> the hot new trend of <a href="https://www.journal.example.com/health/wellness/why-are-so-many-adults-cutting-off-their-parents-d4e1190c" target="_blank">adults cutting off their parents</a>, and <a href="https://www.times.example.com/2026/09/20/magazine/public-schools-segregation.html" target="_blank">a columnist's schooling mea culpa to her daughter.</a></p></html>"#;
    const EXPECTED_PROSE: &str = "The hosts discuss the small-town bar masking debacle, the hot new trend of adults cutting off their parents, and a columnist's schooling mea culpa to her daughter.";

    #[test]
    fn wrapped_descriptions_become_the_full_prose_on_both_feeds() {
        assert_eq!(plain_text(WRAPPED_DESCRIPTION), EXPECTED_PROSE);
        assert_eq!(plain_text(MIRROR_DESCRIPTION), EXPECTED_PROSE);
        let stored = bounded(
            &summary(Some(WRAPPED_DESCRIPTION), None, "Episode Title").unwrap(),
            SUMMARY_BYTES,
        );
        assert_eq!(stored, EXPECTED_PROSE);
        assert!(stored.len() <= SUMMARY_BYTES);
    }

    #[test]
    fn raw_markup_cut_at_the_old_budget_no_longer_describes_the_output() {
        // The stored 512-byte prefixes from production on 2026-09-29 are still
        // cleaned as well as possible: the unterminated tag renders nothing.
        let wrapped_cut = truncated_utf8(WRAPPED_DESCRIPTION, 512);
        assert!(wrapped_cut.ends_with("Atwitter\" targ"), "{wrapped_cut:?}");
        assert_eq!(plain_text(wrapped_cut), "The hosts discuss the");
        let mirror_cut = truncated_utf8(MIRROR_DESCRIPTION, 512);
        assert!(mirror_cut.ends_with("segregat"), "{mirror_cut:?}");
        assert_eq!(
            plain_text(mirror_cut),
            "The hosts discuss the small-town bar masking debacle, the hot new trend of adults cutting off their parents, and"
        );
    }

    #[test]
    fn candidate_summary_is_bounded_prose_not_bounded_markup() {
        // Wrapper attributes and a long href exceed the 512-byte budget on
        // their own; the stored summary must still be the whole sentence.
        let description = format!(
            "<div class=\"{}\"><p>The hosts discuss the <a href=\"https://www.example.com/{}\">debacle</a>, and more.</p></div>",
            "x".repeat(300),
            "y".repeat(300)
        );
        let feed = format!(
            r#"<?xml version="1.0"?><rss version="2.0"><channel><title>Show</title><item><title>Episode Title</title><guid>g</guid><enclosure url="https://example.com/a.mp3" type="audio/mpeg" length="1"/><description><![CDATA[{description}]]></description></item></channel></rss>"#
        );
        let parsed = crate::rss::parse_rss(&feed, "https://example.com/feed.xml").expect("parses");
        assert_eq!(
            candidate_summary(&parsed.episodes[0]).as_deref(),
            Some("The hosts discuss the debacle, and more.")
        );

        let feed = format!(
            r#"<?xml version="1.0"?><rss version="2.0"><channel><title>Show</title><item><title>Episode Title</title><guid>g</guid><enclosure url="https://example.com/a.mp3" type="audio/mpeg" length="1"/><description><![CDATA[{WRAPPED_DESCRIPTION}]]></description></item></channel></rss>"#
        );
        let parsed = crate::rss::parse_rss(&feed, "https://example.com/feed.xml").expect("parses");
        assert_eq!(
            candidate_summary(&parsed.episodes[0]).as_deref(),
            Some(EXPECTED_PROSE)
        );
    }

    #[test]
    fn inline_elements_add_no_whitespace_and_block_elements_do() {
        assert_eq!(
            plain_text(
                "<p>Talk with <strong>Sam</strong>, <em>Ann</em> and <a href=\"/x\">Lee</a>.</p>"
            ),
            "Talk with Sam, Ann and Lee."
        );
        assert_eq!(plain_text("<p>One</p><p>Two</p>"), "One Two");
        assert_eq!(plain_text("<ul><li>A</li><li>B</li></ul>"), "A B");
        assert_eq!(
            plain_text("Line<br>Break<br/>Again<hr>End"),
            "Line Break Again End"
        );
        assert_eq!(
            plain_text("<h2>Guests</h2>Sam<div>Ann</div>"),
            "Guests Sam Ann"
        );
        assert_eq!(plain_text("Coffee</strong>. Plus"), "Coffee. Plus");
    }

    #[test]
    fn comments_hidden_elements_and_quoted_attributes_are_handled() {
        assert_eq!(
            plain_text("<!-- note -->A<script>alert('<b>')</script>B<style>p{}</style>C<?xml v?>"),
            "A B C"
        );
        assert_eq!(
            plain_text(r#"<a href="https://example.com/?q=a>b" title='x>y'>Link</a> text"#),
            "Link text"
        );
        assert_eq!(plain_text("<A HREF='x'>Upper</A><P>Case</P>"), "Upper Case");
        assert_eq!(
            plain_text("<video controls><source src=x>fallback</video>after"),
            "after"
        );
    }

    #[test]
    fn unterminated_markup_at_the_end_renders_nothing() {
        assert_eq!(
            plain_text("Intro <a href=\"https://example.com/very-long-url"),
            "Intro"
        );
        assert_eq!(plain_text("Intro <!-- never closed"), "Intro");
        assert_eq!(plain_text("Intro <script>never closed"), "Intro");
    }

    #[test]
    fn a_lone_angle_bracket_is_text() {
        assert_eq!(
            plain_text("I <3 math: 1 < 2 and 3 > 2"),
            "I <3 math: 1 < 2 and 3 > 2"
        );
        assert_eq!(plain_text("AT&amp;T &lt; 5 &gt; 3"), "AT&T < 5 > 3");
    }

    #[test]
    fn entities_decode_to_real_characters() {
        assert_eq!(
            plain_text("Ben &amp; Jerry&rsquo;s &ldquo;show&rdquo; &mdash; part 2&hellip; caf&eacute; &copy; &#8217;&#x2019;&#146; &unknown; A&B"),
            "Ben & Jerry’s “show” — part 2… café © ’’’ &unknown; A&B"
        );
        assert_eq!(
            plain_text("one&nbsp;&nbsp;two &#0;three&#x1;"),
            "one two three"
        );
        assert_eq!(
            plain_text("Tom & Jerry; also &amp"),
            "Tom & Jerry; also &amp"
        );
    }

    #[test]
    fn escaped_and_double_escaped_markup_stays_out() {
        assert_eq!(
            plain_text("&lt;p&gt;We spend the hour in deep time.&lt;/p&gt;"),
            "We spend the hour in deep time."
        );
        assert_eq!(
            plain_text("&amp;lt;b&amp;gt;Bold&amp;lt;/b&amp;gt;"),
            "Bold"
        );
        let script = plain_text("&amp;lt;script&amp;gt;alert(1)&amp;lt;/script&amp;gt;");
        assert!(!script.contains('<') && !script.contains('>'), "{script:?}");
    }

    #[test]
    fn bare_urls_shrink_to_their_host() {
        assert_eq!(
            plain_text("Listen at https://example.com/track?utm=1 for more."),
            "Listen at example.com for more."
        );
        assert_eq!(
            plain_text("Visit www.example.com/path. (https://Foo.example.org/x)!"),
            "Visit example.com. (Foo.example.org)!"
        );
        assert_eq!(
            plain_text("Support us: patreon.com/show"),
            "Support us: patreon.com/show"
        );
        assert_eq!(
            plain_text("Useful prose explaining how https:// links and foo:// URI schemes work."),
            "Useful prose explaining how https:// links and foo:// URI schemes work."
        );
        assert_eq!(
            plain_text("Read more https://example.com"),
            "Read more example.com"
        );
    }

    #[test]
    fn attribute_debris_and_punctuation_spacing_are_repaired() {
        assert_eq!(
            plain_text("We spend the hour. Visit a href=https://example.com target=_blank now"),
            "We spend the hour. Visit now"
        );
        assert_eq!(
            plain_text("parents , and then ; done ."),
            "parents, and then; done."
        );
        assert_eq!(
            plain_text("pH balance and p5 protocol matter."),
            "pH balance and p5 protocol matter."
        );
        assert_eq!(
            plain_text(" , leading and trailing - "),
            "leading and trailing"
        );
    }

    #[test]
    fn summary_prefers_useful_prose() {
        assert_eq!(
            summary(
                Some(" Episode Title "),
                Some("<p>Full notes.</p>"),
                "Episode Title"
            )
            .as_deref(),
            Some("Full notes.")
        );
        assert_eq!(
            summary(Some("Episode &amp; Title"), None, "Episode & Title"),
            None
        );
        assert_eq!(
            summary(Some("https://example.com/show-notes"), None, "Title"),
            None
        );
        assert_eq!(
            summary(
                Some("https://a.example.com https://b.example.com"),
                Some(""),
                "Title"
            ),
            None
        );
        assert_eq!(
            summary(Some("<div></div>"), Some("Notes"), "Title").as_deref(),
            Some("Notes")
        );
        assert_eq!(summary(None, None, "Title"), None);
    }

    #[test]
    fn bounded_cuts_at_a_word_with_an_ellipsis() {
        assert_eq!(bounded("short", 512), "short");
        let text = "The quick brown fox jumps over the lazy dog, again and again.";
        assert_eq!(bounded(text, 30), "The quick brown fox jumps…");
        assert_eq!(
            bounded(text, 44),
            "The quick brown fox jumps over the lazy…"
        );
        assert_eq!(
            bounded("First sentence. Second sentence goes on.", 25),
            "First sentence."
        );
        let word = "x".repeat(600);
        let cut = bounded(&word, 512);
        assert!(cut.len() <= 512 && cut.ends_with(ELLIPSIS));
        let emoji = "Summary 😀 ".repeat(200);
        let cut = bounded(&emoji, 520);
        assert!(cut.len() <= 520 && cut.ends_with("Summary…"), "{cut:?}");
        assert_eq!(bounded("ab", 1), "a");
    }
}
