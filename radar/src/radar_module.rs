pub const MAX_TARGET_FRAME_HEADER_LENGTH: usize = 8;
pub const MAX_ACK_FRAME_HEADER_LENGTH: usize = 8;

#[derive(Clone, Copy, PartialEq, Eq, defmt::Format)]
pub enum RadarFrameState {
    Empty,
    Targets,
    SuspiciousSpeed,
}

impl RadarFrameState {
    pub fn label(self) -> &'static str {
        match self {
            Self::Empty => "empty",
            Self::Targets => "targets",
            Self::SuspiciousSpeed => "suspicious-speed",
        }
    }
}

#[derive(Clone, Copy)]
pub struct SpeedInterpretation {
    pub effective_kmh: i16,
    pub suspicious: bool,
}

pub trait RadarTarget {
    fn x_mm(&self) -> i16;
    fn y_mm(&self) -> i16;
    fn raw_speed_cm_s(&self) -> i16;
    fn distance_resolution_mm(&self) -> u16;
}

pub trait RadarTargetFrame {
    type Target: RadarTarget;

    fn targets(&self) -> &[Option<Self::Target>];

    fn target_count(&self) -> usize {
        self.targets()
            .iter()
            .filter(|target| target.is_some())
            .count()
    }
}

pub trait RadarModule {
    type TargetFrame: RadarTargetFrame;
    type ParseError: defmt::Format;

    fn target_frame_header_length(&self) -> usize;
    fn target_frame_length(&self) -> usize;
    fn target_frame_header_position(&self, buffer: &[u8]) -> Option<usize>;
    fn parse_target_frame(&self, frame: &[u8]) -> Result<Self::TargetFrame, Self::ParseError>;

    fn ack_frame_header_length(&self) -> usize;
    fn ack_frame_header_position(&self, buffer: &[u8]) -> Option<(usize, usize)>;
    fn ack_frame_footer(&self) -> &'static [u8];

    fn init_command(&self, index: usize) -> Option<&'static [u8]>;
    fn configured_message(&self) -> &'static str;

    fn is_suspicious_speed(&self, raw_speed_cm_s: i16) -> bool;

    fn interpret_speed(
        &self,
        raw_speed_cm_s: i16,
        authorized_speed_kmh: i16,
    ) -> SpeedInterpretation {
        let raw_speed_kmh = raw_speed_cm_s_to_abs_kmh(raw_speed_cm_s);
        let suspicious = self.is_suspicious_speed(raw_speed_cm_s);
        let effective_kmh = if suspicious {
            raw_speed_kmh.max(authorized_speed_kmh.saturating_add(1))
        } else {
            raw_speed_kmh
        };

        SpeedInterpretation {
            effective_kmh,
            suspicious,
        }
    }

    fn frame_diagnostic_state(&self, frame: &Self::TargetFrame) -> RadarFrameState {
        let mut has_targets = false;

        for target in frame.targets().iter().flatten() {
            has_targets = true;
            if self.is_suspicious_speed(target.raw_speed_cm_s()) {
                return RadarFrameState::SuspiciousSpeed;
            }
        }

        if has_targets {
            RadarFrameState::Targets
        } else {
            RadarFrameState::Empty
        }
    }
}

fn raw_speed_cm_s_to_abs_kmh(raw_speed_cm_s: i16) -> i16 {
    ((i32::from(raw_speed_cm_s).abs() * 36 + 500) / 1000) as i16
}
