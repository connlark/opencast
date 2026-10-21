//! One immutable selection per invocation. Clones share the selection, never a
//! PostgreSQL connection, and cannot extend the absolute deadline.
use super::witness::{OpGuard, Role, Scope, Token, Witness};
use crate::database_selection::{self, ConfigurationError};
use futures_util::{future::pending, FutureExt};
use opencast_worker_database_core::database::Cancellation;
use std::{cell::RefCell, rc::Rc};
use worker::{js_sys, wasm_bindgen::JsValue, Env, Error};

struct Selection {
    env: Env,
    backend: std::result::Result<database_selection::Backend, ConfigurationError>,
    // The identity gate is off unless the version pins STORAGE_IDENTITY; a
    // non-string pin is malformed. The environment is read only when pinned.
    pin: Option<std::result::Result<String, ()>>,
    environment: Option<String>,
    // The storage timing witness, only where a caller asked for one.
    witness: Option<Rc<RefCell<Witness>>>,
}
pub(super) enum Backend<'a> {
    Postgres(&'a Env),
}
#[derive(Clone)]
pub struct Authority {
    selection: Rc<Selection>,
    cancel: Cancellation,
    deadline: u64,
    scope: Scope,
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
                witness: None,
            }),
            cancel,
            deadline,
            scope: Scope::Main,
        })
    }
    /// The same authority with a fresh storage timing witness, shared by every
    /// clone made from it. Recording only: nothing it records changes a bound.
    pub(crate) fn witnessed(mut self, origin: u64, perf_origin: f64) -> Self {
        if let Some(selection) = Rc::get_mut(&mut self.selection) {
            let mut witness = Witness::new(origin);
            witness.perf_origin = perf_origin;
            selection.witness = Some(Rc::new(RefCell::new(witness)));
        }
        self
    }
    /// Times this invocation's non-storage calls; inert without a witness.
    pub(crate) fn timer(&self) -> crate::storage_witness::Timer {
        crate::storage_witness::Timer::new(self.selection.witness.clone())
    }
    /// Records into the witness synchronously, with the storage clock's now;
    /// a no-op without one.
    pub(crate) fn note(&self, record: impl FnOnce(&mut Witness, u64)) {
        if let Some(witness) = &self.selection.witness {
            record(
                &mut witness.borrow_mut(),
                opencast_worker_database_core::database::now(),
            );
        }
    }
    /// Whether this invocation writes its `storage_phases` line, and its
    /// outcome: every dispatch, cleanup and dead-letter; a consume under its
    /// poll_delivery gate, on failed or cancelled, and for the provenance
    /// cohort (feeds whose id's first hex nibble is below 4). The environment
    /// brake's exit reads refused, never ok. None: no line.
    pub(crate) fn witness_emission(&self, consume: bool, ok: bool) -> Option<(&'static str, bool)> {
        let witness = self.selection.witness.as_ref()?.borrow();
        if !consume {
            return Some((if ok { "ok" } else { "failed" }, true));
        }
        let outcome = match witness.context.consume_outcome? {
            "failed" => "failed",
            "cancelled" => "cancelled",
            "polling_disabled" => "refused",
            _ => "ok",
        };
        let cohort = witness
            .context
            .chain
            .as_ref()
            .and_then(|chain| chain.feed.chars().next())
            .is_some_and(|nibble| matches!(nibble, '0'..='3'));
        Some((
            outcome,
            witness.context.consume_gated || outcome != "ok" || cohort,
        ))
    }
    /// The invocation's one `storage_phases` line (schema 2), never over the
    /// byte ceiling.
    pub(crate) fn witness_line(&self, outcome: &'static str) -> Option<String> {
        let witness = self.selection.witness.as_ref()?.borrow();
        Some(crate::storage_phases::line(
            &witness,
            &crate::storage_phases::Inputs {
                outcome,
                now_ms: opencast_worker_database_core::database::now(),
                perf_now: crate::polling::timing::monotonic_ms(),
            },
        ))
    }
    /// Storage-fixture builds only: the fixture's core cancellation token in
    /// place of the request signal's (its /test/cancel-core resolves it).
    #[cfg(feature = "storage-fixture")]
    pub(crate) fn with_cancel(mut self, cancel: Cancellation) -> Self {
        self.cancel = cancel;
        self
    }
    /// The cron's scheduled time (diagnostic only; it bounds nothing).
    pub(crate) fn note_scheduled(&self, scheduled_ms: Option<u64>) {
        if let Some(witness) = &self.selection.witness {
            witness.borrow_mut().scheduled_ms = scheduled_ms;
        }
    }
    /// The same deadline, named for the witness (a step's or an alert's).
    pub(crate) fn scoped(&self, scope: Scope) -> Self {
        Self {
            scope,
            ..self.clone()
        }
    }
    fn token(&self) -> Option<Token> {
        self.selection.witness.as_ref().map(|witness| Token {
            witness: witness.clone(),
            deadline: self.deadline,
            scope: self.scope,
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
            scope: Scope::Bookkeeping,
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
        super::identity::admit(self, &backend, operation, read, None).await?;
        Ok(backend)
    }
    /// `bound()` with the operation's witness guard, opened before the identity
    /// gate (its child) and owned by the caller across its executor call. A
    /// refusal finalizes the guard before it returns.
    pub(super) async fn bound_op(
        &self,
        operation: &str,
        read: bool,
        role: Role,
    ) -> worker::Result<(Backend<'_>, OpGuard)> {
        let guard = OpGuard::open(self.token().as_ref(), operation, role, read, None);
        let backend = match self.backend() {
            Ok(backend) => backend,
            Err(error) => {
                guard.failed(&opencast_worker_database_core::lifecycle::Failure::new(
                    opencast_worker_database_core::lifecycle::Kind::Configuration,
                    opencast_worker_database_core::lifecycle::Phase::Connect,
                ));
                return Err(error);
            }
        };
        if let Err(error) =
            super::identity::admit(self, &backend, operation, read, Some(&guard)).await
        {
            guard.refused();
            return Err(error);
        }
        Ok((backend, guard))
    }
    /// A readback's own guard: its parent is the initiating operation.
    pub(super) fn readback_op(&self, operation: &str, parent: &OpGuard) -> OpGuard {
        OpGuard::open(
            self.token().as_ref(),
            operation,
            Role::Readback,
            true,
            Some(parent),
        )
    }
    /// The identity read's guard, a child of the operation it gates.
    pub(super) fn identity_op(&self, parent: Option<&OpGuard>) -> OpGuard {
        OpGuard::open(
            self.token().as_ref(),
            "identity",
            Role::Identity,
            true,
            parent,
        )
    }
    pub(super) fn note_identity(&self, state: &'static str) {
        if let Some(witness) = &self.selection.witness {
            witness.borrow_mut().note_identity(state);
        }
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
