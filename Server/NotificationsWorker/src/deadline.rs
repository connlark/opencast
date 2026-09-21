//! Cancellation-safe deadline shared by publisher and APNs requests.
use futures_util::future::{select, Either};
use std::{future::Future, pin::pin};

/// Races a fetch against a deadline future. A fetch that outlives the
/// deadline is dropped and reported as `timeout_error`, taking the same
/// failure/backoff path as any other failed fetch.
pub async fn fetch_with_deadline<T, E>(
    fetch: impl Future<Output = Result<T, E>>,
    deadline: impl Future<Output = ()>,
    timeout_error: E,
) -> Result<T, E> {
    let fetch = pin!(fetch);
    let deadline = pin!(deadline);
    match select(fetch, deadline).await {
        Either::Left((result, _)) => result,
        Either::Right(((), _)) => Err(timeout_error),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures_util::FutureExt;
    #[test]
    fn hung_fetch_times_out_onto_the_failure_path() {
        // A fetch that never resolves must not hang the tick: the deadline
        // arm wins and surfaces the caller's timeout error.
        let result = fetch_with_deadline(
            std::future::pending::<Result<&str, &str>>(),
            std::future::ready(()),
            "fetch_timeout",
        )
        .now_or_never();

        assert_eq!(result, Some(Err("fetch_timeout")));
    }
    #[test]
    fn completed_fetch_wins_over_pending_deadline() {
        let result = fetch_with_deadline(
            std::future::ready(Ok::<&str, &str>("body")),
            std::future::pending::<()>(),
            "fetch_timeout",
        )
        .now_or_never();

        assert_eq!(result, Some(Ok("body")));
    }
    #[test]
    fn fetch_error_passes_through_the_deadline_race_unchanged() {
        let result = fetch_with_deadline(
            std::future::ready(Err::<&str, &str>("dns_failure")),
            std::future::pending::<()>(),
            "fetch_timeout",
        )
        .now_or_never();

        assert_eq!(result, Some(Err("dns_failure")));
    }
}
