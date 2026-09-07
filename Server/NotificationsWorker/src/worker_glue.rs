//! The Worker has several tiny JavaScript interop helpers. Keeping them in one
//! inline module avoids duplicate snippet keys in worker-build's import map.
use worker::js_sys::Promise;
use worker::wasm_bindgen::{self, prelude::*};

#[wasm_bindgen(inline_js = r#"
export function opencastWorkerGlue(operation, value, number) {
  switch (operation) {
    case 0:
      return value.getReader({ mode: 'byob' });
    case 1:
      return (async () => {
        const result = await value.read(new Uint8Array(number));
        return result.value && result.value.byteLength ? result.value : null;
      })();
    case 2:
      value.cancel().catch(() => {});
      try { value.releaseLock(); } catch (_) {}
      return undefined;
    case 3:
      return globalThis.__opencast_isolate_id ??= crypto.randomUUID();
    case 4:
      return globalThis.__worker_init_state?.instanceId ?? 0;
    case 5:
      return value.buffer.byteLength;
    default:
      throw new Error('unknown opencast Worker glue operation');
  }
}
"#)]
extern "C" {
    #[wasm_bindgen(catch, js_name = opencastWorkerGlue)]
    fn js_worker_glue(operation: u32, value: &JsValue, number: u32) -> Result<JsValue, JsValue>;
}

pub(crate) fn open_feed_reader(body: &JsValue) -> Result<JsValue, JsValue> {
    js_worker_glue(0, body, 0)
}

pub(crate) fn read_feed_chunk(reader: &JsValue, size: u32) -> Promise {
    match js_worker_glue(1, reader, size) {
        Ok(value) => value.unchecked_into(),
        Err(error) => Promise::reject(&error),
    }
}

pub(crate) fn cancel_feed_reader(reader: &JsValue) {
    let _ = js_worker_glue(2, reader, 0);
}

pub(crate) fn isolate_id() -> String {
    js_worker_glue(3, &JsValue::UNDEFINED, 0)
        .ok()
        .and_then(|value| value.as_string())
        .unwrap_or_default()
}

pub(crate) fn wasm_instance_id() -> u32 {
    js_worker_glue(4, &JsValue::UNDEFINED, 0)
        .ok()
        .and_then(|value| value.as_f64())
        .unwrap_or_default() as u32
}

pub(crate) fn wasm_memory_bytes() -> u32 {
    js_worker_glue(5, &wasm_bindgen::memory(), 0)
        .ok()
        .and_then(|value| value.as_f64())
        .unwrap_or_default() as u32
}
