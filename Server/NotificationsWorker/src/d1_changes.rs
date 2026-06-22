pub(crate) fn changed_exactly_one_row(changes: Option<usize>) -> bool {
    changes == Some(1)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn d1_update_result_requires_exactly_one_changed_row() {
        assert!(changed_exactly_one_row(Some(1)));
        assert!(!changed_exactly_one_row(Some(0)));
        assert!(!changed_exactly_one_row(Some(2)));
        assert!(!changed_exactly_one_row(None));
    }
}
