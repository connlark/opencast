//! UTC calendar arithmetic on Unix milliseconds. Every counter that rolls
//! over (month ceiling, daily backstop, hourly failure buckets) keys on these.

pub const MS_PER_SECOND: i64 = 1_000;
pub const MS_PER_HOUR: i64 = 3_600_000;
pub const MS_PER_DAY: i64 = 86_400_000;

/// Milliseconds since 1970 for a canonical UTC timestamp
/// `YYYY-MM-DDTHH:MM:SSZ` (a real calendar date), else `None`. The same
/// rule the policy bundle generator applies to `trial.starts_at`.
pub fn parse_utc_timestamp_ms(value: &str) -> Option<i64> {
    let bytes = value.as_bytes();
    if !value.is_ascii()
        || bytes.len() != 20
        || bytes[4] != b'-'
        || bytes[7] != b'-'
        || bytes[10] != b'T'
        || bytes[13] != b':'
        || bytes[16] != b':'
        || bytes[19] != b'Z'
    {
        return None;
    }
    let number = |range: std::ops::Range<usize>| -> Option<i64> {
        let digits = &value[range];
        if !digits.bytes().all(|byte| byte.is_ascii_digit()) {
            return None;
        }
        digits.parse().ok()
    };
    let (year, month, day) = (number(0..4)?, number(5..7)?, number(8..10)?);
    let (hour, minute, second) = (number(11..13)?, number(14..16)?, number(17..19)?);
    if !(1..=12).contains(&month)
        || day < 1
        || day > days_in_month(year, month)
        || hour > 23
        || minute > 59
        || second > 59
    {
        return None;
    }
    let days = days_from_civil(year, month, day);
    Some(((days * 24 + hour) * 60 + minute) * 60_000 + second * MS_PER_SECOND)
}

/// The UTC day index (days since 1970-01-01) of an instant.
pub fn day_index(now_ms: i64) -> i64 {
    now_ms.div_euclid(MS_PER_DAY)
}

/// The UTC hour index (hours since 1970-01-01T00) of an instant.
pub fn hour_index(now_ms: i64) -> i64 {
    now_ms.div_euclid(MS_PER_HOUR)
}

/// The UTC month of an instant as `YYYY-MM`.
pub fn month_key(now_ms: i64) -> String {
    let (year, month, _) = civil_from_days(day_index(now_ms));
    format!("{year:04}-{month:02}")
}

/// The UTC calendar date of a day index as `YYYY-MM-DD`.
pub fn date_key(day: i64) -> String {
    let (year, month, day) = civil_from_days(day);
    format!("{year:04}-{month:02}-{day:02}")
}

fn is_leap(year: i64) -> bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

fn days_in_month(year: i64, month: i64) -> i64 {
    match month {
        2 if is_leap(year) => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}

// Howard Hinnant's civil-date algorithms (public domain).
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let year_of_era = year - era * 400;
    let month_index = (month + 9) % 12;
    let day_of_year = (153 * month_index + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let days = days + 719_468;
    let era = days.div_euclid(146_097);
    let day_of_era = days - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_index + 2) / 5 + 1;
    let month = if month_index < 10 {
        month_index + 3
    } else {
        month_index - 9
    };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canonical_timestamps_parse_to_unix_milliseconds() {
        assert_eq!(parse_utc_timestamp_ms("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(
            parse_utc_timestamp_ms("2027-01-01T00:00:00Z"),
            Some(1_798_761_600_000)
        );
        assert_eq!(
            parse_utc_timestamp_ms("2028-02-29T23:59:59Z"),
            Some(1_835_481_599_000)
        );
        for invalid in [
            "2027-02-29T00:00:00Z",
            "2027-13-01T00:00:00Z",
            "2027-01-01T24:00:00Z",
            "2027-01-01 00:00:00Z",
            "2027-01-01T00:00:00+00:00",
            "２０２７-01-01T00:00:00Z",
            "",
        ] {
            assert_eq!(parse_utc_timestamp_ms(invalid), None, "{invalid}");
        }
    }

    #[test]
    fn month_and_day_keys_roll_over_at_utc_midnight() {
        let flip = parse_utc_timestamp_ms("2027-01-01T00:00:00Z").unwrap();
        assert_eq!(month_key(flip - 1), "2026-12");
        assert_eq!(month_key(flip), "2027-01");
        assert_eq!(day_index(flip) - day_index(flip - 1), 1);
        assert_eq!(date_key(day_index(flip)), "2027-01-01");
        assert_eq!(date_key(day_index(flip - 1)), "2026-12-31");
        assert_eq!(hour_index(flip) - hour_index(flip - 1), 1);
    }
}
