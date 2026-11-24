//! How the gallery writes dates, lengths and sizes. English for now; the words go through `tr` where the catalog
//! will take them.

use chrono::{DateTime, Datelike, Local, NaiveDate, NaiveDateTime, Utc};
use immich_api::timeline::YearMonth;
use verso_linux::i18n::tr;

const MONTHS: [&str; 12] = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

pub fn month_name(month: u32) -> &'static str {
    MONTHS.get(month.saturating_sub(1) as usize).map_or("", |name| tr(name))
}

/// A section's heading: "March 2024".
pub fn month_title(month: YearMonth) -> String {
    format!("{} {}", month_name(month.month), month.year)
}

/// A day: "Sunday, 17 November 2018".
pub fn day(date: NaiveDate) -> String {
    format!("{}, {} {} {}", tr(&date.format("%A").to_string()), date.day(), month_name(date.month()), date.year())
}

/// A day, short, for tables: "17 Nov 2018".
pub fn short_day(date: NaiveDate) -> String {
    let month = month_name(date.month());
    format!("{} {} {}", date.day(), month.chars().take(3).collect::<String>(), date.year())
}

/// When a photo was taken: "17 November 2018 at 13:04".
pub fn taken(moment: NaiveDateTime) -> String {
    format!("{} {} {} {}", moment.day(), month_name(moment.month()), moment.year(), moment.format("%H:%M"))
}

/// When something happened, from `now`: "Just now", "5 minutes ago", "2 hours ago", "Yesterday", "3 days ago", then
/// the day.
pub fn ago(then: DateTime<Utc>, now: DateTime<Utc>) -> String {
    let minutes = (now - then).num_minutes().max(0);
    let (hours, days) = (minutes / 60, minutes / (60 * 24));
    if minutes < 1 {
        tr("Just now").to_owned()
    } else if minutes == 1 {
        tr("1 minute ago").to_owned()
    } else if hours < 1 {
        tr("{count} minutes ago").replace("{count}", &minutes.to_string())
    } else if hours == 1 {
        tr("1 hour ago").to_owned()
    } else if days < 1 {
        tr("{count} hours ago").replace("{count}", &hours.to_string())
    } else if days == 1 {
        tr("Yesterday").to_owned()
    } else if days < 7 {
        tr("{count} days ago").replace("{count}", &days.to_string())
    } else {
        short_day(then.with_timezone(&Local).date_naive())
    }
}

/// A video's length: "0:07", "12:30", "1:02:03".
pub fn duration(milliseconds: u64) -> String {
    let seconds = (milliseconds + 500) / 1000;
    let (hours, minutes, seconds) = (seconds / 3600, (seconds / 60) % 60, seconds % 60);
    if hours > 0 {
        format!("{hours}:{minutes:02}:{seconds:02}")
    } else {
        format!("{minutes}:{seconds:02}")
    }
}

/// A file's size in decimal units, as Files writes them.
pub fn size(bytes: u64) -> String {
    crate::preferences::format_size(bytes)
}

/// "1 photo", "12 photos": a count of items.
pub fn items(count: u64) -> String {
    if count == 1 {
        tr("1 item").to_owned()
    } else {
        tr("{count} items").replace("{count}", &count.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lengths_read_as_players_show_them() {
        assert_eq!(duration(7_400), "0:07");
        assert_eq!(duration(750_000), "12:30");
        assert_eq!(duration(3_723_000), "1:02:03");
    }

    #[test]
    fn times_read_from_now() {
        let now = Utc::now();
        let ago = |minutes: i64| super::ago(now - chrono::Duration::minutes(minutes), now);
        assert_eq!([ago(0), ago(1), ago(5), ago(60), ago(150), ago(60 * 30), ago(60 * 24 * 3)], ["Just now", "1 minute ago", "5 minutes ago", "1 hour ago", "2 hours ago", "Yesterday", "3 days ago"]);
    }

    #[test]
    fn months_and_days_are_written_out() {
        assert_eq!(month_title(YearMonth::new(2024, 3).unwrap()), "March 2024");
        assert_eq!(day(NaiveDate::from_ymd_opt(2018, 11, 17).unwrap()), "Saturday, 17 November 2018");
    }
}
