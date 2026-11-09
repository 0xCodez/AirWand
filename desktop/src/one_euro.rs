//! The 1€ filter (Casiez, Roussel, Vogel — CHI 2012): an adaptive low-pass filter that
//! removes jitter when the pointer is slow and keeps lag low when it moves fast.

use std::f64::consts::PI;

#[derive(Debug, Clone)]
pub struct OneEuro {
    min_cutoff: f64,
    beta: f64,
    d_cutoff: f64,
    prev: Option<State>,
}

#[derive(Debug, Clone, Copy)]
struct State {
    x: f64,
    dx: f64,
    t: f64,
}

fn alpha(cutoff: f64, dt: f64) -> f64 {
    let tau = 1.0 / (2.0 * PI * cutoff);
    1.0 / (1.0 + tau / dt)
}

impl OneEuro {
    /// `min_cutoff` in Hz, `beta` in 1/(units per second), `d_cutoff` in Hz.
    pub fn new(min_cutoff: f64, beta: f64, d_cutoff: f64) -> Self {
        OneEuro { min_cutoff, beta, d_cutoff, prev: None }
    }

    pub fn reset(&mut self) {
        self.prev = None;
    }

    /// Filters sample `x` taken at time `t` (seconds, monotonic).
    pub fn filter(&mut self, x: f64, t: f64) -> f64 {
        let Some(p) = self.prev else {
            self.prev = Some(State { x, dx: 0.0, t });
            return x;
        };
        let mut dt = t - p.t;
        if !(dt > 1e-6) {
            dt = 1.0 / 120.0; // duplicate / out-of-order timestamps: assume a typical frame
        }
        let raw_dx = (x - p.x) / dt;
        let dx = p.dx + alpha(self.d_cutoff, dt) * (raw_dx - p.dx);
        let cutoff = self.min_cutoff + self.beta * dx.abs();
        let x_hat = p.x + alpha(cutoff, dt) * (x - p.x);
        self.prev = Some(State { x: x_hat, dx, t: p.t + dt });
        x_hat
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn constant_signal_is_unchanged() {
        let mut f = OneEuro::new(1.0, 0.007, 1.0);
        for i in 0..100 {
            assert!((f.filter(500.0, i as f64 / 60.0) - 500.0).abs() < 1e-9);
        }
    }

    #[test]
    fn smooths_jitter_and_converges() {
        let mut f = OneEuro::new(1.0, 0.007, 1.0);
        let mut out = 0.0;
        for i in 0..600 {
            let noise = if i % 2 == 0 { 3.0 } else { -3.0 };
            out = f.filter(100.0 + noise, i as f64 / 60.0);
        }
        assert!((out - 100.0).abs() < 1.5, "jitter should be strongly attenuated, got {out}");
    }

    #[test]
    fn fast_moves_have_low_lag() {
        let mut slow = OneEuro::new(1.0, 0.0, 1.0);
        let mut fast = OneEuro::new(1.0, 0.05, 1.0);
        let (mut a, mut b) = (0.0, 0.0);
        for i in 0..30 {
            let x = i as f64 * 40.0; // 2400 px/s
            let t = i as f64 / 60.0;
            a = slow.filter(x, t);
            b = fast.filter(x, t);
        }
        assert!(b > a, "beta should reduce lag on fast motion");
    }
}
