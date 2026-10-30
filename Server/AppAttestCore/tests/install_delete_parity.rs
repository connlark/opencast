//! D1 is wasm-only. Pin the host-visible delegation contract here; each
//! consumer's workerd tests execute the statements against real local D1.
#[test]
fn standalone_delete_uses_the_same_statements_as_composed_batches() {
    let source = include_str!("../src/app_attest_storage.rs");
    let builder = source
        .split("pub fn install_delete_statements(")
        .nth(1)
        .unwrap()
        .split("/// Deletes an install")
        .next()
        .unwrap();
    assert!(builder.contains("DELETE FROM app_attest_challenges WHERE install_id = ?1"));
    assert!(builder.contains("DELETE FROM app_attest_keys WHERE install_id = ?1"));
    assert_eq!(builder.matches("DELETE FROM").count(), 2);
    assert!(builder.contains("D1Type::Text(install_id)"));
    assert!(builder.contains(".bind_refs(&args)"));

    let wrapper = source
        .split("pub async fn delete_install_rows(")
        .nth(1)
        .unwrap()
        .split("pub async fn mark_challenge_consumed")
        .next()
        .unwrap();
    assert!(wrapper.contains("db.batch(install_delete_statements(db, install_id)?).await?;"));
    assert!(!wrapper.contains(".prepare("));
    assert_eq!(wrapper.matches(".batch(").count(), 1);
}
