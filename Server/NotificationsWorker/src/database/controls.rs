//! Invocation control reads share the polling control operation.
use super::polling::{Control, Operation};
use worker::{Env, Result};

pub async fn control(db: &crate::database::Authority, name: &str) -> Result<bool> {
    let control = match name {
        "dispatcher_admission" => Control::DispatcherAdmission,
        "feed_observation" => Control::FeedObservation,
        "episode_activation" => Control::EpisodeActivation,
        "episode_send" => Control::EpisodeSend,
        "job_enrollment" => Control::JobEnrollment,
        "job_send" => Control::JobSend,
        "cleanup" => Control::Cleanup,
        "diagnostic_send" => Control::DiagnosticSend,
        _ => return Err(worker::Error::RustError("invalid_storage_control".into())),
    };
    Ok(super::execute(db, Operation::ReadControl { control })
        .await?
        .first()
        .is_some_and(|value| value["enabled"].as_i64() == Some(1)))
}
pub async fn permitted(env: &Env, db: &crate::database::Authority, name: &str) -> Result<bool> {
    let key = format!("NOTIFICATION_{}", name.to_uppercase());
    Ok(env
        .var(&key)
        .map(|value| value.to_string() != "false")
        .unwrap_or(true)
        && control(db, name).await?)
}
