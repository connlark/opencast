//! The identifiers the App Attest routes store or look up, checked before D1
//! sees them: the app's install id (`UUID().uuidString`), the App Attest key
//! id (base64 of a 32-byte key identifier) and the challenge id and
//! challenge this worker issues. Anything else is refused, so an identifier
//! field can never hold text a client chose.

use opencast_app_attest_core::app_attest::canonical_key_id;

/// Random bytes in an issued challenge id and challenge.
pub const CHALLENGE_ID_BYTES: usize = 16;
pub const CHALLENGE_BYTES: usize = 32;
/// Standard base64 of 32 bytes, with its padding.
const MAX_KEY_ID_CHARS: usize = 44;

/// `8-4-4-4-12` hexadecimal digits, either case.
pub fn is_install_id(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => byte == b'-',
            _ => byte.is_ascii_hexdigit(),
        })
}

/// The canonical key id (standard base64) when `value` encodes exactly the
/// 32 bytes of an App Attest key identifier.
pub fn key_id(value: &str) -> Option<String> {
    if value.len() > MAX_KEY_ID_CHARS {
        return None;
    }
    canonical_key_id(value).ok()
}

fn base64url_digit(byte: u8) -> Option<u8> {
    match byte {
        b'A'..=b'Z' => Some(byte - b'A'),
        b'a'..=b'z' => Some(byte - b'a' + 26),
        b'0'..=b'9' => Some(byte - b'0' + 52),
        b'-' => Some(62),
        b'_' => Some(63),
        _ => None,
    }
}

/// Exactly the URL-safe base64, unpadded, of `bytes` bytes, as
/// `random_urlsafe_token` issues it: the right length, the alphabet, and
/// the last digit's unused low bits zero.
fn is_issued_token(value: &str, bytes: usize) -> bool {
    let digits = (bytes * 4).div_ceil(3);
    let unused_bits = digits * 6 - bytes * 8;
    value.len() == digits
        && value.bytes().all(|byte| base64url_digit(byte).is_some())
        && value
            .bytes()
            .last()
            .and_then(base64url_digit)
            .is_some_and(|last| last & ((1 << unused_bits) - 1) == 0)
}

pub fn is_challenge_id(value: &str) -> bool {
    is_issued_token(value, CHALLENGE_ID_BYTES)
}

pub fn is_challenge(value: &str) -> bool {
    is_issued_token(value, CHALLENGE_BYTES)
}

#[cfg(test)]
mod tests {
    use super::*;
    use opencast_app_attest_core::random::random_urlsafe_token;

    const CANARY: &str = "CANARY-TRANSCRIPT-7f3a9c";

    #[test]
    fn install_ids_are_the_apps_uuid_strings() {
        assert!(is_install_id("6F9619FF-8B86-D011-B42D-00CF4FC964FF"));
        assert!(is_install_id("6f9619ff-8b86-d011-b42d-00cf4fc964ff"));
        for refused in [
            CANARY,
            "",
            "6F9619FF-8B86-D011-B42D-00CF4FC964F",
            "6F9619FF-8B86-D011-B42D-00CF4FC964FFF",
            "6F9619FF8B86-D011-B42D-00CF4FC964FFF",
            "6F9619FF-8B86-D011-B42D-00CF4FC964FG",
            "{6F9619FF-8B86-D011-B42D-00CF4FC964F}",
            "6F9619FF-8B86-D011-B42D-00CF4FC964F\u{e9}",
        ] {
            assert!(!is_install_id(refused), "{refused}");
        }
    }

    #[test]
    fn key_ids_encode_exactly_thirty_two_bytes() {
        let standard = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=";
        assert_eq!(key_id(standard).as_deref(), Some(standard));
        // The URL-safe unpadded form canonicalizes to the standard one.
        assert_eq!(
            key_id("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8").as_deref(),
            Some(standard)
        );
        for refused in [
            CANARY,
            "",
            "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHg==",
            "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gIQ==",
            "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=    ",
        ] {
            assert_eq!(key_id(refused), None, "{refused}");
        }
    }

    #[test]
    fn challenge_ids_and_challenges_have_the_issued_shape() {
        for _ in 0..32 {
            assert!(is_challenge_id(
                &random_urlsafe_token(CHALLENGE_ID_BYTES).unwrap()
            ));
            assert!(is_challenge(
                &random_urlsafe_token(CHALLENGE_BYTES).unwrap()
            ));
        }
        let id = random_urlsafe_token(CHALLENGE_ID_BYTES).unwrap();
        for refused in [
            CANARY.to_string(),
            String::new(),
            format!("{id}A"),
            id[1..].to_string(),
            format!("{}=", &id[1..]),
            format!("{}+", &id[1..]),
        ] {
            assert!(!is_challenge_id(&refused), "{refused}");
        }
        assert!(!is_challenge(&id));
        // The alphabet and the issued length are not enough: 16 bytes leave
        // the last digit's four low bits unused, so they must be zero.
        assert!(!is_challenge_id("CANARY-TRANSCRIPT-91c4"));
        assert!(is_challenge_id("CANARY-TRANSCRIPT-91cA"));
        assert!(!is_challenge(CANARY));
    }
}
