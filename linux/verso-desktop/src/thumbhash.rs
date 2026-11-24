//! ThumbHash placeholders (https://evanw.github.io/thumbhash/), which Immich keeps for every Asset: a blurred
//! picture shown while the thumbnail loads. Ported from Immich Gallery's Swift port of Evan Wallace's reference
//! implementation (both MIT; THIRD-PARTY-NOTICES.md).

use base64::Engine;

use crate::images::Picture;

/// The placeholder for a base64 ThumbHash, about 32 pixels on its long side; `None` for a hash that cannot be read.
pub fn from_base64(hash: &str) -> Option<Picture> {
    let bytes = base64::engine::general_purpose::STANDARD.decode(hash.trim()).ok()?;
    decode(&bytes)
}

/// Decode a ThumbHash into straight (not premultiplied) RGBA. The loops index the cosine tables as the reference
/// implementation does, which reads more plainly here than iterators.
#[allow(clippy::needless_range_loop)]
pub fn decode(hash: &[u8]) -> Option<Picture> {
    if hash.len() < 5 {
        return None;
    }
    let header24 = u32::from(hash[0]) | u32::from(hash[1]) << 8 | u32::from(hash[2]) << 16;
    let header16 = u32::from(hash[3]) | u32::from(hash[4]) << 8;
    let l_dc = f64::from(header24 & 63) / 63.0;
    let p_dc = f64::from((header24 >> 6) & 63) / 31.5 - 1.0;
    let q_dc = f64::from((header24 >> 12) & 63) / 31.5 - 1.0;
    let l_scale = f64::from((header24 >> 18) & 31) / 31.0;
    let has_alpha = (header24 >> 23) != 0;
    let p_scale = f64::from((header16 >> 3) & 63) / 63.0;
    let q_scale = f64::from((header16 >> 9) & 63) / 63.0;
    let is_landscape = (header16 >> 15) != 0;
    let lx = (if is_landscape { if has_alpha { 5 } else { 7 } } else { header16 & 7 }).max(3) as usize;
    let ly = (if is_landscape { header16 & 7 } else if has_alpha { 5 } else { 7 }).max(3) as usize;
    let (a_dc, a_scale) = if has_alpha && hash.len() > 5 {
        (f64::from(hash[5] & 15) / 15.0, f64::from(hash[5] >> 4) / 15.0)
    } else {
        (1.0, 0.0)
    };

    let ac_start = if has_alpha { 6 } else { 5 };
    let mut ac_index = 0usize;
    let mut decode_channel = |columns: usize, rows: usize, scale: f64| {
        let mut ac = Vec::new();
        for cy in 0..rows {
            let mut cx = if cy > 0 { 0 } else { 1 };
            while cx * rows < columns * (rows - cy) {
                let byte = hash.get(ac_start + (ac_index >> 1)).copied().map_or(0, u32::from);
                ac.push((f64::from((byte >> ((ac_index & 1) << 2)) & 15) / 7.5 - 1.0) * scale);
                ac_index += 1;
                cx += 1;
            }
        }
        ac
    };
    let l_ac = decode_channel(lx, ly, l_scale);
    let p_ac = decode_channel(3, 3, p_scale * 1.25);
    let q_ac = decode_channel(3, 3, q_scale * 1.25);
    let a_ac = if has_alpha { decode_channel(5, 5, a_scale) } else { Vec::new() };

    let ratio = lx as f64 / ly as f64;
    let width = (if ratio > 1.0 { 32.0 } else { 32.0 * ratio }).round() as usize;
    let height = (if ratio > 1.0 { 32.0 / ratio } else { 32.0 }).round() as usize;
    if width == 0 || height == 0 {
        return None;
    }
    let mut rgba = vec![0u8; width * height * 4];
    let nx = lx.max(if has_alpha { 5 } else { 3 });
    let ny = ly.max(if has_alpha { 5 } else { 3 });
    let mut fx = vec![0.0; nx];
    let mut fy = vec![0.0; ny];
    let mut pixel = 0;
    for y in 0..height {
        for (cy, factor) in fy.iter_mut().enumerate() {
            *factor = (std::f64::consts::PI / height as f64 * (y as f64 + 0.5) * cy as f64).cos();
        }
        for x in 0..width {
            for (cx, factor) in fx.iter_mut().enumerate() {
                *factor = (std::f64::consts::PI / width as f64 * (x as f64 + 0.5) * cx as f64).cos();
            }
            let (mut l, mut p, mut q, mut a) = (l_dc, p_dc, q_dc, a_dc);
            let mut index = 0;
            for cy in 0..ly {
                let mut cx = if cy > 0 { 0 } else { 1 };
                let fy2 = fy[cy] * 2.0;
                while cx * ly < lx * (ly - cy) {
                    l += l_ac[index] * fx[cx] * fy2;
                    index += 1;
                    cx += 1;
                }
            }
            index = 0;
            for cy in 0..3 {
                let mut cx = if cy > 0 { 0 } else { 1 };
                let fy2 = fy[cy] * 2.0;
                while cx < 3 - cy {
                    let factor = fx[cx] * fy2;
                    p += p_ac[index] * factor;
                    q += q_ac[index] * factor;
                    index += 1;
                    cx += 1;
                }
            }
            if has_alpha {
                index = 0;
                for cy in 0..5 {
                    let mut cx = if cy > 0 { 0 } else { 1 };
                    let fy2 = fy[cy] * 2.0;
                    while cx < 5 - cy {
                        a += a_ac[index] * fx[cx] * fy2;
                        index += 1;
                        cx += 1;
                    }
                }
            }
            let blue = l - 2.0 / 3.0 * p;
            let red = (3.0 * l - blue + q) / 2.0;
            let green = red - q;
            let channel = |value: f64| (255.0 * value.clamp(0.0, 1.0)).round() as u8;
            rgba[pixel] = channel(red);
            rgba[pixel + 1] = channel(green);
            rgba[pixel + 2] = channel(blue);
            rgba[pixel + 3] = channel(a);
            pixel += 4;
        }
    }
    Some(Picture { width: width as u32, height: height as u32, rgba })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_hash_from_the_lab_server_decodes_to_a_portrait_placeholder() {
        // The lab's Lyon photos are portrait (ratio 0.75).
        let picture = from_base64("HQgKDQIDSW2VuGdnh3p3h/+a0a8p").expect("decodes");
        assert!(picture.height > picture.width, "{}x{}", picture.width, picture.height);
        assert_eq!(picture.height, 32);
        assert_eq!(picture.rgba.len(), (picture.width * picture.height * 4) as usize);
        assert!(picture.rgba.chunks(4).all(|pixel| pixel[3] == 255), "no alpha in a photo's hash");
        assert!(picture.rgba.chunks(4).any(|pixel| pixel[0] != pixel[2]), "it has colour");
    }

    #[test]
    fn garbage_is_no_placeholder() {
        assert!(from_base64("not base64!").is_none());
        assert!(decode(&[1, 2, 3]).is_none());
    }
}
