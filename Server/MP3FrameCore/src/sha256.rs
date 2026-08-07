//! Minimal streaming FIPS 180-4 SHA-256.
//!
//! The crate is deliberately dependency-free, so the planner's per-chunk
//! hashing carries its own implementation instead of `sha2`. The Worker
//! re-verifies every span read with `sha2` before spending an AI call, so a
//! defect here fails closed in production rather than corrupting output.

const K: [u32; 64] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

const INITIAL_STATE: [u32; 8] = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
];

#[derive(Debug, Clone)]
pub struct Sha256 {
    state: [u32; 8],
    block: [u8; 64],
    block_len: usize,
    message_bytes: u64,
}

impl Default for Sha256 {
    fn default() -> Self {
        Self::new()
    }
}

impl Sha256 {
    pub fn new() -> Self {
        Self {
            state: INITIAL_STATE,
            block: [0; 64],
            block_len: 0,
            message_bytes: 0,
        }
    }

    pub fn update(&mut self, mut bytes: &[u8]) {
        self.message_bytes += bytes.len() as u64;
        if self.block_len > 0 {
            let take = bytes.len().min(64 - self.block_len);
            self.block[self.block_len..self.block_len + take].copy_from_slice(&bytes[..take]);
            self.block_len += take;
            bytes = &bytes[take..];
            if self.block_len < 64 {
                return;
            }
            let block = self.block;
            self.compress(&block);
            self.block_len = 0;
        }
        let mut whole = bytes.chunks_exact(64);
        for block in &mut whole {
            let block: &[u8; 64] = block.try_into().expect("chunks_exact yields 64");
            self.compress(block);
        }
        let rest = whole.remainder();
        self.block[..rest.len()].copy_from_slice(rest);
        self.block_len = rest.len();
    }

    pub fn finalize(mut self) -> [u8; 32] {
        let bit_len = self.message_bytes * 8;
        let mut tail = [0u8; 128];
        tail[0] = 0x80;
        // Pad to 56 mod 64, then the big-endian bit length.
        let pad_len = if self.block_len < 56 {
            56 - self.block_len
        } else {
            120 - self.block_len
        };
        tail[pad_len..pad_len + 8].copy_from_slice(&bit_len.to_be_bytes());
        self.update_padding(&tail[..pad_len + 8]);

        let mut digest = [0u8; 32];
        for (index, word) in self.state.iter().enumerate() {
            digest[index * 4..index * 4 + 4].copy_from_slice(&word.to_be_bytes());
        }
        digest
    }

    /// `update` minus the message-length accounting, for the final padding.
    fn update_padding(&mut self, bytes: &[u8]) {
        let saved = self.message_bytes;
        self.update(bytes);
        self.message_bytes = saved;
        debug_assert_eq!(self.block_len, 0, "padding must end on a block boundary");
    }

    fn compress(&mut self, block: &[u8; 64]) {
        let mut w = [0u32; 64];
        for (index, word) in block.chunks_exact(4).enumerate() {
            w[index] = u32::from_be_bytes([word[0], word[1], word[2], word[3]]);
        }
        for index in 16..64 {
            let s0 = w[index - 15].rotate_right(7)
                ^ w[index - 15].rotate_right(18)
                ^ (w[index - 15] >> 3);
            let s1 = w[index - 2].rotate_right(17)
                ^ w[index - 2].rotate_right(19)
                ^ (w[index - 2] >> 10);
            w[index] = w[index - 16]
                .wrapping_add(s0)
                .wrapping_add(w[index - 7])
                .wrapping_add(s1);
        }
        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut h] = self.state;
        for index in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ ((!e) & g);
            let temp1 = h
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[index])
                .wrapping_add(w[index]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let temp2 = s0.wrapping_add(maj);
            h = g;
            g = f;
            f = e;
            e = d.wrapping_add(temp1);
            d = c;
            c = b;
            b = a;
            a = temp1.wrapping_add(temp2);
        }
        for (slot, value) in self.state.iter_mut().zip([a, b, c, d, e, f, g, h]) {
            *slot = slot.wrapping_add(value);
        }
    }
}

pub fn digest(message: &[u8]) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(message);
    hasher.finalize()
}

/// Lowercase hex, byte-for-byte what `hex::encode` produces — the manifest
/// chain hashes these strings, so the encoding is part of the contract.
pub fn hex(digest: &[u8; 32]) -> String {
    let mut out = String::with_capacity(64);
    for byte in digest {
        out.push(char::from_digit(u32::from(byte >> 4), 16).expect("nibble"));
        out.push(char::from_digit(u32::from(byte & 0xF), 16).expect("nibble"));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// NIST FIPS 180-4 known-answer tests.
    #[test]
    fn known_answer_tests_match_the_standard() {
        assert_eq!(
            hex(&digest(b"")),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            hex(&digest(b"abc")),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(
            hex(&digest(
                b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
            )),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        );
        let million_a = vec![b'a'; 1_000_000];
        assert_eq!(
            hex(&digest(&million_a)),
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        );
    }

    /// Streaming must be split-invariant: any partition of the message into
    /// `update` calls yields the one-shot digest.
    #[test]
    fn streamed_updates_are_split_invariant() {
        let message: Vec<u8> = (0..1_000u32)
            .flat_map(|value| value.to_le_bytes())
            .collect();
        let expected = digest(&message);
        for split in [1usize, 3, 7, 55, 56, 63, 64, 65, 128, 1441, 4096] {
            let mut hasher = Sha256::new();
            for piece in message.chunks(split) {
                hasher.update(piece);
            }
            assert_eq!(hasher.finalize(), expected, "split {split} diverged");
        }
        // Interleave empty updates too — they must be no-ops.
        let mut hasher = Sha256::new();
        hasher.update(&[]);
        hasher.update(&message);
        hasher.update(&[]);
        assert_eq!(hasher.finalize(), expected);
    }

    /// The 55/56/64-byte neighborhood exercises both padding branches.
    #[test]
    fn padding_boundaries_round_trip() {
        for len in 50..=130usize {
            let message = vec![0xA5u8; len];
            let streamed = {
                let mut hasher = Sha256::new();
                for piece in message.chunks(9) {
                    hasher.update(piece);
                }
                hasher.finalize()
            };
            assert_eq!(streamed, digest(&message), "length {len} diverged");
        }
    }

    #[test]
    fn hex_is_lowercase_and_stable() {
        let digest = digest(b"abc");
        let encoded = hex(&digest);
        assert_eq!(encoded.len(), 64);
        assert!(encoded
            .chars()
            .all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c)));
    }
}
