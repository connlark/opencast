//! Small, body-free runtime identity used by authenticated poll diagnostics.
//! The isolate token stays stable while Cloudflare reuses one JavaScript
//! isolate; worker-build's Wasm instance counter advances after a critical
//! reinitialization. Memory reports allocated Wasm pages, not request data.
pub(crate) struct RuntimeDiagnostics {
    pub(crate) isolate_id: String,
    pub(crate) wasm_instance_id: u32,
    pub(crate) wasm_memory_bytes: u32,
}

pub(crate) fn current() -> RuntimeDiagnostics {
    RuntimeDiagnostics {
        isolate_id: crate::worker_glue::isolate_id(),
        wasm_instance_id: crate::worker_glue::wasm_instance_id(),
        wasm_memory_bytes: crate::worker_glue::wasm_memory_bytes(),
    }
}
