//! The date scroller beside a timeline's grid, worked out here for Linux's window, the Mac and the iPhone (through
//! `verso-bridge`): where each month falls on it, which years it labels, the month at a point on it, and the exact place
//! in the grid a point stands for, and back (ARCHITECTURE.md, "The date scroller").
//!
//! It is layout-true: each month takes the room the grid gives it, a header and the rows its photos fill, worked out
//! from the months' photo counts, so months not loaded yet take their true room. A point on the scroller is a fraction
//! of the grid's scrolling: 0 with the grid's top at the top of the view, 1 with its end at the bottom, so a drag down
//! the whole scroller goes through the whole grid and wherever the grid is, is a point on it. A grid that fits in view
//! spreads its months over the whole scroller.

use immich_api::timeline::YearMonth;

/// How the grid lays its months out.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Shape {
    /// How many photos a row holds.
    pub columns: u32,
    /// A row's height, with the space below it.
    pub row_height: f64,
    /// A month's header above its rows; none where months flow on (`flows`).
    pub header_height: f64,
    /// How much of the grid's height is in view at once.
    pub viewport: f64,
    /// The months flow on in the same rows, without headers, as Photos' library does on the iPhone; else each month
    /// starts a row of its own under its header, as on the Mac and Linux.
    pub flows: bool,
}

/// A place in the grid: a month, and how far into it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Place {
    /// The month, by its index in the grid's order.
    pub month: usize,
    /// The row of photos within the month, from its first; none in its header. Where months flow on, a month's rows
    /// are those that start with one of its photos.
    pub row: Option<u32>,
    /// How far into that row, or into the header, in points.
    pub offset: f64,
}

/// A year the scroller labels, at its first month; or Now, at the end with the newest photos, as Immich's scroller
/// ends.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct YearMark {
    pub year: i32,
    /// The year's first month, by its index in the grid's order; for Now, the newest month.
    pub month: usize,
    /// Where the year starts on the scroller.
    pub fraction: f64,
    /// The mark reads Now: the newest end, at the top where the newest photos come first, else at the foot.
    pub now: bool,
}

/// One month's room in the grid.
#[derive(Debug, Clone, Copy, PartialEq)]
struct Room {
    year: i32,
    /// Its top, in points down the grid.
    top: f64,
    /// Its header's height: none for a month without photos, or where months flow on.
    header: f64,
    rows: u32,
}

/// A timeline's date scroller, for one layout of its grid.
#[derive(Debug, Clone, PartialEq)]
pub struct Rail {
    months: Vec<Room>,
    /// The newest month comes first in the grid's order (the top), rather than last.
    newest_first: bool,
    row_height: f64,
    viewport: f64,
    /// The grid's height.
    height: f64,
}

/// Whether a section is a month of a timeline (its bucket, `2024-03-01T00:00:00.000Z`), which has a date for the
/// scroller; search results and the like have none.
pub fn is_month(bucket: &str) -> bool {
    YearMonth::parse(bucket).is_some()
}

impl Rail {
    /// The scroller for a timeline's months, in the grid's order, each with how many photos the grid shows of it.
    pub fn new(months: &[(YearMonth, u32)], shape: Shape) -> Rail {
        let columns = u64::from(shape.columns.max(1));
        let row_height = finite(shape.row_height);
        let header_height = if shape.flows { 0.0 } else { finite(shape.header_height) };
        let mut rooms = Vec::with_capacity(months.len());
        let mut top = 0.0;
        let mut photos_before: u64 = 0;
        for (month, count) in months {
            let count = u64::from(*count);
            let rows = if shape.flows {
                // The rows whose first photo is one of the month's.
                (photos_before + count).div_ceil(columns) - photos_before.div_ceil(columns)
            } else {
                count.div_ceil(columns)
            };
            let header = if count == 0 { 0.0 } else { header_height };
            let rows = u32::try_from(rows).unwrap_or(u32::MAX);
            rooms.push(Room { year: month.year, top, header, rows });
            top += header + f64::from(rows) * row_height;
            photos_before += count;
        }
        let newest_first = match (months.first(), months.last()) {
            (Some((first, _)), Some((last, _))) => (first.year, first.month) >= (last.year, last.month),
            _ => true,
        };
        Rail { months: rooms, newest_first, row_height, viewport: finite(shape.viewport), height: top }
    }

    /// How far the grid scrolls: its height less what is in view, or its whole height where it all fits in view.
    fn span(&self) -> f64 {
        if self.height > self.viewport {
            self.height - self.viewport
        } else {
            self.height
        }
    }

    /// The point on the scroller for the grid's top in view, `y` points down it.
    pub fn fraction_at(&self, y: f64) -> f64 {
        let span = self.span();
        if span > 0.0 && y.is_finite() {
            (y / span).clamp(0.0, 1.0)
        } else {
            0.0
        }
    }

    /// Where the grid's top in view goes for a point on the scroller, in points down the grid.
    pub fn y_at(&self, fraction: f64) -> f64 {
        if fraction.is_finite() {
            fraction.clamp(0.0, 1.0) * self.span()
        } else {
            0.0
        }
    }

    /// Each month's top, as a point on the scroller.
    pub fn tops(&self) -> Vec<f64> {
        self.months.iter().map(|month| self.fraction_at(month.top)).collect()
    }

    /// How many rows of photos a month has (see [`Place::row`]).
    pub fn rows(&self, month: usize) -> u32 {
        self.months.get(month).map_or(0, |room| room.rows)
    }

    /// The years to label, each where it begins, at its oldest month (its January, where the library has one): at the
    /// foot of the year's months where the newest photos come first, at their top where they come last. Now marks the
    /// end with the newest photos, as Immich's scroller ends, so the year of the newest photos keeps its own label where
    /// that year began, never read as now. Taken from Now outwards on a scroller `length` long: the newest photos' year
    /// is always labelled, just past Now where it began nearer to it than `spacing`, and an older year that would come
    /// nearer than `spacing` to the year before it is left out.
    pub fn year_marks(&self, length: f64, spacing: f64) -> Vec<YearMark> {
        let Some(newest) = (if self.newest_first { self.months.first() } else { self.months.last() }) else {
            return Vec::new();
        };
        let (now_month, now_fraction) = if self.newest_first { (0, 0.0) } else { (self.months.len() - 1, 1.0) };
        // Each year's oldest month, in the grid's order: the last of its months where the newest come first.
        let mut starts: Vec<(i32, usize)> = Vec::new();
        for (index, month) in self.months.iter().enumerate() {
            match starts.last_mut() {
                Some((year, start)) if *year == month.year => {
                    if self.newest_first {
                        *start = index;
                    }
                }
                _ => starts.push((month.year, index)),
            }
        }
        if !self.newest_first {
            starts.reverse();
        }
        let mut marks = vec![YearMark { year: newest.year, month: now_month, fraction: now_fraction, now: true }];
        // How far the last label kept stands from Now, in points.
        let mut reach = 0.0;
        for (year, index) in starts {
            let mut fraction = self.fraction_at(self.months[index].top);
            let mut distance = (fraction - now_fraction).abs() * length;
            if marks.len() == 1 {
                if distance < spacing {
                    let room = if length > 0.0 { (spacing / length).min(1.0) } else { 0.0 };
                    fraction = if self.newest_first { room } else { 1.0 - room };
                    distance = spacing;
                }
            } else if distance - reach < spacing {
                continue;
            }
            reach = distance;
            marks.push(YearMark { year, month: index, fraction, now: false });
        }
        if !self.newest_first {
            marks.reverse();
        }
        marks
    }

    /// The month at a point on the scroller: the last one that starts at or above it. A month that takes no room (one
    /// without photos, or, where months flow on, one whose photos all share a row with others) is never at a point.
    pub fn month_at(&self, fraction: f64) -> Option<usize> {
        self.month_at_y(self.y_at(fraction))
    }

    fn month_at_y(&self, y: f64) -> Option<usize> {
        if self.months.is_empty() {
            return None;
        }
        let after = self.months.partition_point(|month| month.top <= y);
        let has_room = |index: &usize| self.room(*index) > 0.0;
        (0..after).rev().find(has_room).or_else(|| (0..self.months.len()).find(has_room)).or(Some(0))
    }

    fn room(&self, index: usize) -> f64 {
        let month = &self.months[index];
        month.header + f64::from(month.rows) * self.row_height
    }

    /// The exact place in the grid a point on the scroller stands for: the month, and the row and how far into it.
    pub fn place_at(&self, fraction: f64) -> Option<Place> {
        let y = self.y_at(fraction);
        let index = self.month_at_y(y)?;
        let month = &self.months[index];
        let within = (y - month.top).max(0.0);
        if within < month.header || month.rows == 0 {
            return Some(Place { month: index, row: None, offset: within.min(month.header) });
        }
        let into_rows = within - month.header;
        let row = if self.row_height > 0.0 { ((into_rows / self.row_height).floor() as u32).min(month.rows - 1) } else { 0 };
        let offset = (into_rows - f64::from(row) * self.row_height).clamp(0.0, self.row_height);
        Some(Place { month: index, row: Some(row), offset })
    }

    /// Where a place is, in points down the grid. A month past the last is the grid's end.
    pub fn y_of(&self, place: Place) -> f64 {
        let Some(month) = self.months.get(place.month) else { return self.height };
        let within = match place.row {
            None => finite(place.offset).min(month.header),
            Some(row) => {
                let row = row.min(month.rows.saturating_sub(1));
                month.header + f64::from(row) * self.row_height + finite(place.offset).min(self.row_height)
            }
        };
        month.top + within
    }

    /// The point on the scroller for the grid's top in view at a place: where the scroller marks the grid.
    pub fn fraction_of(&self, place: Place) -> f64 {
        self.fraction_at(self.y_of(place))
    }
}

/// A length given from outside, never negative or not a number.
fn finite(length: f64) -> f64 {
    if length.is_finite() {
        length.max(0.0)
    } else {
        0.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn month(year: i32, month: u32) -> YearMonth {
        YearMonth::new(year, month).unwrap()
    }

    /// Four columns, rows of 10, headers of 20, none of it in view.
    fn shape(viewport: f64) -> Shape {
        Shape { columns: 4, row_height: 10.0, header_height: 20.0, viewport, flows: false }
    }

    /// Eight, four, two and six photos: 40, 30, 30 and 40 points of 140.
    fn months() -> Vec<(YearMonth, u32)> {
        vec![(month(2024, 3), 8), (month(2024, 1), 4), (month(2023, 12), 2), (month(2021, 6), 6)]
    }

    fn close(first: f64, second: f64) -> bool {
        (first - second).abs() < 1e-9
    }

    #[test]
    fn only_a_timelines_months_have_dates() {
        assert!(is_month("2024-03-01T00:00:00.000Z"));
        assert!(is_month("2024-03-01"));
        assert!(!is_month("results"));
        assert!(!is_month("2024"));
    }

    #[test]
    fn each_month_takes_its_header_and_its_rows() {
        let rail = Rail::new(&months(), shape(0.0));
        assert_eq!(rail.tops(), [0.0, 40.0 / 140.0, 70.0 / 140.0, 100.0 / 140.0]);
        assert_eq!((0..4).map(|index| rail.rows(index)).collect::<Vec<_>>(), [2, 1, 1, 2]);
        assert!(Rail::new(&[], shape(0.0)).tops().is_empty());
        let none = Rail::new(&[(month(2024, 1), 0)], Shape { columns: 0, row_height: 10.0, header_height: 0.0, viewport: 0.0, flows: false });
        assert_eq!(none.tops(), [0.0]);
        assert_eq!(none.month_at(0.5), Some(0));
    }

    #[test]
    fn with_one_photo_a_row_and_no_headers_months_take_room_by_their_photos() {
        // As Linux's scrubber placed them, before months took the grid's room.
        let one_a_row = Shape { columns: 1, row_height: 1.0, header_height: 0.0, viewport: 0.0, flows: false };
        let rail = Rail::new(&[(month(2024, 3), 10), (month(2024, 2), 30), (month(2024, 1), 1)], one_a_row);
        assert_eq!(rail.tops(), [0.0, 10.0 / 41.0, 40.0 / 41.0]);
        assert_eq!(rail.month_at(0.0), Some(0));
        assert_eq!(rail.month_at(0.3), Some(1));
        assert_eq!(rail.month_at(0.99), Some(2));
    }

    #[test]
    fn the_scroller_runs_from_the_grids_top_in_view_to_its_end_in_view() {
        // 40 of the 140 points in view: the grid scrolls 100.
        let rail = Rail::new(&months(), shape(40.0));
        assert_eq!(rail.tops(), [0.0, 0.4, 0.7, 1.0]);
        assert!(close(rail.y_at(1.0), 100.0));
        assert!(close(rail.fraction_at(50.0), 0.5));
        assert_eq!(rail.fraction_at(-5.0), 0.0);
        assert_eq!(rail.fraction_at(500.0), 1.0);
        assert_eq!(rail.y_at(f64::NAN), 0.0);
        // A grid that fits in view spreads its months over the whole scroller.
        assert_eq!(Rail::new(&months(), shape(400.0)).tops(), Rail::new(&months(), shape(0.0)).tops());
    }

    /// The marks as they read: a year, or Now.
    fn labels(marks: &[YearMark]) -> Vec<String> {
        marks.iter().map(|mark| if mark.now { "Now".to_owned() } else { mark.year.to_string() }).collect()
    }

    #[test]
    fn a_year_is_labelled_at_its_first_month_unless_too_near_the_one_above() {
        let rail = Rail::new(&months(), shape(0.0));
        let tall = rail.year_marks(1400.0, 18.0);
        // The newest photos first: Now at the top, and each year where it began, at its oldest month (2024 at its
        // January, below its March), so the newest photos' year keeps its label and is never read as now.
        assert_eq!(labels(&tall), ["Now", "2024", "2023", "2021"]);
        assert_eq!(tall.iter().map(|mark| mark.month).collect::<Vec<_>>(), [0, 1, 2, 3]);
        assert!(close(tall[0].fraction, 0.0));
        assert!(close(tall[2].fraction, 0.5));
        let short = rail.year_marks(50.0, 18.0);
        // On a short scroller the newest photos' year keeps its label, just past Now (it began 14 points from it), and
        // the older years too near it give way.
        assert_eq!(labels(&short), ["Now", "2024"]);
        assert!(close(short[1].fraction, 18.0 / 50.0) && short[1].month == 1);
        assert!(Rail::new(&[], shape(0.0)).year_marks(100.0, 10.0).is_empty());
    }

    #[test]
    fn now_is_at_the_foot_where_the_newest_photos_come_last() {
        let oldest_first: Vec<(YearMonth, u32)> = months().into_iter().rev().collect();
        let rail = Rail::new(&oldest_first, shape(0.0));
        let tall = rail.year_marks(1400.0, 18.0);
        assert_eq!(labels(&tall), ["2021", "2023", "2024", "Now"]);
        let last = tall.last().unwrap();
        assert!(last.now && close(last.fraction, 1.0) && last.month == oldest_first.len() - 1);
        // On a short scroller, the newest photos' year keeps its label and the years too near it give way.
        let short = rail.year_marks(50.0, 18.0);
        assert_eq!(labels(&short), ["2021", "2024", "Now"]);
        assert!(short.windows(2).all(|pair| (pair[1].fraction - pair[0].fraction) * 50.0 >= 18.0));
        // Shorter still, the newest photos' year, which began 15 points above Now, goes just above it.
        let shorter = rail.year_marks(30.0, 18.0);
        assert_eq!(labels(&shorter), ["2024", "Now"]);
        assert!(close(shorter[0].fraction, 1.0 - 18.0 / 30.0) && shorter[0].month == 2);
    }

    #[test]
    fn a_point_stands_for_the_month_that_starts_at_or_above_it() {
        let rail = Rail::new(&months(), shape(0.0));
        assert_eq!(rail.month_at(0.0), Some(0));
        assert_eq!(rail.month_at(0.3), Some(1));
        assert_eq!(rail.month_at(0.99), Some(3));
        assert_eq!(rail.month_at(-1.0), Some(0));
        assert_eq!(Rail::new(&[], shape(0.0)).month_at(0.5), None);
    }

    #[test]
    fn a_point_stands_for_an_exact_place_never_a_months_start() {
        let rail = Rail::new(&months(), shape(0.0));
        // 10 points down: the first month's header, half way.
        assert_eq!(rail.place_at(10.0 / 140.0), Some(Place { month: 0, row: None, offset: 10.0 }));
        // 33 points: its second row, 3 points in.
        let place = rail.place_at(33.0 / 140.0).unwrap();
        assert_eq!((place.month, place.row), (0, Some(1)));
        assert!(close(place.offset, 3.0));
        // 65 points: the second month's only row, 5 points in.
        let place = rail.place_at(65.0 / 140.0).unwrap();
        assert_eq!((place.month, place.row), (1, Some(0)));
        assert!(close(place.offset, 5.0));
        // The end: the last row of the last month, at its foot.
        let end = rail.place_at(1.0).unwrap();
        assert_eq!((end.month, end.row), (3, Some(1)));
        assert!(close(end.offset, 10.0));
        // A drag through a month goes on through its rows.
        let rows: Vec<Option<u32>> = (100..140).step_by(5).map(|y| rail.place_at(f64::from(y) / 140.0).unwrap().row).collect();
        assert_eq!(rows, [None, None, None, None, Some(0), Some(0), Some(1), Some(1)]);
    }

    #[test]
    fn a_place_goes_back_to_its_point() {
        let rail = Rail::new(&months(), shape(40.0));
        for step in 0..=100 {
            let fraction = f64::from(step) / 100.0;
            let place = rail.place_at(fraction).unwrap();
            assert!(close(rail.fraction_of(place), fraction), "{fraction}: {place:?}");
        }
        assert!(close(rail.y_of(Place { month: 2, row: Some(0), offset: 0.0 }), 90.0));
        assert!(close(rail.y_of(Place { month: 1, row: Some(7), offset: 99.0 }), 70.0), "kept within the month");
        assert_eq!(rail.y_of(Place { month: 9, row: None, offset: 0.0 }), 140.0);
        assert_eq!(rail.fraction_of(Place { month: 9, row: None, offset: 0.0 }), 1.0);
    }

    #[test]
    fn where_months_flow_on_a_row_belongs_to_the_month_of_its_first_photo() {
        // Six, one and five photos, four a row: rows 0 and 1 start with the first month's, row 2 with the third's; the
        // second month's one photo shares row 1 and takes no room of its own.
        let flowing = Shape { columns: 4, row_height: 10.0, header_height: 20.0, viewport: 0.0, flows: true };
        let rail = Rail::new(&[(month(2024, 3), 6), (month(2024, 2), 1), (month(2023, 1), 5)], flowing);
        assert_eq!(rail.tops(), [0.0, 20.0 / 30.0, 20.0 / 30.0]);
        assert_eq!((0..3).map(|index| rail.rows(index)).collect::<Vec<_>>(), [2, 0, 1]);
        assert_eq!(rail.month_at(15.0 / 30.0), Some(0));
        assert_eq!(rail.month_at(0.7), Some(2));
        let place = rail.place_at(15.0 / 30.0).unwrap();
        assert_eq!((place.month, place.row), (0, Some(1)));
        assert!(close(place.offset, 5.0));
        assert!(close(rail.fraction_of(place), 0.5));
        let marks = rail.year_marks(300.0, 10.0);
        assert_eq!(labels(&marks), ["Now", "2024"]);
        assert_eq!(marks.iter().map(|mark| mark.month).collect::<Vec<_>>(), [0, 1]);
    }
}
