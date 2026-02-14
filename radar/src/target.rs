const HEADER: [u8; 4] = [0xAA, 0xFF, 0x03, 0x00];
const FOOTER: [u8; 2] = [0x55, 0xCC];
const MAX_TARGETS: usize = 4;
const TARGET_LENGTH: usize = 8;

enum TargetParseError {
    InvalidDataLength,
    Empty,
}

#[derive(Debug, defmt::Format)]
pub struct Target {
    // X coordinate in mm
    pub x: i16,

    // Y coordinate in mm
    pub y: i16,

    // Speed in km/h
    pub speed: i16,

    // Distance resolution in mm
    pub distance_resolution: u16,
}

impl TryFrom<&[u8]> for Target {
    type Error = TargetParseError;

    fn try_from(value: &[u8]) -> Result<Self, Self::Error> {
        if value.len() != TARGET_LENGTH {
            return Err(TargetParseError::InvalidDataLength);
        }
        if value == [0x00; TARGET_LENGTH] {
            return Err(TargetParseError::Empty);
        }
        Ok(Target {
            x: parse_custom_i16(&value[0..2]),
            y: parse_custom_i16(&value[2..4]),
            speed: parse_custom_i16(&value[4..6]),
            distance_resolution: u16::from_le_bytes(value[6..8].try_into().unwrap()),
        })
    }
}

fn parse_custom_i16(slice: &[u8]) -> i16 {
    let raw = u16::from_le_bytes(slice.try_into().unwrap());
    if raw & 0x8000 != 0 {
        // If MSB is set, map 0x8000..0xFFFF to 0..32767
        (raw as i16).wrapping_add(-32768i16)
    } else {
        // If MSB is not set, map 0x0000..0x7FFF to 0..-32767
        -(raw as i16)
    }
}

#[derive(Debug, defmt::Format)]
pub struct TargetsList {
    targets: [Option<Target>; HEADER.len()],
}

impl TargetsList {
    pub fn max_speed(&self) -> i16 {
        self.targets
            .iter()
            .map(|t| t.as_ref().map_or(0, |t| -t.speed))
            .max()
            .unwrap_or(0)
    }

    pub fn targets(&self) -> &[Option<Target>] {
        &self.targets
    }
}

#[derive(Debug, defmt::Format)]
pub enum TargetsListParseError {
    DataTooShort(usize),
    InvalidHeader([u8; HEADER.len()]),
    InvalidFooter([u8; FOOTER.len()]),
}

impl TryFrom<&[u8]> for TargetsList {
    type Error = TargetsListParseError;

    fn try_from(value: &[u8]) -> Result<Self, Self::Error> {
        if value.len() < HEADER.len() + TARGET_LENGTH + FOOTER.len() {
            return Err(TargetsListParseError::DataTooShort(value.len()));
        }
        let header = value[0..HEADER.len()].try_into().unwrap();
        if header != HEADER {
            return Err(TargetsListParseError::InvalidHeader(header));
        }
        let footer = value[value.len() - FOOTER.len()..].try_into().unwrap();
        if footer != FOOTER {
            return Err(TargetsListParseError::InvalidFooter(footer));
        }

        let mut targets = [const { None }; MAX_TARGETS];
        for (i, target) in targets.iter_mut().enumerate() {
            let offset = HEADER.len() + i * TARGET_LENGTH;
            if offset + TARGET_LENGTH <= value.len() {
                *target = Target::try_from(&value[offset..offset + TARGET_LENGTH]).ok();
            } else {
                *target = None;
            }
        }

        Ok(TargetsList { targets })
    }
}
