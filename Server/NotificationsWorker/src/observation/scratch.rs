//! Spool pages held before a scan has proved a semantic change. They live in a
//! bounded worker buffer; only a feed too large for it spills into one private
//! multipart scratch upload. Scratch has no D1 row and no event authority. An
//! unchanged, failed or truncated scan aborts the upload, so nothing becomes an
//! object; R2 expires an upload abandoned by a crash. Only a proved change
//! completes it, copies the pages under the claimed lease and deletes it.
use super::{
    snapshot::Page,
    store::{fault, Store},
};
use worker::{Bucket, MultipartUpload, Range, Result, UploadedPart};

/// Buffered bytes that stay in the isolate. R2 requires equal parts of at least
/// 5 MiB, so this is also the exact scratch part size. It is R2's minimum: a
/// part is briefly held twice (Wasm and the runtime's copy) while it uploads.
pub const BUFFER_BYTES: usize = 5 * 1024 * 1024;
pub const PREFIX: &str = "scratch/";

#[derive(Default)]
pub struct Pending {
    buffer: Vec<u8>,
    /// Byte length and record count of every page, in scan order.
    pages: Vec<(usize, usize)>,
    spilled: usize,
    upload: Option<(String, MultipartUpload)>,
    parts: Vec<UploadedPart>,
}
impl Pending {
    pub async fn push(
        &mut self,
        bucket: &Bucket,
        feed_id: &str,
        bytes: Vec<u8>,
        count: usize,
    ) -> Result<()> {
        self.pages.push((bytes.len(), count));
        self.buffer.extend(bytes);
        while self.buffer.len() >= BUFFER_BYTES {
            if self.upload.is_none() {
                let key = format!("{PREFIX}{feed_id}/{}", crate::delivery::db::id());
                let upload = bucket.create_multipart_upload(&key).execute().await?;
                self.upload = Some((key, upload));
            }
            let rest = self.buffer.split_off(BUFFER_BYTES);
            let part = std::mem::replace(&mut self.buffer, rest);
            let number = u16::try_from(self.parts.len() + 1).map_err(|_| fault("scratch_parts"))?;
            let (_, upload) = self.upload.as_ref().expect("scratch upload");
            self.parts.push(upload.upload_part(number, part).await?);
            self.spilled += BUFFER_BYTES;
        }
        Ok(())
    }
    /// The comparison finished without a change, or the scan failed.
    pub async fn discard(&mut self) {
        self.buffer = vec![];
        self.pages.clear();
        self.parts.clear();
        if let Some((_, upload)) = self.upload.take() {
            // Best effort: an upload that cannot be aborted still expires.
            if upload.abort().await.is_err() {
                worker::console_warn!(
                    "{}",
                    serde_json::json!({"event":"feed_scratch_abort_failed"})
                );
            }
        }
    }
    /// A change is proved and the store holds its lease: every page becomes an
    /// ordinary reserved, verified spool page, in its original order.
    pub async fn materialize(mut self, store: &mut Store) -> Result<Vec<Page>> {
        let mut spool = vec![];
        let scratch = match self.upload.take() {
            Some((key, upload)) => {
                upload.complete(std::mem::take(&mut self.parts)).await?;
                Some(key)
            }
            None => None,
        };
        let mut offset = 0;
        let mut window: (usize, Vec<u8>) = (0, vec![]);
        for (length, count) in std::mem::take(&mut self.pages) {
            let bytes = if offset + length <= self.spilled {
                let key = scratch.as_ref().ok_or_else(|| fault("scratch_missing"))?;
                if offset < window.0 || offset + length > window.0 + window.1.len() {
                    let size = BUFFER_BYTES.max(length).min(self.spilled - offset);
                    window = (offset, read(&store.bucket, key, offset, size).await?);
                }
                window.1[offset - window.0..offset - window.0 + length].to_vec()
            } else if offset >= self.spilled {
                let start = offset - self.spilled;
                self.buffer[start..start + length].to_vec()
            } else {
                // One page straddles the last uploaded part and the buffer.
                let key = scratch.as_ref().ok_or_else(|| fault("scratch_missing"))?;
                let head = self.spilled - offset;
                let mut bytes = read(&store.bucket, key, offset, head).await?;
                bytes.extend(&self.buffer[..length - head]);
                bytes
            };
            offset += length;
            spool.push(
                store
                    .put("spool", bytes, count, String::new(), String::new())
                    .await?,
            );
        }
        if let Some(key) = scratch {
            // A crash before this delete leaves one object for the sweeper.
            store.bucket.delete(key).await?;
        }
        Ok(spool)
    }
}
async fn read(bucket: &Bucket, key: &str, offset: usize, length: usize) -> Result<Vec<u8>> {
    let bytes = bucket
        .get(key)
        .range(Range::OffsetWithLength {
            offset: offset as u64,
            length: length as u64,
        })
        .execute()
        .await?
        .ok_or_else(|| fault("scratch_missing"))?
        .body()
        .ok_or_else(|| fault("scratch_missing"))?
        .bytes()
        .await?;
    if bytes.len() != length {
        return Err(fault("scratch_range"));
    }
    Ok(bytes)
}
/// Completed scratch objects survive only a crash between copy and delete.
pub async fn sweep(bucket: &Bucket, now_ms: u64) -> Result<usize> {
    let listed = bucket.list().prefix(PREFIX).limit(100).execute().await?;
    let mut removed = 0;
    for object in listed.objects() {
        if object.uploaded().as_millis() + 3_600_000 <= now_ms {
            bucket.delete(object.key()).await?;
            removed += 1;
        }
    }
    Ok(removed)
}
