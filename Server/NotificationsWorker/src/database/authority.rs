//! One immutable selection per invocation. Clones share the selection, never a
//! PostgreSQL connection, and cannot extend the absolute deadline.
use crate::database_selection::{self, ConfigurationError};
use futures_util::{future::pending, FutureExt};
use opencast_worker_database_core::database::Cancellation;
use std::rc::Rc;
use worker::{js_sys, wasm_bindgen::JsValue, Env, Error};

struct Selection {
    env: Env,
    backend: std::result::Result<database_selection::Backend, ConfigurationError>,
    // The identity gate is off unless the version pins STORAGE_IDENTITY; a
    // non-string pin is malformed. The environment is read only when pinned.
    pin: Option<std::result::Result<String, ()>>,
    environment: Option<String>,
}
pub(super) enum Backend<'a> {
    Postgres(&'a Env),
}
#[derive(Clone)]
pub struct Authority {
    selection: Rc<Selection>,
    cancel: Cancellation,
    deadline: u64,
}
impl Authority {
    pub fn new(
        env: &Env,
        signal: Option<worker::web_sys::AbortSignal>,
        deadline: u64,
    ) -> worker::Result<Self> {
        // A non-string binding is invalid, not an absent variable. Defer the
        // configuration error until the first storage call.
        let backend =
            match js_sys::Reflect::get(env.as_ref(), &JsValue::from_str("STORAGE_AUTHORITY")) {
                Ok(value) if value.is_undefined() => database_selection::select(None),
                Ok(value) => value
                    .as_string()
                    .ok_or(ConfigurationError::InvalidAuthority)
                    .and_then(|value| database_selection::select(Some(&value))),
                Err(_) => Err(ConfigurationError::InvalidAuthority),
            };
        let pin = match js_sys::Reflect::get(env.as_ref(), &JsValue::from_str("STORAGE_IDENTITY")) {
            Ok(value) if value.is_undefined() => None,
            Ok(value) => Some(value.as_string().ok_or(())),
            Err(_) => Some(Err(())),
        };
        let environment = pin.as_ref().and_then(|_| {
            js_sys::Reflect::get(env.as_ref(), &JsValue::from_str("NOTIFICATION_ENVIRONMENT"))
                .ok()
                .and_then(|value| value.as_string())
        });
        let cancel = match signal {
            Some(signal) => super::cancellation::Abort::new(signal)?
                .boxed_local()
                .shared(),
            None => pending().boxed_local().shared(),
        };
        Ok(Self {
            selection: Rc::new(Selection {
                env: env.clone(),
                backend,
                pin,
                environment,
            }),
            cancel,
            deadline,
        })
    }
    pub fn default_deadline(arrived: u64) -> u64 {
        arrived.saturating_add(opencast_worker_database_core::lifecycle::HANDLER_MS)
    }
    pub fn capped_at(&self, deadline: u64) -> Self {
        Self {
            deadline: self.deadline.min(deadline),
            ..self.clone()
        }
    }
    /// Post-phase bookkeeping shares the selection and remains inside the
    /// invocation's outer cap, independently of the work phase's cancellation.
    pub(crate) fn bookkeeping(&self, deadline: u64) -> Self {
        Self {
            cancel: pending().boxed_local().shared(),
            ..self.capped_at(deadline)
        }
    }
    pub(super) fn backend(&self) -> worker::Result<Backend<'_>> {
        match self
            .selection
            .backend
            .map_err(|error| Error::RustError(error.code().into()))?
        {
            database_selection::Backend::Postgres => Ok(Backend::Postgres(&self.selection.env)),
        }
    }
    pub(super) fn identity_pin(&self) -> Option<std::result::Result<&str, ()>> {
        self.selection
            .pin
            .as_ref()
            .map(|pin| pin.as_deref().map_err(|_| ()))
    }
    pub(super) fn identity_environment(&self) -> Option<&str> {
        self.selection.environment.as_deref()
    }
    /// The selected backend, behind the identity gate when the version is
    /// pinned. Called by every storage entry before it submits anything.
    pub(super) async fn bound(&self, operation: &str, read: bool) -> worker::Result<Backend<'_>> {
        let backend = self.backend()?;
        super::identity::admit(self, &backend, operation, read).await?;
        Ok(backend)
    }
    pub(super) fn context(&self) -> (Cancellation, u64) {
        (self.cancel.clone(), self.deadline)
    }
    pub(crate) fn attest(&self) -> worker::Result<super::slice_c::GatedAttest<'_>> {
        let storage = match self.backend()? {
            Backend::Postgres(env) => {
                let (cancel, deadline) = self.context();
                super::slice_c::AttestAuthority::Postgres {
                    env,
                    cancel,
                    deadline,
                }
            }
        };
        Ok(super::slice_c::GatedAttest {
            authority: self,
            storage,
        })
    }
}
