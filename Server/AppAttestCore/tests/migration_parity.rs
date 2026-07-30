//! Drift tripwire: AdAnalysisWorker and RemoteTranscriptionWorker share the
//! same App Attest auth schema by copied migration file. `wrangler d1
//! migrations` reads real files from disk and `0001` is applied remotely in
//! every lane, so the copies can never be renumbered, re-contented, or
//! symlinked — this test makes a future edit to one copy fail host `cargo
//! test` instead of silently diverging. NotificationsWorker's App Attest
//! schema arrived by its own migration lineage and is deliberately excluded.

#[test]
fn ad_analysis_and_remote_transcription_app_attest_auth_migrations_are_byte_identical() {
    let ad_analysis = include_str!("../../AdAnalysisWorker/migrations/0001_app_attest_auth.sql");
    let remote_transcription =
        include_str!("../../RemoteTranscriptionWorker/migrations/0001_app_attest_auth.sql");
    assert_eq!(
        ad_analysis, remote_transcription,
        "0001_app_attest_auth.sql drifted between AdAnalysisWorker and \
         RemoteTranscriptionWorker; both lanes have 0001 applied remotely, so \
         fix by making the files byte-identical again, never by renumbering"
    );
}
