use crate::{
    command::{
        CLOSE_COMMAND_MODE, FRAME_FOOTER, FRAME_HEADER, OPEN_COMMAND_MODE, RESPONSE_FRAME_HEADER,
        SET_SINGLE_TARGET,
    },
    radar_module::{RadarModule, RadarTarget, RadarTargetFrame},
    target::{
        targets_list_header_position, Target, TargetsList, TargetsListParseError,
        TARGETS_LIST_HEADER_LENGTH, TARGETS_LIST_LENGTH,
    },
};

pub struct Rd03d;

impl RadarTarget for Target {
    fn x_mm(&self) -> i16 {
        self.x
    }

    fn y_mm(&self) -> i16 {
        self.y
    }

    fn raw_speed_cm_s(&self) -> i16 {
        self.speed.saturating_neg()
    }

    fn distance_resolution_mm(&self) -> u16 {
        self.distance_resolution
    }
}

impl RadarTargetFrame for TargetsList {
    type Target = Target;

    fn targets(&self) -> &[Option<Self::Target>] {
        self.targets()
    }
}

impl RadarModule for Rd03d {
    type TargetFrame = TargetsList;
    type ParseError = TargetsListParseError;

    fn target_frame_header_length(&self) -> usize {
        TARGETS_LIST_HEADER_LENGTH
    }

    fn target_frame_length(&self) -> usize {
        TARGETS_LIST_LENGTH
    }

    fn target_frame_header_position(&self, buffer: &[u8]) -> Option<usize> {
        targets_list_header_position(buffer)
    }

    fn parse_target_frame(&self, frame: &[u8]) -> Result<Self::TargetFrame, Self::ParseError> {
        TargetsList::try_from(frame)
    }

    fn ack_frame_header_length(&self) -> usize {
        RESPONSE_FRAME_HEADER.len()
    }

    fn ack_frame_header_position(&self, buffer: &[u8]) -> Option<(usize, usize)> {
        let command_header = buffer
            .windows(FRAME_HEADER.len())
            .position(|window| window == FRAME_HEADER)
            .map(|position| (position, FRAME_HEADER.len()));
        let alternate_header = buffer
            .windows(RESPONSE_FRAME_HEADER.len())
            .position(|window| window == RESPONSE_FRAME_HEADER)
            .map(|position| (position, RESPONSE_FRAME_HEADER.len()));

        match (command_header, alternate_header) {
            (Some(command_header), Some(alternate_header)) => {
                Some(if command_header.0 <= alternate_header.0 {
                    command_header
                } else {
                    alternate_header
                })
            }
            (Some(command_header), None) => Some(command_header),
            (None, Some(alternate_header)) => Some(alternate_header),
            (None, None) => None,
        }
    }

    fn ack_frame_footer(&self) -> &'static [u8] {
        &FRAME_FOOTER
    }

    fn init_command(&self, index: usize) -> Option<&'static [u8]> {
        match index {
            0 => Some(OPEN_COMMAND_MODE.get()),
            1 => Some(SET_SINGLE_TARGET.get()),
            2 => Some(CLOSE_COMMAND_MODE.get()),
            _ => None,
        }
    }

    fn configured_message(&self) -> &'static str {
        "Entered single target mode"
    }

    fn is_suspicious_speed(&self, raw_speed_cm_s: i16) -> bool {
        matches!(i32::from(raw_speed_cm_s).abs(), 248 | 256)
    }
}
