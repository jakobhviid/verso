//! The date scroller beside a timeline's grid, worked out in the core for the Mac and the iPhone as for Linux's window
//! (`verso_core::rail`; ARCHITECTURE.md, "The date scroller"). The Swift side names the grid's months by their bucket
//! (`2025-03-01`), as its grid does, and gets back places by the months' indexes in the order it gave them.

use std::sync::Arc;

use immich_api::timeline::YearMonth;
use verso_core::rail::{self, Place, Rail, Shape};

/// A month of the grid, as it shows it: its bucket, and how many photos the grid shows of it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RailMonth {
    pub bucket: String,
    pub count: u32,
}

/// How the grid lays its months out (`verso_core::rail::Shape`).
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct RailShape {
    /// How many photos a row holds.
    pub columns: u32,
    /// A row's height, with the space below it.
    pub row_height: f64,
    /// A month's header above its rows; none where months flow on.
    pub header_height: f64,
    /// How much of the grid's height is in view at once.
    pub viewport: f64,
    /// The months flow on in the same rows, without headers (the iPhone); else each starts a row under its header.
    pub flows: bool,
}

/// A place in the grid: a month, by its index, and how far into it.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct RailPlace {
    pub month: u32,
    /// The row of photos within the month, from its first; none in its header.
    pub row: Option<u32>,
    /// How far into that row, or into the header, in points.
    pub offset: f64,
}

/// A year the scroller labels, at its first month.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct RailYear {
    pub year: i32,
    /// The year's first month, by its index; for Now, the newest month.
    pub month: u32,
    /// Where the year starts on the scroller, from 0 at its top to 1 at its foot.
    pub fraction: f64,
    /// The mark reads Now, at the end with the newest photos, rather than its year.
    pub now: bool,
}

/// A timeline's date scroller, for one layout of its grid. A point on it is a fraction of the grid's scrolling: 0 with
/// the grid's top in view, 1 with its end.
#[derive(uniffi::Object)]
pub struct DateRail {
    rail: Rail,
}

/// Whether every section is a month of a timeline, which has a date for the scroller; search results and the like have
/// none.
#[uniffi::export]
pub fn months_are_dated(buckets: Vec<String>) -> bool {
    buckets.iter().all(|bucket| rail::is_month(bucket))
}

/// The scroller for the grid's months, in its order; none when a section is not a month (search results and the like).
#[uniffi::export]
pub fn date_rail(months: Vec<RailMonth>, shape: RailShape) -> Option<Arc<DateRail>> {
    let months: Vec<(YearMonth, u32)> =
        months.iter().map(|month| YearMonth::parse(&month.bucket).map(|parsed| (parsed, month.count))).collect::<Option<_>>()?;
    let shape = Shape {
        columns: shape.columns,
        row_height: shape.row_height,
        header_height: shape.header_height,
        viewport: shape.viewport,
        flows: shape.flows,
    };
    Some(Arc::new(DateRail { rail: Rail::new(&months, shape) }))
}

fn index(month: usize) -> u32 {
    u32::try_from(month).unwrap_or(u32::MAX)
}

#[uniffi::export]
impl DateRail {
    /// Each month's top, as a point on the scroller.
    pub fn tops(&self) -> Vec<f64> {
        self.rail.tops()
    }

    /// The years to label, each at its first month, leaving out one that would come nearer than `spacing` to the one
    /// labelled before it on a scroller `length` long.
    pub fn year_marks(&self, length: f64, spacing: f64) -> Vec<RailYear> {
        self.rail
            .year_marks(length, spacing)
            .into_iter()
            .map(|mark| RailYear { year: mark.year, month: index(mark.month), fraction: mark.fraction, now: mark.now })
            .collect()
    }

    /// The month at a point on the scroller.
    pub fn month_at(&self, fraction: f64) -> Option<u32> {
        self.rail.month_at(fraction).map(index)
    }

    /// The exact place in the grid a point on the scroller stands for.
    pub fn place_at(&self, fraction: f64) -> Option<RailPlace> {
        self.rail.place_at(fraction).map(|place| RailPlace { month: index(place.month), row: place.row, offset: place.offset })
    }

    /// The point on the scroller for the grid's top in view at a place: where the scroller marks the grid.
    pub fn fraction_of(&self, place: RailPlace) -> f64 {
        self.rail.fraction_of(Place { month: place.month as usize, row: place.row, offset: place.offset })
    }

    /// Where the grid's top in view goes for a point on the scroller, in points down the grid.
    pub fn y_at(&self, fraction: f64) -> f64 {
        self.rail.y_at(fraction)
    }

    /// The point on the scroller for the grid's top in view, `y` points down it.
    pub fn fraction_at(&self, y: f64) -> f64 {
        self.rail.fraction_at(y)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn month(bucket: &str, count: u32) -> RailMonth {
        RailMonth { bucket: bucket.to_owned(), count }
    }

    /// The Mac's grid in small: four columns, rows of 10, headers of 20, 40 points in view of 140.
    fn shape() -> RailShape {
        RailShape { columns: 4, row_height: 10.0, header_height: 20.0, viewport: 40.0, flows: false }
    }

    fn months() -> Vec<RailMonth> {
        vec![
            month("2024-03-01T00:00:00.000Z", 8),
            month("2024-01-01T00:00:00.000Z", 4),
            month("2023-12-01", 2),
            month("2021-06-01T00:00:00.000Z", 6),
        ]
    }

    #[test]
    fn only_a_timelines_months_get_a_scroller() {
        assert!(months_are_dated(months().into_iter().map(|month| month.bucket).collect()));
        assert!(!months_are_dated(vec!["2024-03-01".to_owned(), "results".to_owned()]));
        assert!(date_rail(vec![month("2024-03-01", 2), month("results", 3)], shape()).is_none());
        assert!(date_rail(Vec::new(), shape()).is_some_and(|rail| rail.tops().is_empty()));
    }

    #[test]
    fn months_take_their_rows_and_years_are_labelled_where_they_begin() {
        let rail = date_rail(months(), shape()).unwrap();
        assert_eq!(rail.tops(), [0.0, 0.4, 0.7, 1.0]);
        let years = rail.year_marks(1000.0, 18.0);
        assert_eq!(
            years.iter().map(|year| (year.year, year.month, year.now)).collect::<Vec<_>>(),
            [(2024, 0, true), (2024, 1, false), (2023, 2, false), (2021, 3, false)]
        );
        assert_eq!(rail.month_at(0.5), Some(1));
        assert_eq!(rail.month_at(-1.0), Some(0));
    }

    #[test]
    fn a_point_is_an_exact_place_and_back() {
        let rail = date_rail(months(), shape()).unwrap();
        // 33 points down: the first month's second row, 3 points in.
        let place = rail.place_at(0.33).unwrap();
        assert_eq!((place.month, place.row), (0, Some(1)));
        assert!((place.offset - 3.0).abs() < 1e-9);
        assert!((rail.fraction_of(place) - 0.33).abs() < 1e-9);
        assert_eq!(rail.place_at(0.1), Some(RailPlace { month: 0, row: None, offset: 10.0 }));
        assert!((rail.y_at(0.5) - 50.0).abs() < 1e-9);
        assert!((rail.fraction_at(70.0) - 0.7).abs() < 1e-9);
        assert_eq!(rail.fraction_of(RailPlace { month: 2, row: None, offset: 0.0 }), 0.7);
    }
}
