//! Pointer smoother: a dedicated ~240 Hz thread that owns the input `Injector` and turns
//! bursty network MOVE / AIM packets into an even stream of OS pointer events.
//!
//! * MOVE deltas are added to a pending `f64` backlog. Every tick releases the fraction
//!   `alpha = 1 - exp(-dt / tau)` of it (frame-rate independent exponential easing,
//!   `tau` ≈ 6 ms), with sub-pixel accumulation so fractional pixels are never lost and only
//!   whole pixels are injected. A backlog is never older than `MAX_LAG` (25 ms): as the last
//!   push ages, the release fraction ramps up to drain it fully by then; large backlogs
//!   (network hiccups) also shorten `tau`.
//! * AIM targets (already 1€-filtered in `Injector`) are followed with the same easing, so
//!   absolute moves are emitted at the tick rate, interpolating between packets.
//! * Every other message (buttons, clicks, keys, scroll, text…) is handled as soon as it is
//!   received; BUTTON / CLICK flush pending motion first so clicks land where intended.
//! * Pause / watchdog / BYE send `Cmd::ReleaseAll`, which also drops pending motion.
//!
//! When there is no motion in flight the thread blocks on its channel (no idle wake-ups).
//! Timing: `thread::sleep` until ~0.7 ms before the deadline, then a yielding spin-tail.

use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender, TryRecvError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use crate::input::Injector;
use crate::protocol::Message;

/// Tick rate of the motion thread.
pub const TICK_HZ: f64 = 240.0;
/// Exponential easing time constant for relative motion (seconds).
pub const TAU: f64 = 0.006;
/// Pending motion is fully emitted at most this long after its last push (seconds).
pub const MAX_LAG: f64 = 0.025;
/// Backlog size (px) at which `tau` is halved; larger backlogs drain proportionally faster.
pub const BACKLOG_PX: f64 = 150.0;
/// Easing time constant for AIM absolute targets (seconds).
pub const AIM_TAU: f64 = 0.008;
/// The spin-tail before each deadline.
const SPIN_TAIL: Duration = Duration::from_micros(700);
/// How long the thread blocks when idle before re-checking (only matters for shutdown).
const IDLE_WAIT: Duration = Duration::from_millis(100);

fn ease_alpha(dt: f64, tau: f64) -> f64 {
    if dt <= 0.0 {
        return 0.0;
    }
    1.0 - (-dt / tau).exp()
}

/// Pure relative-motion smoother (no OS calls). Times are seconds on any monotonic clock.
#[derive(Debug, Clone)]
pub struct RelSmoother {
    tau: f64,
    max_lag: f64,
    pending: (f64, f64),
    frac: (f64, f64),
    last_push: f64,
    last_tick: Option<f64>,
}

impl Default for RelSmoother {
    fn default() -> Self {
        RelSmoother::new(TAU, MAX_LAG)
    }
}

impl RelSmoother {
    pub fn new(tau: f64, max_lag: f64) -> Self {
        RelSmoother { tau, max_lag, pending: (0.0, 0.0), frac: (0.0, 0.0), last_push: 0.0, last_tick: None }
    }

    pub fn push(&mut self, dx: f64, dy: f64, now: f64) {
        if !dx.is_finite() || !dy.is_finite() {
            return;
        }
        if !self.is_active() {
            // Start a fresh timeline: the first tick after idle gets a nominal dt.
            self.last_tick = None;
        }
        self.pending.0 += dx;
        self.pending.1 += dy;
        self.last_push = now;
    }

    /// True while there is pending motion to emit.
    pub fn is_active(&self) -> bool {
        self.pending.0 != 0.0 || self.pending.1 != 0.0
    }

    /// Advances to `now` and returns the whole pixels to inject now.
    pub fn tick(&mut self, now: f64) -> (i32, i32) {
        let dt = match self.last_tick {
            Some(t) => (now - t).clamp(0.0, 0.1),
            None => 1.0 / TICK_HZ,
        };
        self.last_tick = Some(now);
        if !self.is_active() {
            return (0, 0);
        }
        let mag = self.pending.0.hypot(self.pending.1);
        let tau = self.tau / (1.0 + mag / BACKLOG_PX);
        let mut a = ease_alpha(dt, tau);
        // Deadline guarantee: everything is out by `max_lag` after the last push.
        let age = now - self.last_push;
        let remaining = self.max_lag - age;
        if remaining <= dt || mag < 0.02 {
            a = 1.0;
        } else {
            a = a.max(dt / remaining);
        }
        let (ox, oy) = if a >= 1.0 { self.pending } else { (self.pending.0 * a, self.pending.1 * a) };
        if a >= 1.0 {
            self.pending = (0.0, 0.0);
        } else {
            self.pending.0 -= ox;
            self.pending.1 -= oy;
        }
        self.emit(ox, oy)
    }

    /// Emits all pending motion now (before a click, for example).
    pub fn flush(&mut self) -> (i32, i32) {
        let (ox, oy) = self.pending;
        self.pending = (0.0, 0.0);
        self.emit(ox, oy)
    }

    /// Drops pending motion and the sub-pixel remainder.
    pub fn clear(&mut self) {
        self.pending = (0.0, 0.0);
        self.frac = (0.0, 0.0);
        self.last_tick = None;
    }

    fn emit(&mut self, ox: f64, oy: f64) -> (i32, i32) {
        self.frac.0 = snap(self.frac.0 + ox);
        self.frac.1 = snap(self.frac.1 + oy);
        let ix = self.frac.0.trunc();
        let iy = self.frac.1.trunc();
        self.frac.0 -= ix;
        self.frac.1 -= iy;
        (ix as i32, iy as i32)
    }
}

/// Removes floating-point noise next to whole numbers (so 9.999999999999998 counts as 10).
fn snap(v: f64) -> f64 {
    let r = v.round();
    if (v - r).abs() < 1e-9 {
        r
    } else {
        v
    }
}

/// Pure absolute-target follower for AIM (no OS calls): eases the emitted position toward
/// the newest target at the tick rate, so packets arriving at 60–120 Hz are interpolated.
#[derive(Debug, Clone, Default)]
pub struct AbsFollower {
    pos: Option<(f64, f64)>,
    target: Option<(f64, f64)>,
    last_tick: Option<f64>,
}

impl AbsFollower {
    /// Sets a new target. The first target after a reset is jumped to directly.
    pub fn set_target(&mut self, x: f64, y: f64) {
        if self.pos.is_none() {
            self.pos = Some((x, y));
        }
        self.target = Some((x, y));
    }

    pub fn is_active(&self) -> bool {
        match (self.pos, self.target) {
            (Some(p), Some(t)) => (p.0 - t.0).abs() > 0.25 || (p.1 - t.1).abs() > 0.25 || self.last_tick.is_none(),
            _ => false,
        }
    }

    /// Returns the position to move to, or `None` when nothing changed.
    pub fn tick(&mut self, now: f64) -> Option<(f64, f64)> {
        let (p, t) = (self.pos?, self.target?);
        let first = self.last_tick.is_none();
        let dt = self.last_tick.map_or(1.0 / TICK_HZ, |l| (now - l).clamp(0.0, 0.1));
        self.last_tick = Some(now);
        let a = ease_alpha(dt, AIM_TAU);
        let mut np = (p.0 + (t.0 - p.0) * a, p.1 + (t.1 - p.1) * a);
        if (t.0 - np.0).abs() <= 0.25 && (t.1 - np.1).abs() <= 0.25 {
            np = t;
        }
        self.pos = Some(np);
        let moved = np.0.round() != p.0.round() || np.1.round() != p.1.round();
        let settled = np == t && p != t;
        if first || moved || settled {
            Some(np)
        } else {
            None
        }
    }

    pub fn reset(&mut self) {
        *self = AbsFollower::default();
    }

    pub fn target(&self) -> Option<(f64, f64)> {
        self.target
    }

    pub fn position(&self) -> Option<(f64, f64)> {
        self.pos
    }
}

/// Commands from the control thread.
pub enum Cmd {
    Msg(Message),
    /// Release held buttons / keys and drop pending motion (BYE, silence, pause).
    ReleaseAll,
    /// Release everything and stop the thread.
    Shutdown,
}

/// Handle to the motion thread.
pub struct Smoother {
    tx: Sender<Cmd>,
    handle: Option<JoinHandle<()>>,
}

impl Smoother {
    /// Spawns the motion thread. The `Injector` is created on that thread (platform
    /// backends are not required to be `Send`).
    pub fn spawn(invert_scroll: bool) -> std::io::Result<Smoother> {
        let (tx, rx) = mpsc::channel();
        let handle = std::thread::Builder::new()
            .name("orbit-motion".into())
            .spawn(move || run(rx, Injector::new(invert_scroll)))?;
        Ok(Smoother { tx, handle: Some(handle) })
    }

    pub fn send(&self, msg: Message) {
        let _ = self.tx.send(Cmd::Msg(msg));
    }

    pub fn release_all(&self) {
        let _ = self.tx.send(Cmd::ReleaseAll);
    }

    /// Releases everything and waits for the thread to finish.
    pub fn shutdown(&mut self) {
        let _ = self.tx.send(Cmd::Shutdown);
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}

/// Returns false when the thread should stop.
fn apply(inj: &mut Injector, cmd: Cmd, now: f64) -> bool {
    match cmd {
        Cmd::Msg(m) => inj.handle(&m, now),
        Cmd::ReleaseAll => {
            if inj.has_held_input() {
                log::info!("releasing held buttons / keys");
            }
            inj.release_all();
        }
        Cmd::Shutdown => {
            inj.release_all();
            return false;
        }
    }
    true
}

fn run(rx: Receiver<Cmd>, mut inj: Injector) {
    let epoch = Instant::now();
    let secs = |i: Instant| i.duration_since(epoch).as_secs_f64();
    let period = Duration::from_secs_f64(1.0 / TICK_HZ);
    let mut next_tick: Option<Instant> = None;
    loop {
        // Idle: block until something arrives.
        if !inj.motion_active() {
            next_tick = None;
            match rx.recv_timeout(IDLE_WAIT) {
                Ok(cmd) => {
                    if !apply(&mut inj, cmd, secs(Instant::now())) {
                        return;
                    }
                }
                Err(RecvTimeoutError::Timeout) => continue,
                Err(RecvTimeoutError::Disconnected) => {
                    inj.release_all();
                    return;
                }
            }
        }
        // Drain everything queued (low latency for clicks / keys).
        loop {
            match rx.try_recv() {
                Ok(cmd) => {
                    if !apply(&mut inj, cmd, secs(Instant::now())) {
                        return;
                    }
                }
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => {
                    inj.release_all();
                    return;
                }
            }
        }
        if !inj.motion_active() {
            continue;
        }
        let now = Instant::now();
        let deadline = match next_tick {
            // First tick of a motion burst runs immediately: no added start latency.
            None => now,
            Some(t) if t + period < now => now, // fell behind: do not try to catch up
            Some(t) => t,
        };
        if deadline > now + SPIN_TAIL {
            std::thread::sleep(deadline - now - SPIN_TAIL);
        }
        while Instant::now() < deadline {
            std::thread::yield_now();
        }
        // Pick up anything that arrived while sleeping before emitting this tick.
        loop {
            match rx.try_recv() {
                Ok(cmd) => {
                    if !apply(&mut inj, cmd, secs(Instant::now())) {
                        return;
                    }
                }
                Err(_) => break,
            }
        }
        inj.tick_motion(secs(Instant::now()));
        next_tick = Some(deadline + period);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DT: f64 = 1.0 / TICK_HZ;

    /// Runs ticks from `t` until `until`, returning summed output and the final time.
    fn run_ticks(s: &mut RelSmoother, mut t: f64, until: f64, out: &mut (i64, i64)) -> f64 {
        while t < until {
            t += DT;
            let (x, y) = s.tick(t);
            out.0 += x as i64;
            out.1 += y as i64;
        }
        t
    }

    #[test]
    fn total_output_equals_total_input() {
        let mut s = RelSmoother::default();
        let mut out = (0i64, 0i64);
        let (mut tx, mut ty) = (0.0f64, 0.0f64);
        let mut t = 0.0;
        // 120 Hz packets with awkward fractional deltas, ticked at 240 Hz.
        for i in 0..500 {
            let dx = 0.37 + (i % 7) as f64 * 0.91;
            let dy = -0.13 - (i % 5) as f64 * 0.47;
            s.push(dx, dy, t);
            tx += dx;
            ty += dy;
            t = run_ticks(&mut s, t, t + 1.0 / 120.0, &mut out);
        }
        run_ticks(&mut s, t, t + 0.1, &mut out);
        assert!(!s.is_active());
        assert_eq!(out.0, tx.trunc() as i64);
        assert_eq!(out.1, ty.trunc() as i64);
        // The remainder is kept, not lost.
        assert!((out.0 as f64 + s.frac.0 - tx).abs() < 1e-6);
        assert!((out.1 as f64 + s.frac.1 - ty).abs() < 1e-6);
    }

    #[test]
    fn sub_pixel_motion_is_not_lost() {
        let mut s = RelSmoother::default();
        let mut out = (0i64, 0i64);
        let mut t = 0.0;
        for _ in 0..100 {
            s.push(0.1, -0.1, t); // 0.1 is inexact in binary: exercises `snap`
            t = run_ticks(&mut s, t, t + 0.03, &mut out);
        }
        assert_eq!(out, (10, -10));
    }

    #[test]
    fn converges_within_max_lag() {
        let mut s = RelSmoother::default();
        s.push(40.0, 0.0, 0.0);
        let mut emitted = 0i64;
        let mut t = 0.0;
        let mut half_at = None;
        while s.is_active() {
            t += DT;
            emitted += s.tick(t).0 as i64;
            if half_at.is_none() && emitted >= 20 {
                half_at = Some(t);
            }
            assert!(t <= MAX_LAG + DT + 1e-9, "still pending after {t}s");
        }
        assert_eq!(emitted, 40);
        // Smooth but responsive: half the move is out within ~1.5 tau.
        assert!(half_at.unwrap() <= 0.0095, "half at {:?}", half_at);
    }

    #[test]
    fn large_backlog_flushes_faster() {
        let mut big = RelSmoother::default();
        let mut small = RelSmoother::default();
        big.push(1000.0, 0.0, 0.0);
        small.push(10.0, 0.0, 0.0);
        let first_big = big.tick(DT).0;
        let first_small = small.tick(DT).0;
        let (b, s) = (first_big as f64 / 1000.0, first_small as f64 / 10.0);
        assert!(b > s, "big backlog should release a larger fraction ({b} vs {s})");
        let mut out = (first_big as i64, 0i64);
        run_ticks(&mut big, DT, MAX_LAG + DT, &mut out);
        assert!(!big.is_active());
        assert_eq!(out.0, 1000);
    }

    #[test]
    fn frame_rate_independent() {
        // The same input at 240 Hz vs 120 Hz ticks emits ~the same amount after 8 ms.
        let mut a = RelSmoother::new(TAU, 1.0);
        let mut b = RelSmoother::new(TAU, 1.0);
        a.push(100.0, 0.0, 0.0);
        b.push(100.0, 0.0, 0.0);
        a.tick(0.0);
        b.tick(0.0);
        a.flush_frac_for_test();
        b.flush_frac_for_test();
        let mut sa = 0;
        for i in 1..=4 {
            sa += a.tick(i as f64 * 0.002).0;
        }
        let mut sb = 0;
        for i in 1..=2 {
            sb += b.tick(i as f64 * 0.004).0;
        }
        assert!((sa - sb).abs() <= 2, "{sa} vs {sb}");
    }

    #[test]
    fn flush_and_clear() {
        let mut s = RelSmoother::default();
        s.push(12.6, -3.4, 0.0);
        assert_eq!(s.flush(), (12, -3));
        assert!(!s.is_active());
        s.push(5.0, 5.0, 0.0);
        s.clear();
        assert!(!s.is_active());
        assert_eq!(s.tick(0.01), (0, 0));
        assert_eq!(s.flush(), (0, 0));
    }

    #[test]
    fn aim_follower_interpolates_and_settles() {
        let mut f = AbsFollower::default();
        f.set_target(100.0, 100.0);
        assert_eq!(f.tick(0.0), Some((100.0, 100.0)));
        f.set_target(200.0, 100.0);
        let mut t = 0.0;
        let mut last = 100.0;
        let mut steps = 0;
        while f.is_active() {
            t += DT;
            if let Some((x, _)) = f.tick(t) {
                assert!(x >= last && x <= 200.0);
                last = x;
                steps += 1;
            }
            assert!(t < 0.1);
        }
        assert_eq!(last, 200.0);
        assert!(steps > 3, "should glide over several ticks, got {steps}");
    }

    impl RelSmoother {
        fn flush_frac_for_test(&mut self) {
            self.frac = (0.0, 0.0);
        }
    }
}
