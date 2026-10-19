//! Pure authority selection, shared by runtime construction and host tests.
//! The authority is always explicit: an absent `STORAGE_AUTHORITY` is refused,
//! never defaulted, and `postgres` is the only value that selects storage.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Backend {
    Postgres,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ConfigurationError {
    MissingAuthority,
    InvalidAuthority,
}
impl ConfigurationError {
    pub(crate) fn code(self) -> &'static str {
        match self {
            Self::MissingAuthority => "storage_authority_missing",
            Self::InvalidAuthority => "invalid_storage_authority",
        }
    }
}
pub(crate) fn select(value: Option<&str>) -> Result<Backend, ConfigurationError> {
    match value {
        None => Err(ConfigurationError::MissingAuthority),
        Some("postgres") => Ok(Backend::Postgres),
        Some(_) => Err(ConfigurationError::InvalidAuthority),
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn an_absent_authority_is_refused_without_a_default() {
        assert_eq!(select(None), Err(ConfigurationError::MissingAuthority));
        assert_eq!(
            ConfigurationError::MissingAuthority.code(),
            "storage_authority_missing"
        );
    }
    #[test]
    fn postgres_selects_the_postgres_backend() {
        assert_eq!(select(Some("postgres")), Ok(Backend::Postgres));
    }
    #[test]
    fn d1_unknown_empty_or_misspelled_values_never_fall_back() {
        for value in ["d1", "D1", "", "POSTGRES", "postgres ", " d1", "garbage"] {
            assert_eq!(
                select(Some(value)),
                Err(ConfigurationError::InvalidAuthority)
            );
        }
        assert_eq!(
            ConfigurationError::InvalidAuthority.code(),
            "invalid_storage_authority"
        );
    }
}
