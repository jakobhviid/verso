//! Changing when photos were taken, for one photo or many: shifting each by an amount (years, months, days, hours,
//! minutes, seconds, earlier or later), or setting them all to one date. Immich's web app sets one date for all the
//! photos chosen; moving each by the same amount is what a camera with the wrong clock needs.
//!
//! Every photo keeps its own clock: its date is read and moved as it reads where it was taken (its local time, at its
//! own UTC offset), and written back at that offset, so a photo from Tokyo and one from Copenhagen both move by the
//! amount asked, as their clocks show it.

use chrono::{FixedOffset, Months, NaiveDateTime, TimeDelta, TimeZone};
use immich_api::{AssetChanges, Client};
use verso_linux::i18n::tr;

use crate::actions::offset_of;

/// How far to move a photo's date: whole calendar months (a year is twelve), then an exact length of time.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Shift {
    pub months: i32,
    pub seconds: i64,
}

/// The parts of a shift as a person gives them, each zero or more.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Amount {
    pub years: u32,
    pub months: u32,
    pub days: u32,
    pub hours: u32,
    pub minutes: u32,
    pub seconds: u32,
}

impl Shift {
    /// `amount` earlier or later.
    pub fn new(amount: Amount, earlier: bool) -> Shift {
        let sign = if earlier { -1 } else { 1 };
        let months = i64::from(amount.years) * 12 + i64::from(amount.months);
        let seconds = i64::from(amount.days) * 86_400 + i64::from(amount.hours) * 3_600 + i64::from(amount.minutes) * 60 + i64::from(amount.seconds);
        Shift { months: (months.min(i64::from(i32::MAX)) as i32) * sign, seconds: seconds * i64::from(sign) }
    }

    pub fn is_none(&self) -> bool {
        self.months == 0 && self.seconds == 0
    }

    /// `taken` moved: by calendar months first, the day of the month kept (or the month's last, where it has fewer
    /// days: January 31 and a month later is February's last), then by the exact time, days being 24 hours on the
    /// photo's own clock. `None` past the calendar's ends.
    pub fn apply(&self, taken: NaiveDateTime) -> Option<NaiveDateTime> {
        let by_months = if self.months >= 0 {
            taken.checked_add_months(Months::new(self.months.unsigned_abs()))
        } else {
            taken.checked_sub_months(Months::new(self.months.unsigned_abs()))
        }?;
        by_months.checked_add_signed(TimeDelta::try_seconds(self.seconds)?)
    }
}

/// What to do to each photo's date.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Change {
    Shift(Shift),
    /// This date and time, on each photo's own clock.
    Set(NaiveDateTime),
}

impl Change {
    /// The photo taken at `taken` (its local time) once changed.
    pub fn applied(&self, taken: NaiveDateTime) -> Option<NaiveDateTime> {
        match self {
            Change::Shift(shift) => shift.apply(taken),
            Change::Set(when) => Some(*when),
        }
    }
}

/// How changing several photos' dates went.
#[derive(Debug, Default)]
pub struct Outcome {
    pub changed: usize,
    /// The first failure's message, and how many failed.
    pub failed: Option<(String, usize)>,
}

/// Change when `ids` were taken, each read first for its own date and clock. A few at a time.
pub async fn change_taken(client: &Client, ids: Vec<String>, change: Change) -> Outcome {
    let permits = std::sync::Arc::new(tokio::sync::Semaphore::new(8));
    let mut tasks = tokio::task::JoinSet::new();
    for id in ids {
        let (client, permits) = (client.clone(), permits.clone());
        tasks.spawn(async move {
            let _permit = permits.acquire_owned().await.map_err(|error| error.to_string())?;
            change_one(&client, &id, change).await
        });
    }
    let mut outcome = Outcome::default();
    while let Some(done) = tasks.join_next().await {
        match done.map_err(|error| error.to_string()).and_then(|result| result) {
            Ok(()) => outcome.changed += 1,
            Err(message) => match &mut outcome.failed {
                Some((_, count)) => *count += 1,
                None => outcome.failed = Some((message, 1)),
            },
        }
    }
    outcome
}

async fn change_one(client: &Client, id: &str, change: Change) -> Result<(), String> {
    let details = client.asset_details(id).await.map_err(|error| error.to_string())?;
    let offset: FixedOffset = offset_of(&details);
    let taken = details.local_date_time.unwrap_or_else(|| details.file_created_at.with_timezone(&offset).naive_local());
    let changed = change.applied(taken).ok_or_else(|| tr("That date is beyond the calendar").to_owned())?;
    let moment = offset.from_local_datetime(&changed).single().ok_or_else(|| tr("That time does not exist on the photo's clock").to_owned())?;
    let changes = AssetChanges { date_time_original: Some(moment), ..AssetChanges::default() };
    client.update_asset(id, &changes).await.map(|_| ()).map_err(|error| error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::NaiveDate;

    fn at(year: i32, month: u32, day: u32, hour: u32, minute: u32, second: u32) -> NaiveDateTime {
        NaiveDate::from_ymd_opt(year, month, day).unwrap().and_hms_opt(hour, minute, second).unwrap()
    }

    #[test]
    fn every_part_of_a_shift_moves_the_date_by_its_amount() {
        let all = Amount { years: 1, months: 2, days: 3, hours: 4, minutes: 5, seconds: 6 };
        let later = Shift::new(all, false);
        assert_eq!(later, Shift { months: 14, seconds: 3 * 86_400 + 4 * 3_600 + 5 * 60 + 6 });
        assert_eq!(later.apply(at(2023, 5, 10, 8, 0, 0)), Some(at(2024, 7, 13, 12, 5, 6)));
        assert_eq!(Shift::new(all, true).apply(at(2024, 7, 13, 12, 5, 6)), Some(at(2023, 5, 10, 8, 0, 0)), "and back");
        let one = |amount: Amount| Shift::new(amount, false).apply(at(2024, 3, 15, 14, 32, 10));
        assert_eq!(one(Amount { years: 1, ..Amount::default() }), Some(at(2025, 3, 15, 14, 32, 10)));
        assert_eq!(one(Amount { months: 1, ..Amount::default() }), Some(at(2024, 4, 15, 14, 32, 10)));
        assert_eq!(one(Amount { days: 1, ..Amount::default() }), Some(at(2024, 3, 16, 14, 32, 10)));
        assert_eq!(one(Amount { hours: 1, ..Amount::default() }), Some(at(2024, 3, 15, 15, 32, 10)));
        assert_eq!(one(Amount { minutes: 1, ..Amount::default() }), Some(at(2024, 3, 15, 14, 33, 10)));
        assert_eq!(one(Amount { seconds: 1, ..Amount::default() }), Some(at(2024, 3, 15, 14, 32, 11)));
        assert!(Shift::new(Amount::default(), true).is_none());
    }

    #[test]
    fn hours_carry_into_days_and_months_into_years() {
        let shift = Shift::new(Amount { hours: 10, ..Amount::default() }, false);
        assert_eq!(shift.apply(at(2023, 12, 31, 20, 0, 0)), Some(at(2024, 1, 1, 6, 0, 0)));
        let shift = Shift::new(Amount { months: 13, ..Amount::default() }, true);
        assert_eq!(shift.apply(at(2024, 1, 10, 9, 0, 0)), Some(at(2022, 12, 10, 9, 0, 0)));
        let shift = Shift::new(Amount { seconds: 61, ..Amount::default() }, true);
        assert_eq!(shift.apply(at(2024, 1, 1, 0, 0, 30)), Some(at(2023, 12, 31, 23, 59, 29)));
    }

    #[test]
    fn a_month_on_from_a_long_month_lands_on_the_shorter_months_last_day() {
        let month = Shift::new(Amount { months: 1, ..Amount::default() }, false);
        assert_eq!(month.apply(at(2024, 1, 31, 10, 0, 0)), Some(at(2024, 2, 29, 10, 0, 0)));
        let year = Shift::new(Amount { years: 1, ..Amount::default() }, true);
        assert_eq!(year.apply(at(2024, 2, 29, 10, 0, 0)), Some(at(2023, 2, 28, 10, 0, 0)));
    }

    #[test]
    fn setting_gives_every_photo_the_same_date() {
        let when = at(2001, 9, 1, 12, 0, 0);
        assert_eq!(Change::Set(when).applied(at(1999, 1, 1, 0, 0, 0)), Some(when));
    }
}
