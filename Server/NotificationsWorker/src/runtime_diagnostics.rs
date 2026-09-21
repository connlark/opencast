//! Allocated Wasm bytes for bounded runtime health checks; no request data.
pub(crate) struct RuntimeDiagnostics {
    pub(crate) wasm_memory_bytes: u32,
}
pub(crate) fn current() -> RuntimeDiagnostics {
    RuntimeDiagnostics {
        wasm_memory_bytes: crate::worker_glue::wasm_memory_bytes(),
    }
}
