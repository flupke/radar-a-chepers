//! Pi-to-ESP capture configuration. V2 acknowledgments echo the command revision.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TriggerConfig {
    pub authorized_speed_kmh: i16,
    pub min_dist_mm: i32,
    pub max_dist_mm: i32,
    pub trigger_cooldown_ms: u64,
    pub aperture_angle_degrees: i16,
    pub capture_paused: bool,
}

impl TriggerConfig {
    pub const fn default() -> Self {
        Self {
            authorized_speed_kmh: 25,
            min_dist_mm: 0,
            max_dist_mm: 10_000,
            trigger_cooldown_ms: 1000,
            aperture_angle_degrees: 90,
            // A reboot must not resume a camera that was paused by the user.
            capture_paused: true,
        }
    }
}

pub struct ConfigCommand<'a> {
    pub config: TriggerConfig,
    revision: Option<&'a str>,
}

impl ConfigCommand<'_> {
    pub fn acknowledgement<'a>(&self, buffer: &'a mut [u8; 32]) -> &'a [u8] {
        let prefix = b"CONFIG_OK";
        buffer[..prefix.len()].copy_from_slice(prefix);
        let mut len = prefix.len();
        if let Some(revision) = self.revision {
            buffer[len] = b' ';
            len += 1;
            buffer[len..len + revision.len()].copy_from_slice(revision.as_bytes());
            len += revision.len();
        }
        buffer[len] = b'\n';
        &buffer[..len + 1]
    }
}

pub fn parse_config_command(line: &str) -> Option<ConfigCommand<'_>> {
    let mut parts = line.split_whitespace();
    let revision = match parts.next()? {
        "CONFIG_V2" => {
            let revision = parts.next()?;
            if revision.len() > 20 || !revision.bytes().all(|byte| byte.is_ascii_digit()) {
                return None;
            }
            revision.parse::<u64>().ok()?;
            Some(revision)
        }
        // During deployment, the firmware is flashed before replacing the Pi
        // uploader. Keep accepting the previous uploader's complete command.
        "CONFIG" => None,
        _ => return None,
    };
    let config = TriggerConfig {
        authorized_speed_kmh: parts.next()?.parse().ok()?,
        min_dist_mm: parts.next()?.parse().ok()?,
        max_dist_mm: parts.next()?.parse().ok()?,
        trigger_cooldown_ms: parts.next()?.parse().ok()?,
        aperture_angle_degrees: parts.next()?.parse().ok()?,
        capture_paused: match parts.next()? {
            "0" => false,
            "1" => true,
            _ => return None,
        },
    };
    if parts.next().is_some()
        || config.authorized_speed_kmh <= 0
        || config.min_dist_mm < 0
        || config.max_dist_mm <= 0
        || config.max_dist_mm < config.min_dist_mm
        || !(1..=180).contains(&config.aperture_angle_degrees)
    {
        return None;
    }
    Some(ConfigCommand { config, revision })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn applies_and_acknowledges_the_exact_revision() {
        let command =
            parse_config_command("CONFIG_V2 18446744073709551615 42 1235 9877 1500 64 1\n")
                .unwrap();
        assert_eq!(
            command.config,
            TriggerConfig {
                authorized_speed_kmh: 42,
                min_dist_mm: 1235,
                max_dist_mm: 9877,
                trigger_cooldown_ms: 1500,
                aperture_angle_degrees: 64,
                capture_paused: true,
            }
        );
        assert_eq!(
            command.acknowledgement(&mut [0; 32]),
            b"CONFIG_OK 18446744073709551615\n"
        );
    }

    #[test]
    fn legacy_uploader_can_configure_newly_flashed_firmware() {
        let command = parse_config_command("CONFIG 25 0 10000 1000 90 0").unwrap();
        assert!(!command.config.capture_paused);
        assert_eq!(command.acknowledgement(&mut [0; 32]), b"CONFIG_OK\n");
        assert!(TriggerConfig::default().capture_paused);
    }

    #[test]
    fn incomplete_or_invalid_commands_are_not_acknowledged() {
        for command in [
            "CONFIG_V2 1 25 0 10000 1000 90",
            "CONFIG_V2 1 25 0 10000 1000 90 1 extra",
            "CONFIG_V2 18446744073709551616 25 0 10000 1000 90 1",
            "CONFIG_V2 +1 25 0 10000 1000 90 1",
            "CONFIG_V2 one 25 0 10000 1000 90 1",
            "CONFIG_V2 1 25 0 10000 1000 90 2",
            "CONFIG_V2 1 25 10001 10000 1000 90 1",
            "CONFIG_V2 1 25 -1 10000 1000 90 1",
            "CONFIG_V2 1 25 0 10000 -1 90 1",
            "CONFIG_V2 1 25 0 10000 1000 181 1",
        ] {
            assert!(parse_config_command(command).is_none(), "{command}");
        }
    }
}
