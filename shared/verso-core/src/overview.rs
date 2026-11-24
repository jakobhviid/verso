//! The Library's Years and Months, as in Photos (after Immich Gallery's `LibraryOverviewArrangement`): a card for each
//! year, showing a photo from its fullest month, and for each month a few photos from different days of it. Linux's
//! window, the Mac and the iPhone (through `verso-bridge`) all arrange them here.

use chrono::{Datelike, NaiveDateTime};
use immich_api::timeline::YearMonth;

/// A year of the timeline.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Year {
    pub year: i32,
    /// Its months, in the grid's order.
    pub months: Vec<YearMonth>,
    /// The month its card shows a photo from: its fullest (the first of them on a tie).
    pub key_month: YearMonth,
}

/// A photo of a month, as the mosaic picks from it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Photo {
    pub id: String,
    /// When it was taken, on the clock where it was taken; none when Immich gave no date.
    pub taken: Option<NaiveDateTime>,
    pub is_video: bool,
}

/// A photo picked for a month's mosaic, and the day of the month it shows (none for a photo without a date).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pick {
    pub id: String,
    pub day: Option<u32>,
}

/// The years of a timeline's months (with their counts), in the order each year first comes in the grid.
pub fn years(months: &[(YearMonth, u32)]) -> Vec<Year> {
    let mut years: Vec<(Year, u32)> = Vec::new();
    for (month, count) in months {
        match years.iter_mut().find(|(year, _)| year.year == month.year) {
            Some((year, most)) => {
                year.months.push(*month);
                if *count > *most {
                    year.key_month = *month;
                    *most = *count;
                }
            }
            None => years.push((Year { year: month.year, months: vec![*month], key_month: *month }, *count)),
        }
    }
    years.into_iter().map(|(year, _)| year).collect()
}

/// A month's mosaic: one photo from each of up to `limit` days, spread over the month (the first and last day
/// included), in the grid's order. Within a day, the photo in the middle, and a still before a video. Photos without a
/// date count as a day of their own.
pub fn picks(photos: &[Photo], limit: usize) -> Vec<Pick> {
    if limit == 0 {
        return Vec::new();
    }
    let mut days: Vec<(Option<u32>, Vec<&Photo>)> = Vec::new();
    for photo in photos {
        let day = photo.taken.map(|taken| taken.day());
        match days.iter_mut().find(|(known, _)| *known == day) {
            Some((_, photos)) => photos.push(photo),
            None => days.push((day, vec![photo])),
        }
    }
    let chosen: Vec<usize> = if days.len() <= limit { (0..days.len()).collect() } else { (0..limit).map(|index| index * (days.len() - 1) / (limit - 1).max(1)).collect() };
    chosen
        .into_iter()
        .map(|index| {
            let (day, photos) = &days[index];
            let stills: Vec<&&Photo> = photos.iter().filter(|photo| !photo.is_video).collect();
            let pool: Vec<&&Photo> = if stills.is_empty() { photos.iter().collect() } else { stills };
            Pick { id: pool[pool.len() / 2].id.clone(), day: *day }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::NaiveDate;

    fn month(year: i32, month: u32) -> YearMonth {
        YearMonth::new(year, month).unwrap()
    }

    fn photo(id: &str, day: u32, hour: u32, is_video: bool) -> Photo {
        Photo { id: id.to_owned(), taken: Some(NaiveDate::from_ymd_opt(2024, 3, day).unwrap().and_hms_opt(hour, 0, 0).unwrap()), is_video }
    }

    fn pick(id: &str, day: u32) -> Pick {
        Pick { id: id.to_owned(), day: Some(day) }
    }

    #[test]
    fn years_keep_the_grids_order_and_show_their_fullest_month() {
        let years = years(&[(month(2024, 3), 5), (month(2024, 1), 9), (month(2023, 12), 2), (month(2023, 11), 2)]);
        assert_eq!(years.iter().map(|year| year.year).collect::<Vec<_>>(), [2024, 2023]);
        assert_eq!(years[0].months, [month(2024, 3), month(2024, 1)]);
        assert_eq!(years[0].key_month, month(2024, 1));
        assert_eq!(years[1].key_month, month(2023, 12), "on a tie, the first");
        assert!(super::years(&[]).is_empty());
    }

    #[test]
    fn oldest_first_reads_the_same_way() {
        let years = years(&[(month(2023, 11), 2), (month(2023, 12), 2), (month(2024, 1), 9), (month(2024, 3), 5)]);
        assert_eq!(years.iter().map(|year| year.year).collect::<Vec<_>>(), [2023, 2024]);
        assert_eq!(years[0].key_month, month(2023, 11), "on a tie, the first");
        assert_eq!(years[1].months, [month(2024, 1), month(2024, 3)]);
        assert_eq!(years[1].key_month, month(2024, 1));
    }

    #[test]
    fn a_month_shows_one_photo_a_day_the_middle_one_and_a_still_before_a_video() {
        let photos = [photo("a", 20, 20, false), photo("b", 20, 10, false), photo("c", 20, 8, false), photo("v", 9, 12, true), photo("d", 9, 12, false), photo("w", 3, 12, true)];
        assert_eq!(picks(&photos, 4), [pick("b", 20), pick("d", 9), pick("w", 3)]);
    }

    #[test]
    fn more_days_than_tiles_spread_over_the_month() {
        let many: Vec<Photo> = (1..=10).rev().map(|day| photo(&format!("p{day}"), day, 12, false)).collect();
        let days = |limit: usize| picks(&many, limit).into_iter().map(|pick| pick.day).collect::<Vec<_>>();
        assert_eq!(days(4), [Some(10), Some(7), Some(4), Some(1)]);
        assert_eq!(days(1), [Some(10)]);
        assert!(days(0).is_empty());
        assert!(picks(&[], 4).is_empty());
    }

    #[test]
    fn photos_without_a_date_still_show() {
        let undated = Photo { id: "x".to_owned(), taken: None, is_video: false };
        assert_eq!(picks(std::slice::from_ref(&undated), 4), [Pick { id: "x".to_owned(), day: None }]);
        let mixed = [photo("a", 5, 12, false), undated.clone(), Photo { id: "y".to_owned(), taken: None, is_video: false }];
        assert_eq!(picks(&mixed, 4), [pick("a", 5), Pick { id: "y".to_owned(), day: None }], "the undated are a day of their own");
    }
}
