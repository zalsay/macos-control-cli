//! Display-pixel version of swift/CursorMotion.swift's Bézier/minimum-jerk planner.
//! This only plans points; input still passes through the existing Actions gate.
use crate::protocol::{Error, Result};

#[derive(Clone, Copy, Debug)]
pub(super) struct Sample {
    pub point: (i64, i64),
    pub at_ms: u64,
}

pub(super) fn plan(
    start: (i64, i64),
    end: (i64, i64),
    width: u32,
    height: u32,
    duration_ms: Option<u64>,
    bend: f64,
    timing: f64,
) -> Result<Vec<Sample>> {
    let inside = |(x, y): (i64, i64)| x >= 0 && y >= 0 && x < width as i64 && y < height as i64;
    if !inside(start) || !inside(end) || !bend.is_finite() || !timing.is_finite() {
        return Err(Error::new("INPUT_FAILED", "无法生成视口范围内的鼠标轨迹"));
    }
    let dx = (end.0 - start.0) as f64;
    let dy = (end.1 - start.1) as f64;
    let distance = dx.hypot(dy);
    let automatic_ms = if distance == 0.0 {
        0
    } else {
        ((0.15 + distance / 2200.0) * (1.0 + 0.1 * timing.clamp(-1.0, 1.0)))
            .clamp(0.15, 0.7)
            .mul_add(1000.0, 0.0)
            .round() as u64
    };
    let duration = duration_ms.unwrap_or(automatic_ms);
    if duration > 2000 {
        return Err(Error::invalid("移动时长不能超过 2000ms"));
    }
    if duration == 0 {
        return Ok(vec![Sample {
            point: end,
            at_ms: 0,
        }]);
    }
    let steps = (duration * 60).div_ceil(1000);
    let deviation = distance.mul_add(0.08, 0.0).min(28.0) * bend.clamp(-1.0, 1.0);
    // A curved path near an edge may leave the viewport. As on macOS, fall
    // back to a straight path with the same easing, never an instant jump.
    for offset in [deviation, 0.0] {
        let (nx, ny) = if distance == 0.0 {
            (0.0, 0.0)
        } else {
            (-dy / distance * offset, dx / distance * offset)
        };
        let a = (
            start.0 as f64 + dx / 3.0 + nx,
            start.1 as f64 + dy / 3.0 + ny,
        );
        let b = (
            start.0 as f64 + dx * 2.0 / 3.0 + nx * 0.7,
            start.1 as f64 + dy * 2.0 / 3.0 + ny * 0.7,
        );
        let mut samples = Vec::with_capacity(steps as usize + 1);
        for i in 0..=steps {
            let u = i as f64 / steps as f64;
            let t = u * u * u * (10.0 + u * (-15.0 + 6.0 * u));
            let v = 1.0 - t;
            let (x, y) = if i == 0 {
                (start.0 as f64, start.1 as f64)
            } else if i == steps {
                (end.0 as f64, end.1 as f64)
            } else {
                (
                    v.powi(3) * start.0 as f64
                        + 3.0 * v * v * t * a.0
                        + 3.0 * v * t * t * b.0
                        + t.powi(3) * end.0 as f64,
                    v.powi(3) * start.1 as f64
                        + 3.0 * v * v * t * a.1
                        + 3.0 * v * t * t * b.1
                        + t.powi(3) * end.1 as f64,
                )
            };
            if x < 0.0 || y < 0.0 || x >= width as f64 || y >= height as f64 {
                break;
            }
            // System input uses integer pixels. Rounding at the far edge must
            // not turn an in-bounds subpixel sample into an out-of-bounds pixel.
            samples.push(Sample {
                point: (
                    (x.round() as i64).min(width as i64 - 1),
                    (y.round() as i64).min(height as i64 - 1),
                ),
                at_ms: duration * i / steps,
            });
        }
        if samples.len() == steps as usize + 1 {
            return Ok(samples);
        }
    }
    Err(Error::new("INPUT_FAILED", "无法生成视口范围内的鼠标轨迹"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_swift_curve_endpoints_easing_and_bounded_variation() {
        let samples = plan((100, 100), (1100, 600), 1600, 1000, None, 0.7, 0.0).unwrap();
        assert_eq!(samples.first().unwrap().point, (100, 100));
        assert_eq!(samples.last().unwrap().point, (1100, 600));
        assert_eq!(samples.last().unwrap().at_ms, 658);
        assert!(samples.windows(2).all(|p| p[0].at_ms < p[1].at_ms));
        assert!(
            samples
                .iter()
                .any(|p| { ((p.point.0 - 100) * 500 - (p.point.1 - 100) * 1000).abs() > 1000 }),
            "curve must deviate from a straight line"
        );
        let projection = |p: (i64, i64)| (p.0 - 100) * 1000 + (p.1 - 100) * 500;
        assert!(samples
            .windows(2)
            .all(|p| projection(p[0].point) <= projection(p[1].point)));
        let delta = |i: usize| projection(samples[i + 1].point) - projection(samples[i].point);
        assert!(delta(0) < delta(samples.len() / 2));
        assert!(delta(samples.len() - 2) < delta(samples.len() / 2));
        // The midpoint is shared by the Swift 40-step reference trajectory.
        assert_eq!(samples[20].point, (594, 361));
    }

    #[test]
    fn edges_short_distances_same_point_and_explicit_zero_remain_exact() {
        for bend in [-1.0, 0.0, 1.0] {
            let samples = plan((0, 0), (1199, 0), 1200, 800, None, bend, 1.0).unwrap();
            assert!(samples
                .iter()
                .all(|p| (0..800).contains(&p.point.1) && (0..1200).contains(&p.point.0)));
            if bend <= 0.0 {
                assert!(
                    samples.iter().all(|p| p.point.1 == 0),
                    "outward bend must fall back to an eased straight path"
                );
            }
            assert_eq!(samples.last().unwrap().point, (1199, 0));
        }
        let still = plan((100, 100), (100, 100), 1200, 800, None, 1.0, 0.0).unwrap();
        assert_eq!(still.len(), 1);
        assert_eq!(still[0].at_ms, 0);
        let short = plan((100, 100), (101, 100), 1200, 800, None, -1.0, -1.0).unwrap();
        assert_eq!(short.last().unwrap().at_ms, 150);
        let instant = plan((100, 100), (1000, 600), 1200, 800, Some(0), 1.0, 0.0).unwrap();
        assert_eq!(instant.len(), 1);
        assert_eq!(instant[0].point, (1000, 600));
        assert!(plan((-1, 0), (100, 100), 1200, 800, None, 0.0, 0.0).is_err());
        assert!(plan((0, 0), (1200, 100), 1200, 800, None, 0.0, 0.0).is_err());
        assert!(plan((0, 0), (100, 100), 1200, 800, None, f64::NAN, 0.0).is_err());
    }
}
