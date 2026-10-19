//! Pure retention JSON handling shared by the PostgreSQL adapter and host tests.
#![cfg(any(target_arch = "wasm32", test))]

fn compact(value: &str) -> Result<String, ()> {
    parse::normalize(value)
}
fn string_end(bytes: &[u8], start: usize) -> usize {
    let mut i = start + 1;
    while i < bytes.len() {
        if bytes[i] == b'\\' {
            i += 2;
        } else if bytes[i] == b'"' {
            return i + 1;
        } else {
            i += 1;
        }
    }
    bytes.len()
}
fn marker(value: &str) -> Option<std::ops::Range<usize>> {
    let bytes = value.as_bytes();
    if bytes.first() != Some(&b'{') {
        return None;
    }
    let mut i = 1;
    while i + 1 < bytes.len() {
        let end = string_end(bytes, i);
        let matches = serde_json::from_str::<String>(&value[i..end])
            .is_ok_and(|key| key == "preparation_poisoned");
        i = end + 1; // colon
        let start = i;
        let mut depth = 0;
        while i < bytes.len() {
            match bytes[i] {
                b'"' => {
                    i = string_end(bytes, i);
                    continue;
                }
                b'[' | b'{' => depth += 1,
                b']' | b'}' if depth > 0 => depth -= 1,
                b',' | b'}' if depth == 0 => break,
                _ => {}
            }
            i += 1;
        }
        if matches {
            return Some(start..i);
        }
        i += 1;
    }
    None
}
pub(crate) fn set_poisoned(value: &str) -> Result<String, ()> {
    let mut value = compact(value)?;
    if let Some(range) = marker(&value) {
        value.replace_range(range, "1");
    } else if value.starts_with('{') {
        let member = if value.len() == 2 {
            "\"preparation_poisoned\":1"
        } else {
            ",\"preparation_poisoned\":1"
        };
        value.insert_str(value.len() - 1, member);
    }
    Ok(value)
}
pub(crate) fn is_poisoned(value: &str) -> Result<bool, ()> {
    let value = compact(value)?;
    Ok(marker(&value).is_some_and(|range| {
        let value = &value[range];
        value == "true" || value.parse::<f64>().is_ok_and(|n| n == 1.0)
    }))
}

#[cfg(all(test, not(target_arch = "wasm32")))]
mod tests {

    use super::*;
    // A frozen compatibility contract, not a live differential oracle: what
    // SQLite answered for these 18 inputs, in this order, recorded twice byte
    // for byte on one rusqlite in-memory connection, which reported
    // `SELECT sqlite_version()` = 3.54.0. rusqlite 0.40.2 / libsqlite3-sys
    // 0.38.2 were linked without `bundled`, so that is the capturing host's
    // runtime-linked SQLite (macOS). Each row is the input, the text of
    // `SELECT json_set(?1,'$.preparation_poisoned',1)` and the boolean of
    // `SELECT COALESCE(json_extract(?1,'$.preparation_poisoned')=1,0)`.
    // SQLite versions differ on one input: Debian bookworm's 3.40.1 does not
    // match the `\u0070`-escaped key in a json_set path and appends a second
    // `preparation_poisoned` member; these are the 3.54.0 answers.
    const RECORDED: [(&str, &str, bool); 18] = [
            ("{}", "{\"preparation_poisoned\":1}", false),
            (" { \"z\" : 1e2, \"a\" : [ 1, 2 ] } ", "{\"z\":1e2,\"a\":[1,2],\"preparation_poisoned\":1}", false),
            ("{\"preparation_poisoned\":0,\"preparation_poisoned\":9,\"z\":\"\\\\u0020\"}", "{\"preparation_poisoned\":1,\"preparation_poisoned\":9,\"z\":\"\\\\u0020\"}", false),
            ("{\"preparation_poisoned\":true}", "{\"preparation_poisoned\":1}", true),
            ("{\"preparation_poisoned\":\"1\"}", "{\"preparation_poisoned\":1}", false),
            ("{\"preparation_poisoned\":1.0}", "{\"preparation_poisoned\":1}", true),
            ("{\"preparation_poisoned\":1e0}", "{\"preparation_poisoned\":1}", true),
            ("{\"preparation_poisoned\":null}", "{\"preparation_poisoned\":1}", false),
            ("{\"preparation_poisoned\":{\"x\":[1,2]}}", "{\"preparation_poisoned\":1}", false),
            ("{\"preparation_\\u0070oisoned\":0,\"x\":\"a,}\\\\\\\"b\"}", "{\"preparation_\\u0070oisoned\":1,\"x\":\"a,}\\\\\\\"b\"}", false),
            ("{z:0x10,a:NaN,preparation_poisoned:+1,}", "{\"z\":16,\"a\":null,\"preparation_poisoned\":1}", true),
            ("{/* kept order */z:1.,a:.2,b:Infinity,c:'single',d:'\\v'}", "{\"z\":1.0,\"a\":0.2,\"b\":9e999,\"c\":\"single\",\"d\":\"\\u000b\",\"preparation_poisoned\":1}", false),
            ("[]", "[]", false),
            ("[1,2]", "[1,2]", false),
            ("null", "null", false),
            ("true", "true", false),
            ("17", "17", false),
            ("\"text\"", "\"text\"", false),
    ];
    #[test]
    fn poison_marker_matches_the_recorded_sqlite_answers() {
        for (source, set, poisoned) in RECORDED {
            assert_eq!(set_poisoned(source).unwrap(), set, "{source}");
            assert_eq!(is_poisoned(source).unwrap(), poisoned, "{source}");
        }
    }
}

mod parse {
    pub(crate) fn normalize(input: &str) -> Result<String, ()> {
        let mut parser = Parser {
            chars: input.chars().collect(),
            at: 0,
        };
        let value = parser.value(0)?;
        parser.space()?;
        if parser.at != parser.chars.len() {
            return Err(());
        }
        Ok(value)
    }
    struct Parser {
        chars: Vec<char>,
        at: usize,
    }
    impl Parser {
        fn peek(&self) -> Option<char> {
            self.chars.get(self.at).copied()
        }
        fn take(&mut self) -> Result<char, ()> {
            let value = self.peek().ok_or(())?;
            self.at += 1;
            Ok(value)
        }
        fn space(&mut self) -> Result<(), ()> {
            loop {
                match (self.peek(), self.chars.get(self.at + 1)) {
                    (
                        Some(
                            ' '
                            | '\t'
                            | '\n'
                            | '\r'
                            | '\u{b}'
                            | '\u{c}'
                            | '\u{a0}'
                            | '\u{1680}'
                            | '\u{2000}'..='\u{200a}'
                            | '\u{2028}'
                            | '\u{2029}'
                            | '\u{202f}'
                            | '\u{205f}'
                            | '\u{3000}'
                            | '\u{feff}',
                        ),
                        _,
                    ) => {
                        self.at += 1;
                    }
                    (Some('/'), Some('/')) => {
                        self.at += 2;
                        while self.peek().is_some_and(|c| !matches!(c, '\n' | '\r')) {
                            self.at += 1;
                        }
                    }
                    (Some('/'), Some('*')) => {
                        self.at += 2;
                        loop {
                            if self.take()? == '*' && self.peek() == Some('/') {
                                self.at += 1;
                                break;
                            }
                        }
                    }
                    _ => return Ok(()),
                }
            }
        }
        fn quoted(&mut self) -> Result<String, ()> {
            let delimiter = self.take()?;
            let mut out = String::from("\"");
            loop {
                let ch = self.take()?;
                if ch == delimiter {
                    out.push('"');
                    return Ok(out);
                }
                if ch == '\\' {
                    let escape = self.take()?;
                    match escape {
                        '\'' => out.push('\''),
                        'v' => out.push_str("\\u000b"),
                        '0' if !self.peek().is_some_and(|c| c.is_ascii_digit()) => {
                            out.push_str("\\u0000")
                        }
                        'x' => {
                            out.push_str("\\u00");
                            self.hex(2, &mut out)?;
                        }
                        'u' => {
                            out.push_str("\\u");
                            self.hex(4, &mut out)?;
                        }
                        '\r' => {
                            if self.peek() == Some('\n') {
                                self.at += 1;
                            }
                        }
                        '\n' | '\u{2028}' | '\u{2029}' => {}
                        '"' | '\\' | '/' | 'b' | 'f' | 'n' | 'r' | 't' => {
                            out.push('\\');
                            out.push(escape);
                        }
                        _ => return Err(()),
                    }
                } else {
                    match ch {
                        '\0' => return Err(()),
                        '"' => out.push_str("\\\""),
                        '\u{8}' => out.push_str("\\b"),
                        '\t' => out.push_str("\\t"),
                        '\n' => out.push_str("\\n"),
                        '\u{c}' => out.push_str("\\f"),
                        '\r' => out.push_str("\\r"),
                        '\u{1}'..='\u{1f}' => out.push_str(&format!("\\u{:04x}", ch as u32)),
                        _ => out.push(ch),
                    }
                }
            }
        }
        fn hex(&mut self, count: usize, out: &mut String) -> Result<(), ()> {
            for _ in 0..count {
                let ch = self.take()?;
                if !ch.is_ascii_hexdigit() {
                    return Err(());
                }
                out.push(ch);
            }
            Ok(())
        }
        fn key(&mut self) -> Result<String, ()> {
            if matches!(self.peek(), Some('"' | '\'')) {
                return self.quoted();
            }
            let start = self.at;
            let mut out = String::from("\"");
            loop {
                match self.peek() {
                    Some('\\') => {
                        self.at += 1;
                        if self.take()? != 'u' {
                            return Err(());
                        }
                        out.push_str("\\u");
                        self.hex(4, &mut out)?;
                    }
                    Some(ch)
                        if ch == '_'
                            || ch == '$'
                            || ch.is_ascii_alphabetic()
                            || (self.at > start && ch.is_ascii_digit())
                            || (ch > '\u{7f}' && !ch.is_whitespace() && ch != '\u{feff}') =>
                    {
                        out.push(ch);
                        self.at += 1;
                    }
                    _ => break,
                }
            }
            if self.at == start {
                return Err(());
            }
            let word: String = self.chars[start..self.at].iter().collect();
            // SQLite's value parser recognizes these before its identifier fallback.
            if matches!(word.as_str(), "true" | "false" | "null")
                || matches!(
                    word.to_ascii_lowercase().as_str(),
                    "inf" | "infinity" | "nan" | "qnan" | "snan"
                )
            {
                return Err(());
            }
            out.push('"');
            Ok(out)
        }
        fn value(&mut self, depth: usize) -> Result<String, ()> {
            self.space()?;
            match self.peek().ok_or(())? {
                '"' | '\'' => self.quoted(),
                '{' | '[' => {
                    if depth >= 1000 {
                        return Err(());
                    }
                    let open = self.take()?;
                    let close = if open == '{' { '}' } else { ']' };
                    let mut out = open.to_string();
                    self.space()?;
                    if self.peek() == Some(close) {
                        self.at += 1;
                        out.push(close);
                        return Ok(out);
                    }
                    loop {
                        self.space()?;
                        if open == '{' {
                            out.push_str(&self.key()?);
                            self.space()?;
                            if self.take()? != ':' {
                                return Err(());
                            }
                            out.push(':');
                        }
                        out.push_str(&self.value(depth + 1)?);
                        self.space()?;
                        let next = self.take()?;
                        if next == close {
                            out.push(close);
                            return Ok(out);
                        }
                        if next != ',' {
                            return Err(());
                        }
                        self.space()?;
                        if self.peek() == Some(close) {
                            self.at += 1;
                            out.push(close);
                            return Ok(out);
                        }
                        out.push(',');
                    }
                }
                _ => {
                    let start = self.at;
                    while self
                        .peek()
                        .is_some_and(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'))
                    {
                        self.at += 1;
                    }
                    if self.at == start {
                        return Err(());
                    }
                    let text: String = self.chars[start..self.at].iter().collect();
                    match text.as_str() {
                        "true" | "false" | "null" => Ok(text),
                        _ => number(&text),
                    }
                }
            }
        }
    }
    fn number(text: &str) -> Result<String, ()> {
        let lower = text.to_ascii_lowercase();
        if matches!(lower.as_str(), "nan" | "qnan" | "snan") {
            return Ok("null".into());
        }
        let unsigned = lower
            .strip_prefix('+')
            .or_else(|| lower.strip_prefix('-'))
            .unwrap_or(&lower);
        if matches!(unsigned, "inf" | "infinity") {
            return Ok(if text.starts_with('-') {
                "-9e999"
            } else {
                "9e999"
            }
            .into());
        }
        let normalized = text.strip_prefix('+').unwrap_or(text);
        let unsigned = normalized.strip_prefix('-').unwrap_or(normalized);
        if let Some(hex) = unsigned
            .strip_prefix("0x")
            .or_else(|| unsigned.strip_prefix("0X"))
        {
            if hex.is_empty() || !hex.chars().all(|c| c.is_ascii_hexdigit()) {
                return Err(());
            }
            let digits = hex.trim_start_matches('0');
            let value = if digits.len() > 16 {
                "9.0e999".into()
            } else {
                u64::from_str_radix(if digits.is_empty() { "0" } else { digits }, 16)
                    .map_err(|_| ())?
                    .to_string()
            };
            return Ok(format!(
                "{}{value}",
                if normalized.starts_with('-') { "-" } else { "" }
            ));
        }
        // Validate decimal grammar without converting its potentially huge value.
        let bytes = unsigned.as_bytes();
        let mut i = 0;
        while bytes.get(i).is_some_and(u8::is_ascii_digit) {
            i += 1;
        }
        let integer = i;
        if integer > 1 && bytes[0] == b'0' {
            return Err(());
        }
        let mut has_dot = false;
        let mut fraction = 0;
        if bytes.get(i) == Some(&b'.') {
            has_dot = true;
            i += 1;
            let start = i;
            while bytes.get(i).is_some_and(u8::is_ascii_digit) {
                i += 1;
            }
            fraction = i - start;
        }
        if integer + fraction == 0 {
            return Err(());
        }
        if matches!(bytes.get(i), Some(b'e' | b'E')) {
            i += 1;
            if matches!(bytes.get(i), Some(b'+' | b'-')) {
                i += 1;
            }
            let start = i;
            while bytes.get(i).is_some_and(u8::is_ascii_digit) {
                i += 1;
            }
            if start == i {
                return Err(());
            }
        }
        if i != bytes.len() {
            return Err(());
        }
        let mut result = normalized.to_owned();
        if has_dot && fraction == 0 {
            let dot = result.find('.').ok_or(())?;
            result.insert(dot + 1, '0');
        }
        if has_dot && integer == 0 {
            result.insert(usize::from(result.starts_with('-')), '0');
        }
        Ok(result)
    }
}
