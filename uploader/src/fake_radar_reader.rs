use std::time::Duration;

use rand::Rng;
use tokio::time::sleep;

use crate::{actor::Actor, infraction_recorder::InfractionRecorder};

pub struct FakeRadarReader {
    infraction_recorder: InfractionRecorder,
}

impl FakeRadarReader {
    pub fn new(infraction_recorder: InfractionRecorder) -> Self {
        Self {
            infraction_recorder,
        }
    }
}

const TICK_MS: u64 = 200;

/// A simulated target approaching the radar with smooth motion.
struct Target {
    x: f64,  // mm, lateral position
    y: f64,  // mm, forward distance from radar
    vx: f64, // mm/s, lateral velocity
    vy: f64, // mm/s, forward velocity (negative = approaching)
}

impl Target {
    fn new(rng: &mut impl Rng) -> Self {
        let y = rng.random_range(9000.0_f64..14000.0);
        let x = rng.random_range(-3000.0_f64..3000.0);
        let speed_kmh = rng.random_range(3.0_f64..15.0); // walking 3-5, jogging 8-10, running 12-15
        let vy = -speed_kmh / 3.6 * 1000.0;
        let vx = rng.random_range(-300.0_f64..300.0);
        Self { x, y, vx, vy }
    }

    fn step(&mut self, dt: f64, rng: &mut impl Rng) {
        // Smooth random acceleration (mm/s²)
        self.vx += rng.random_range(-200.0_f64..200.0) * dt;
        self.vy += rng.random_range(-500.0_f64..500.0) * dt;

        // Clamp velocities to pedestrian bounds
        self.vx = self.vx.clamp(-600.0, 600.0);
        self.vy = self.vy.clamp(-4200.0, -800.0); // ~3-15 km/h forward

        self.x += self.vx * dt;
        self.y += self.vy * dt;
    }

    fn speed_kmh(&self) -> i16 {
        let speed_mm_s = (self.vx.powi(2) + self.vy.powi(2)).sqrt();
        (speed_mm_s / 1000.0 * 3.6) as i16
    }

    fn has_passed(&self) -> bool {
        self.y < -500.0
    }
}

impl Actor for FakeRadarReader {
    type Command = ();

    async fn event_loop(
        self,
        _port: crate::actor::ActorPort<Self::Command>,
        _command_receiver: tokio::sync::mpsc::UnboundedReceiver<Self::Command>,
    ) {
        log::info!("Fake radar reader started — generating synthetic data");

        let mut rng = rand::rng();
        let dt = TICK_MS as f64 / 1000.0;

        loop {
            let mut target = Target::new(&mut rng);
            log::info!(
                "New target at ({:.0}, {:.0}), ~{} km/h",
                target.x,
                target.y,
                target.speed_kmh()
            );

            while !target.has_passed() {
                let message = format!(
                    "EVENTS: TARGET: {} {} {}",
                    target.speed_kmh(),
                    target.x as i16,
                    target.y as i16,
                );
                log::debug!("Fake radar: {message}");
                self.infraction_recorder
                    .process_log_message(message)
                    .await;
                target.step(dt, &mut rng);
                sleep(Duration::from_millis(TICK_MS)).await;
            }

            // Brief gap between targets
            let gap_ms = rng.random_range(500_u64..2000);
            sleep(Duration::from_millis(gap_ms)).await;
        }
    }
}
