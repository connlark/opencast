use worker::js_sys::Reflect;
use worker::wasm_bindgen::{JsCast, JsValue};
use worker::{Env, Error, Fetcher, Result};

// Deployed Workers can receive a service binding whose class is a `Fetcher`
// subclass with another name, which `Env::service` refuses: check `fetch`.
pub fn service(env: &Env, name: &str) -> Result<Fetcher> {
    let binding = Reflect::get(env, &JsValue::from_str(name))?;
    if binding.is_object() && Reflect::get(&binding, &JsValue::from_str("fetch"))?.is_function() {
        Ok(binding.unchecked_into())
    } else {
        Err(Error::RustError(format!("{name} is not a service binding")))
    }
}
