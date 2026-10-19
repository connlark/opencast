//! Owned backend-neutral values and result rules. Debug never prints SQL or data.
use crate::lifecycle::{Failure, Kind, Phase};
use serde::{Deserialize, Serialize};

/// D1 binds integers through JavaScript's exactly representable number range.
pub const MAX_SAFE_INTEGER: i64 = 9_007_199_254_740_991;

#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", content = "value", rename_all = "snake_case")]
pub enum Parameter {
    Text(Option<String>),
    Integer(Option<i64>),
    Bytes(Option<Vec<u8>>),
    TextArray(Option<Vec<Option<String>>>),
    IntegerArray(Option<Vec<Option<i64>>>),
}
impl std::fmt::Debug for Parameter {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Parameter(<redacted>)")
    }
}
impl Parameter {
    pub fn validate(&self) -> Result<(), Failure> {
        let valid = |value: i64| (-MAX_SAFE_INTEGER..=MAX_SAFE_INTEGER).contains(&value);
        let accepted = match self {
            Self::Integer(Some(value)) => valid(*value),
            Self::IntegerArray(Some(values)) => values.iter().flatten().all(|v| valid(*v)),
            _ => true,
        };
        if accepted {
            Ok(())
        } else {
            Err(Failure::new(Kind::Assertion, Phase::Transaction))
        }
    }

    #[cfg(all(target_arch = "wasm32", feature = "postgres"))]
    pub(crate) fn typed(
        &self,
    ) -> (
        &(dyn tokio_postgres::types::ToSql + Sync),
        tokio_postgres::types::Type,
    ) {
        use tokio_postgres::types::Type;
        match self {
            Self::Text(value) => (value, Type::TEXT),
            Self::Integer(value) => (value, Type::INT8),
            Self::Bytes(value) => (value, Type::BYTEA),
            Self::TextArray(value) => (value, Type::TEXT_ARRAY),
            Self::IntegerArray(value) => (value, Type::INT8_ARRAY),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CountRule {
    Any,
    AtMost(u64),
    Exactly(u64),
}
impl CountRule {
    pub fn accepts(self, count: u64) -> bool {
        match self {
            Self::Any => true,
            Self::AtMost(max) => count <= max,
            Self::Exactly(expected) => count == expected,
        }
    }
}

/// Constructed only by the backend's semantic implementation, never an HTTP caller.
#[derive(Clone)]
pub struct Statement {
    pub sql: String,
    pub parameters: Vec<Parameter>,
    pub count: CountRule,
}
impl std::fmt::Debug for Statement {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Statement(<redacted>)")
    }
}
impl Statement {
    pub fn validate(&self) -> Result<(), Failure> {
        for value in &self.parameters {
            value.validate()?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn integer_boundary_is_exact_for_scalars_and_nullable_array_elements() {
        for value in [-MAX_SAFE_INTEGER, 0, MAX_SAFE_INTEGER] {
            assert!(Parameter::Integer(Some(value)).validate().is_ok());
        }
        for value in [
            i64::MIN,
            -MAX_SAFE_INTEGER - 1,
            MAX_SAFE_INTEGER + 1,
            i64::MAX,
        ] {
            assert!(Parameter::Integer(Some(value)).validate().is_err());
            assert!(Parameter::IntegerArray(Some(vec![None, Some(value)]))
                .validate()
                .is_err());
        }
        assert!(Parameter::Integer(None).validate().is_ok());
        assert!(Parameter::IntegerArray(Some(vec![])).validate().is_ok());
        assert!(
            Parameter::IntegerArray(Some(vec![Some(3), None, Some(3), Some(1)]))
                .validate()
                .is_ok()
        );
    }
    #[test]
    fn count_rules_distinguish_valid_noop_and_invalid_multiple_rows() {
        assert!(CountRule::AtMost(1).accepts(0));
        assert!(CountRule::AtMost(1).accepts(1));
        assert!(!CountRule::AtMost(1).accepts(2));
        assert!(!CountRule::Exactly(1).accepts(0));
        assert!(CountRule::Exactly(1).accepts(1));
        assert!(!CountRule::Exactly(1).accepts(2));
        assert!(CountRule::Any.accepts(u64::MAX));
    }
    #[test]
    fn debug_redacts_statements_and_all_parameter_bytes() {
        let value = Parameter::Text(Some("private-fixture".into()));
        let statement = Statement {
            sql: "private-sql".into(),
            parameters: vec![value.clone()],
            count: CountRule::Any,
        };
        assert_eq!(format!("{value:?}"), "Parameter(<redacted>)");
        assert_eq!(format!("{statement:?}"), "Statement(<redacted>)");
    }
}
