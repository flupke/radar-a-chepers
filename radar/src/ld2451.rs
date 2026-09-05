//! Hi-Link LD2451 protocol V1.03. See fixtures/ld2451/README.md for provenance
//! and the manufacturer's contradictory direction example.
use crate::radar_module::{
    RadarModule, RadarTarget, RadarTargetFrame, MAX_TARGETS_PER_FRAME, MAX_TARGET_FRAME_LENGTH,
};

const HEADER: [u8; 4] = [0xF4, 0xF3, 0xF2, 0xF1];
const FOOTER: [u8; 4] = [0xF8, 0xF7, 0xF6, 0xF5];
const ACK_HEADER: [u8; 4] = [0xFD, 0xFC, 0xFB, 0xFA];
const ACK_FOOTER: [u8; 4] = [0x04, 0x03, 0x02, 0x01];
// The count occupies one byte; do not impose an undocumented three-target limit.
const MAX_TARGETS: usize = MAX_TARGETS_PER_FRAME;
const OPEN_CONFIG: &[u8] = &[0xFD, 0xFC, 0xFB, 0xFA, 4, 0, 0xFF, 0, 1, 0, 4, 3, 2, 1];
// Report both directions over the full range. Application capture filters stay
// on the ESP, so module-side filtering cannot hide otherwise eligible motion.
const SET_DETECTION: &[u8] = &[0xFD, 0xFC, 0xFB, 0xFA, 6, 0, 2, 0, 100, 2, 0, 1, 4, 3, 2, 1];
const CLOSE_CONFIG: &[u8] = &[0xFD, 0xFC, 0xFB, 0xFA, 2, 0, 0xFE, 0, 4, 3, 2, 1];

pub struct Ld2451;

#[derive(Clone, Copy, Debug, defmt::Format)]
pub struct Ld2451Target {
    pub angle_degrees: i16,
    pub distance_m: u8,
    pub direction: u8,
    pub speed_kmh: u8,
    pub snr: u8,
    x_mm: i32,
    y_mm: i32,
}

#[derive(Debug, defmt::Format)]
pub struct Ld2451TargetFrame {
    pub approaching_alarm: bool,
    targets: [Option<Ld2451Target>; MAX_TARGETS],
    count: usize,
}

#[derive(Debug, PartialEq, Eq, defmt::Format)]
pub enum Ld2451ParseError {
    InvalidLength,
    InvalidHeader,
    InvalidFooter,
    InvalidTarget,
    InvalidAlarm,
}

impl RadarTarget for Ld2451Target {
    fn x_mm(&self) -> i32 {
        self.x_mm
    }

    fn y_mm(&self) -> i32 {
        self.y_mm
    }

    fn raw_speed_cm_s(&self) -> i16 {
        let speed = ((i32::from(self.speed_kmh) * 1000 + 18) / 36) as i16;
        // V1.03 table 9: 1 = approaching, 0 = receding. Positive is approaching
        // in our event contract. Capture decisions use the absolute speed.
        if self.direction == 1 {
            speed
        } else {
            -speed
        }
    }

    fn distance_resolution_mm(&self) -> u16 {
        1000
    }
}

impl RadarTargetFrame for Ld2451TargetFrame {
    type Target = Ld2451Target;

    fn targets(&self) -> &[Option<Self::Target>] {
        &self.targets[..self.count]
    }
}

impl RadarModule for Ld2451 {
    type TargetFrame = Ld2451TargetFrame;
    type ParseError = Ld2451ParseError;

    fn name(&self) -> &'static str {
        "ld2451"
    }

    fn baud_rate(&self) -> u32 {
        115_200
    }

    fn target_frame_header_length(&self) -> usize {
        HEADER.len()
    }

    fn target_frame_length(&self, buffer: &[u8]) -> Result<Option<usize>, Self::ParseError> {
        if buffer.len() < 6 {
            return Ok(None);
        }
        if buffer[..4] != HEADER {
            return Err(Ld2451ParseError::InvalidHeader);
        }
        let payload = u16::from_le_bytes([buffer[4], buffer[5]]) as usize;
        if payload != 0 && (payload < 2 || (payload - 2) % 5 != 0) {
            return Err(Ld2451ParseError::InvalidLength);
        }
        if payload + 10 > MAX_TARGET_FRAME_LENGTH {
            return Err(Ld2451ParseError::InvalidLength);
        }
        if payload > 0 && buffer.len() >= 7 && payload != 2 + usize::from(buffer[6]) * 5 {
            return Err(Ld2451ParseError::InvalidLength);
        }
        Ok(Some(payload + 10))
    }

    fn target_frame_header_position(&self, buffer: &[u8]) -> Option<usize> {
        buffer
            .windows(HEADER.len())
            .position(|bytes| bytes == HEADER)
    }

    fn parse_target_frame(&self, frame: &[u8]) -> Result<Self::TargetFrame, Self::ParseError> {
        if self.target_frame_length(frame)? != Some(frame.len()) {
            return Err(Ld2451ParseError::InvalidLength);
        }
        if frame[frame.len() - 4..] != FOOTER {
            return Err(Ld2451ParseError::InvalidFooter);
        }
        let mut result = Ld2451TargetFrame {
            approaching_alarm: false,
            targets: [None; MAX_TARGETS],
            count: 0,
        };
        if frame.len() == 10 {
            return Ok(result);
        }
        if frame[7] > 1 {
            return Err(Ld2451ParseError::InvalidAlarm);
        }
        result.approaching_alarm = frame[7] == 1;
        result.count = usize::from(frame[6]);
        for (target, bytes) in result.targets[..result.count]
            .iter_mut()
            .zip(frame[8..frame.len() - 4].chunks_exact(5))
        {
            let angle_degrees = i16::from(bytes[0]) - 128;
            if bytes[1] > 100 || bytes[2] > 1 || bytes[3] > 120 {
                return Err(Ld2451ParseError::InvalidTarget);
            }
            let angle = f32::from(angle_degrees) * core::f32::consts::PI / 180.0;
            let distance_mm = f32::from(bytes[1]) * 1000.0;
            *target = Some(Ld2451Target {
                angle_degrees,
                distance_m: bytes[1],
                direction: bytes[2],
                speed_kmh: bytes[3],
                snr: bytes[4],
                x_mm: libm::roundf(distance_mm * libm::sinf(angle)) as i32,
                y_mm: libm::roundf(distance_mm * libm::cosf(angle)) as i32,
            });
        }
        Ok(result)
    }

    fn ack_frame_header_length(&self) -> usize {
        ACK_HEADER.len()
    }

    fn ack_frame_header_position(&self, buffer: &[u8]) -> Option<(usize, usize)> {
        buffer
            .windows(ACK_HEADER.len())
            .position(|bytes| bytes == ACK_HEADER)
            .map(|position| (position, ACK_HEADER.len()))
    }

    fn ack_frame_footer(&self) -> &'static [u8] {
        &ACK_FOOTER
    }

    fn init_command(&self, index: usize) -> Option<&'static [u8]> {
        [OPEN_CONFIG, SET_DETECTION, CLOSE_CONFIG]
            .get(index)
            .copied()
    }

    fn configured_message(&self) -> &'static str {
        "LD2451 configured: 100m, both directions, minimum speed 0km/h"
    }

    fn is_suspicious_speed(&self, _raw_speed_cm_s: i16) -> bool {
        false
    }

    fn log_frame_details(&self, frame: &Self::TargetFrame) {
        defmt::info!("LD2451 alarm: approaching={}", frame.approaching_alarm);
        for target in frame.targets().iter().flatten() {
            defmt::info!(
                "LD2451 raw target: angle={}deg distance={}m direction={} speed={}km/h snr={}",
                target.angle_degrees,
                target.distance_m,
                target.direction,
                target.speed_kmh,
                target.snr
            );
        }
    }
}

#[cfg(test)]
mod tests {
    extern crate std;
    use super::*;
    use crate::stream::TargetStream;
    use std::vec::Vec;

    fn fixture(text: &str) -> Vec<u8> {
        text.split_whitespace()
            .map(|byte| u8::from_str_radix(byte, 16).unwrap())
            .collect()
    }

    fn empty() -> Vec<u8> {
        fixture(include_str!("../fixtures/ld2451/synthetic/empty.hex"))
    }

    fn approaching() -> Vec<u8> {
        fixture(include_str!("../fixtures/ld2451/synthetic/approaching.hex"))
    }

    #[test]
    fn parses_both_empty_encodings() {
        assert_eq!(
            Ld2451.parse_target_frame(&empty()).unwrap().target_count(),
            0
        );
        let frame = [0xF4, 0xF3, 0xF2, 0xF1, 2, 0, 0, 0, 0xF8, 0xF7, 0xF6, 0xF5];
        assert_eq!(Ld2451.parse_target_frame(&frame).unwrap().target_count(), 0);
    }

    #[test]
    fn represents_full_range_and_speed_without_overflow() {
        let frame = Ld2451.parse_target_frame(&approaching()).unwrap();
        let target = frame.targets()[0].as_ref().unwrap();
        assert!(frame.approaching_alarm);
        assert_eq!((target.x_mm(), target.y_mm()), (0, 100_000));
        assert_eq!(target.raw_speed_cm_s(), 3333);
        assert_eq!(target.distance_resolution_mm(), 1000);
        assert_eq!(target.snr, 255);
        let speed = Ld2451.interpret_speed(target.raw_speed_cm_s(), 25);
        assert_eq!(speed.effective_kmh, 120);
        assert!(!speed.suspicious);
    }

    #[test]
    fn converts_manual_polar_targets_using_current_direction_table() {
        let bytes = fixture(include_str!(
            "../fixtures/ld2451/synthetic/manual-three-targets.hex"
        ));
        let frame = Ld2451.parse_target_frame(&bytes).unwrap();
        assert_eq!(frame.target_count(), 3);
        let targets = frame.targets();
        let first = targets[0].as_ref().unwrap();
        assert_eq!((first.x_mm(), first.y_mm()), (6946, 39392));
        assert_eq!(first.raw_speed_cm_s(), -1667);
        let second = targets[1].as_ref().unwrap();
        assert_eq!((second.x_mm(), second.y_mm()), (5209, 29544));
        assert_eq!(second.raw_speed_cm_s(), 1667);
        let third = targets[2].as_ref().unwrap();
        assert_eq!((third.x_mm(), third.y_mm()), (-16497, 93557));
        assert_eq!(third.raw_speed_cm_s(), -1667);
    }

    #[test]
    fn validates_frame_boundaries_count_and_target_fields() {
        let valid = approaching();
        for len in 0..valid.len() {
            assert!(
                Ld2451.parse_target_frame(&valid[..len]).is_err(),
                "length {len}"
            );
        }
        for (index, value) in [
            (0, 0),
            (4, 1),
            (5, 255),
            (6, 2),
            (7, 2),
            (9, 101),
            (10, 2),
            (11, 121),
            (16, 0),
        ] {
            let mut corrupt = valid.clone();
            corrupt[index] = value;
            assert!(
                Ld2451.parse_target_frame(&corrupt).is_err(),
                "index {index}"
            );
        }
        let mut extra = valid.clone();
        extra.push(0);
        assert!(Ld2451.parse_target_frame(&extra).is_err());
    }

    #[test]
    fn stream_recovers_from_noise_bad_lengths_and_bad_footers() {
        let valid = approaching();
        let mut noise = std::vec![0xFD, 0xFC, 0xFB, 0xFA, 4, 0, 2, 1, 0, 0, 4, 3, 2, 1];
        noise.extend([0xF4, 0xF3, 0xF2, 0xF1, 0xFF, 0xFF]);
        noise.extend([0xF4, 0xF3, 0xF2, 0xF1, 7, 0, 255]);
        let mut bad_footer = valid.clone();
        *bad_footer.last_mut().unwrap() = 0;
        noise.extend(bad_footer);
        noise.extend(&valid);
        noise.extend(empty());
        noise.extend(&valid);
        let mut stream = TargetStream::new();
        let mut counts = Vec::new();
        // Feeding individual bytes covers headers, lengths and payloads split
        // at every UART boundary, including adjacent frames in one read.
        for byte in noise {
            stream.push(byte);
            while let Some((frame, raw)) = stream.next_frame(&Ld2451) {
                assert!(Ld2451.parse_target_frame(raw).is_ok());
                counts.push(frame.target_count());
            }
        }
        assert_eq!(counts, [1, 0, 1]);
    }

    #[test]
    fn retains_valid_header_inside_a_corrupted_frame() {
        let mut bytes = approaching()[..8].to_vec();
        bytes.extend(empty());
        let mut stream = TargetStream::new();
        let mut count = 0;
        for byte in bytes {
            stream.push(byte);
            while let Some((frame, _)) = stream.next_frame(&Ld2451) {
                assert_eq!(frame.target_count(), 0);
                count += 1;
            }
        }
        assert_eq!(count, 1);
    }

    #[test]
    fn handles_the_full_wire_target_count_and_recovers_after_truncation() {
        let payload = 2 + 255 * 5;
        let mut bytes = HEADER.to_vec();
        bytes.extend((payload as u16).to_le_bytes());
        bytes.extend([255, 1]);
        for _ in 0..255 {
            bytes.extend([128, 100, 1, 120, 255]);
        }
        bytes.extend(FOOTER);
        let mut stream = TargetStream::new();
        for byte in &bytes[..bytes.len() - 1] {
            stream.push(*byte);
            assert!(stream.next_frame(&Ld2451).is_none());
        }
        stream.push(*bytes.last().unwrap());
        assert_eq!(stream.next_frame(&Ld2451).unwrap().0.target_count(), 255);
        for byte in &bytes[..8] {
            stream.push(*byte);
            assert!(stream.next_frame(&Ld2451).is_none());
        }
        stream.clear();
        for byte in empty() {
            stream.push(byte);
        }
        assert_eq!(stream.next_frame(&Ld2451).unwrap().0.target_count(), 0);
    }

    #[test]
    fn init_selects_both_directions_without_rd03d_commands_or_sentinels() {
        assert_eq!(Ld2451.baud_rate(), 115_200);
        assert!(!Ld2451.allow_unacknowledged_stream());
        assert_eq!(&Ld2451.init_command(0).unwrap()[6..10], &[255, 0, 1, 0]);
        assert_eq!(
            &Ld2451.init_command(1).unwrap()[6..12],
            &[2, 0, 100, 2, 0, 1]
        );
        assert_eq!(&Ld2451.init_command(2).unwrap()[6..8], &[254, 0]);
        assert!(Ld2451.init_command(3).is_none());
        for speed in [248, 256, -248, -256] {
            assert!(!Ld2451.is_suspicious_speed(speed));
            assert_eq!(Ld2451.interpret_speed(speed, 25).effective_kmh, 9);
        }
    }
}
