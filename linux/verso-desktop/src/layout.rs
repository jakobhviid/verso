//! The grid's rows: photos laid out at their own shape in rows of one height, as Photos and Immich's web app do, or
//! as squares (ARCHITECTURE.md, "Verso's window"). Pure arithmetic, so both desktops lay out alike.

/// One row of tiles: where it starts in the list, and each tile's size in pixels. The widths of a full row add up to
/// the width given, spacing included.
#[derive(Debug, Clone, PartialEq)]
pub struct Row {
    pub start: usize,
    pub height: u32,
    pub widths: Vec<u32>,
}

impl Row {
    pub fn len(&self) -> usize {
        self.widths.len()
    }

    pub fn is_empty(&self) -> bool {
        self.widths.is_empty()
    }
}

/// Very wide or tall photos are shown cut to these shapes, so a panorama never makes a row a sliver.
const NARROWEST: f64 = 0.5;
const WIDEST: f64 = 3.0;

fn clamped(ratio: f64) -> f64 {
    if ratio.is_finite() && ratio > 0.0 {
        ratio.clamp(NARROWEST, WIDEST)
    } else {
        1.0
    }
}

/// Lay out `ratios` (width over height) in rows `width` pixels wide, each near `target_height`, with `spacing`
/// between tiles. A row takes photos until it is full; it then keeps the last one if that brings its height nearer
/// the target than leaving it for the next row would. The last row keeps the target height rather than stretching.
pub fn justified(ratios: &[f64], width: u32, target_height: u32, spacing: u32) -> Vec<Row> {
    let width = f64::from(width.max(1));
    let target = f64::from(target_height.max(1));
    let spacing_f = f64::from(spacing);
    let mut rows = Vec::new();
    let mut start = 0;
    while start < ratios.len() {
        let mut sum = 0.0;
        let mut end = start;
        // Take photos while the row, at the target height, is narrower than the width.
        while end < ratios.len() {
            let next = sum + clamped(ratios[end]);
            let gaps = spacing_f * (end - start) as f64;
            if next * target + gaps > width && end > start {
                // Full: keep this photo only if the row's height then lands nearer the target.
                let with_height = (width - gaps) / next;
                let without_height = (width - spacing_f * (end - start - 1) as f64) / sum;
                if (with_height - target).abs() < (without_height - target).abs() {
                    sum = next;
                    end += 1;
                }
                break;
            }
            sum = next;
            end += 1;
        }
        let count = end - start;
        let gaps = spacing_f * (count - 1) as f64;
        let last = end >= ratios.len();
        let fitted = (width - gaps) / sum;
        let height = if last && fitted > target { target } else { fitted }.max(1.0);
        let mut widths: Vec<u32> = ratios[start..end].iter().map(|ratio| (clamped(*ratio) * height).round().max(1.0) as u32).collect();
        if !(last && fitted > target) {
            // Rounding leaves a pixel or two: the last tile takes them, so the row ends at the edge.
            let used: u32 = widths.iter().sum::<u32>() + spacing * (count as u32 - 1);
            let total = width as u32;
            if let Some(last_width) = widths.last_mut() {
                *last_width = (i64::from(*last_width) + i64::from(total) - i64::from(used)).max(1) as u32;
            }
        }
        rows.push(Row { start, height: height.round() as u32, widths });
        start = end;
    }
    rows
}

/// Lay out `count` squares in rows `width` pixels wide: as many columns as fit at about `target_size`, sized to fill
/// the row.
pub fn squares(count: usize, width: u32, target_size: u32, spacing: u32) -> Vec<Row> {
    let columns = columns(width, target_size, spacing);
    let size = (width.saturating_sub(spacing * (columns as u32 - 1))) / columns as u32;
    let size = size.max(1);
    (0..count)
        .step_by(columns)
        .map(|start| {
            let in_row = columns.min(count - start);
            Row { start, height: size, widths: vec![size; in_row] }
        })
        .collect()
}

/// How many squares of about `target_size` fit across `width`, at least one.
pub fn columns(width: u32, target_size: u32, spacing: u32) -> usize {
    (((width + spacing) as f64 / (target_size.max(1) + spacing) as f64).round() as usize).max(1)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row_width(row: &Row, spacing: u32) -> u32 {
        row.widths.iter().sum::<u32>() + spacing * (row.len() as u32 - 1)
    }

    #[test]
    fn full_rows_fill_the_width_exactly_and_the_last_keeps_its_height() {
        let ratios = [1.5, 0.75, 1.0, 1.33, 1.5, 0.66, 1.78, 1.0, 1.0, 0.75];
        let rows = justified(&ratios, 1000, 200, 4);
        assert_eq!(rows.iter().map(Row::len).sum::<usize>(), ratios.len(), "every photo is in one row");
        for row in &rows[..rows.len() - 1] {
            assert_eq!(row_width(row, 4), 1000, "{row:?}");
            assert!((140..=280).contains(&row.height), "a full row's height stays near the target: {row:?}");
        }
        let last = rows.last().unwrap();
        assert!(row_width(last, 4) <= 1000);
        assert!(last.height <= 200, "the last row never stretches beyond the target");
    }

    #[test]
    fn rows_start_where_the_previous_ended() {
        let ratios = vec![1.0; 23];
        let rows = justified(&ratios, 640, 150, 2);
        let mut expected_start = 0;
        for row in &rows {
            assert_eq!(row.start, expected_start);
            expected_start += row.len();
        }
        assert_eq!(expected_start, 23);
    }

    #[test]
    fn a_panorama_is_cut_rather_than_making_a_sliver_of_a_row() {
        let rows = justified(&[20.0, 1.0, 1.0], 900, 200, 0);
        assert!(rows[0].height >= 150, "{:?}", rows[0]);
        let unknown = justified(&[f64::NAN, 0.0, -1.0], 300, 100, 0);
        assert_eq!(unknown[0].widths, vec![100, 100, 100], "an unknown shape is a square");
    }

    #[test]
    fn one_very_wide_window_still_lays_out_one_photo() {
        let rows = justified(&[1.0], 5000, 200, 4);
        assert_eq!(rows, vec![Row { start: 0, height: 200, widths: vec![200] }]);
        assert!(justified(&[], 800, 200, 4).is_empty());
    }

    #[test]
    fn squares_fill_their_rows() {
        let rows = squares(10, 1000, 200, 4);
        assert_eq!(columns(1000, 200, 4), 5);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].widths.len(), 5);
        assert!(row_width(&rows[0], 4) <= 1000 && row_width(&rows[0], 4) > 990);
        assert_eq!(squares(3, 1000, 200, 4)[0].widths.len(), 3, "a short last row keeps square tiles");
        assert_eq!(columns(50, 200, 4), 1);
    }
}
