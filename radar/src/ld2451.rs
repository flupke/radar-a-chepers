use crate::radar_module::{RadarModule, RadarTarget, RadarTargetFrame};

pub struct Ld2451;

#[derive(Debug, defmt::Format)]
pub struct Ld2451Target;

#[derive(Debug, defmt::Format)]
pub struct Ld2451TargetFrame;

#[derive(Debug, defmt::Format)]
pub enum Ld2451ParseError {
    NotImplemented,
}

impl RadarTarget for Ld2451Target {
    fn x_mm(&self) -> i16 {
        0
    }

    fn y_mm(&self) -> i16 {
        0
    }

    fn raw_speed_cm_s(&self) -> i16 {
        0
    }

    fn distance_resolution_mm(&self) -> u16 {
        0
    }
}

impl RadarTargetFrame for Ld2451TargetFrame {
    type Target = Ld2451Target;

    fn targets(&self) -> &[Option<Self::Target>] {
        &[]
    }
}

impl RadarModule for Ld2451 {
    type TargetFrame = Ld2451TargetFrame;
    type ParseError = Ld2451ParseError;

    fn target_frame_header_length(&self) -> usize {
        1
    }

    fn target_frame_length(&self) -> usize {
        1
    }

    fn target_frame_header_position(&self, _buffer: &[u8]) -> Option<usize> {
        None
    }

    fn parse_target_frame(&self, _frame: &[u8]) -> Result<Self::TargetFrame, Self::ParseError> {
        Err(Ld2451ParseError::NotImplemented)
    }

    fn ack_frame_header_length(&self) -> usize {
        1
    }

    fn ack_frame_header_position(&self, _buffer: &[u8]) -> Option<(usize, usize)> {
        None
    }

    fn ack_frame_footer(&self) -> &'static [u8] {
        &[]
    }

    fn init_command(&self, _index: usize) -> Option<&'static [u8]> {
        None
    }

    fn configured_message(&self) -> &'static str {
        "LD2451 radar module selected; protocol not implemented"
    }

    fn is_suspicious_speed(&self, _raw_speed_cm_s: i16) -> bool {
        false
    }
}
