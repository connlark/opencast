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
use std::{cell::RefCell, rc::Rc};
use worker::{Bucket, MultipartUpload, Range, Result, UploadedPart};

/// Buffered bytes that stay in the isolate. R2 requires equal parts of at least
/// 5 MiB, so this is also the exact scratch part size. It is R2's minimum: a
/// part is briefly held twice (Wasm and the runtime's copy) while it uploads.
/// The retained feed body uses the same constant, so both spill the same way.
pub const BUFFER_BYTES: usize = super::body::BODY_BUFFER_BYTES;
pub const PREFIX: &str = "scratch/";

/// One private multipart scratch upload. Its first part creates it under a
/// fresh `scratch/{feed}/{uuid}` key; parts are numbered from 1 in push order.
#[derive(Default)]
pub struct Upload {
    started: Option<(String, Rc<MultipartUpload>)>,
    parts: Vec<UploadedPart>,
}
impl Upload {
    /// The scratch key, once the first part has created the upload.
    pub fn key(&self) -> Option<&str> {
        self.started.as_ref().map(|(key, _)| key.as_str())
    }
}
/// Shared, so whoever owns the scan (not only the future that is uploading a
/// part, which a deadline may drop) keeps the handle that aborts it. No borrow
/// is ever held across an await.
pub type Spill = Rc<RefCell<Upload>>;

/// Uploads `part` as the next part of `spill`, creating the upload first.
pub async fn push_part(spill: &Spill, bucket: &Bucket, feed_id: &str, part: Vec<u8>) -> Result<()> {
    let started = spill
        .borrow()
        .started
        .as_ref()
        .map(|(_, upload)| upload.clone());
    let upload = match started {
        Some(upload) => upload,
        None => {
            let key = format!("{PREFIX}{feed_id}/{}", crate::delivery::db::id());
            let upload = Rc::new(bucket.create_multipart_upload(&key).execute().await?);
            spill.borrow_mut().started = Some((key, upload.clone()));
            upload
        }
    };
    upload_next(spill, &upload, part).await
}
/// Uploads the last part of a started upload. R2 requires every other part to
/// be the same size; only this one may be shorter.
pub async fn push_final_part(spill: &Spill, part: Vec<u8>) -> Result<()> {
    let started = spill
        .borrow()
        .started
        .as_ref()
        .map(|(_, upload)| upload.clone());
    let upload = started.ok_or_else(|| fault("scratch_missing"))?;
    upload_next(spill, &upload, part).await
}
async fn upload_next(spill: &Spill, upload: &MultipartUpload, part: Vec<u8>) -> Result<()> {
    let number =
        u16::try_from(spill.borrow().parts.len() + 1).map_err(|_| fault("scratch_parts"))?;
    let uploaded = upload.upload_part(number, part).await?;
    spill.borrow_mut().parts.push(uploaded);
    Ok(())
}
/// Best effort: an upload that cannot be aborted still expires.
pub async fn abort(spill: &Spill) {
    let started = {
        let mut upload = spill.borrow_mut();
        upload.parts.clear();
        upload.started.take()
    };
    if let Some((_, upload)) = started {
        if upload.abort().await.is_err() {
            worker::console_warn!(
                "{}",
                serde_json::json!({"event":"feed_scratch_abort_failed"})
            );
        }
    }
}
/// Completes the upload into an object and returns its key; `None` when no
/// part was ever uploaded. Completing spends the handle, so a failed
/// completion is aborted through a resumed one (best effort, as `abort`).
pub async fn complete(spill: &Spill, bucket: &Bucket) -> Result<Option<String>> {
    let (started, parts) = {
        let mut upload = spill.borrow_mut();
        (upload.started.take(), std::mem::take(&mut upload.parts))
    };
    let Some((key, upload)) = started else {
        return Ok(None);
    };
    let upload = Rc::try_unwrap(upload).map_err(|_| fault("scratch_upload_busy"))?;
    let id = upload.upload_id().await;
    if let Err(error) = upload.complete(parts).await {
        let resumed = bucket.resume_multipart_upload(key, id).map(|upload| {
            Rc::new(RefCell::new(Upload {
                started: Some((String::new(), Rc::new(upload))),
                parts: vec![],
            }))
        });
        if let Ok(resumed) = resumed {
            abort(&resumed).await;
        }
        return Err(error);
    }
    Ok(Some(key))
}

#[derive(Default)]
pub struct Pending {
    buffer: Vec<u8>,
    /// Byte length and record count of every page, in scan order.
    pages: Vec<(usize, usize)>,
    spilled: usize,
    upload: Spill,
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
            let rest = self.buffer.split_off(BUFFER_BYTES);
            let part = std::mem::replace(&mut self.buffer, rest);
            push_part(&self.upload, bucket, feed_id, part).await?;
            self.spilled += BUFFER_BYTES;
        }
        Ok(())
    }
    /// The comparison finished without a change, or the scan failed.
    pub async fn discard(&mut self) {
        self.buffer = vec![];
        self.pages.clear();
        abort(&self.upload).await;
    }
    /// A change is proved and the store holds its lease: every page becomes an
    /// ordinary reserved, verified spool page, in its original order.
    pub async fn materialize(mut self, store: &mut Store) -> Result<Vec<Page>> {
        let mut spool = vec![];
        let scratch = complete(&self.upload, &store.bucket).await?;
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
pub async fn read(bucket: &Bucket, key: &str, offset: usize, length: usize) -> Result<Vec<u8>> {
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
pub async fn sweep(bucket: &Bucket, now_ms: u64, budget: &super::gc::Budget) -> Result<usize> {
    if budget.expired() {
        return Ok(0);
    }
    let listed = bucket.list().prefix(PREFIX).limit(100).execute().await?;
    let mut removed = 0;
    for object in listed.objects() {
        if budget.expired() {
            break;
        }
        if object.uploaded().as_millis() + 3_600_000 <= now_ms {
            bucket.delete(object.key()).await?;
            removed += 1;
        }
    }
    Ok(removed)
}
