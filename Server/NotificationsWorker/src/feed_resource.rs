//! Shared decoded-input policy; guarded against app drift by preflight.
pub const MAX_DECODED_BYTES: usize = 128 * 1024 * 1024;
pub const MAX_ITEMS: usize = 100_000;
pub const MAX_DEPTH: usize = 50;
pub const MAX_FIELD_BYTES: usize = 12 * 1024 * 1024;
pub const MAX_ITEM_TEXT_BYTES: usize = 16 * 1024 * 1024;
pub const MAX_PROCESSING_BYTES: usize = 512 * 1024 * 1024;
pub const CHUNK_BYTES: usize = 64 * 1024;
pub const MAX_ACTIVE_SCANS: usize = 2;
pub const INACTIVITY_SECONDS: u64 = 20;
pub const SCAN_DEADLINE_SECONDS: u64 = 120;
pub const POLL_ADMISSION_SECONDS: i64 = 20;
