//! Bounded UART framing shared by both modules and exercised by host tests.
use crate::radar_module::{RadarModule, MAX_TARGET_FRAME_LENGTH};

const CAPACITY: usize = MAX_TARGET_FRAME_LENGTH;

pub struct TargetStream {
    buffer: [u8; CAPACITY],
    len: usize,
    consumed: usize,
}

impl TargetStream {
    pub const fn new() -> Self {
        Self {
            buffer: [0; CAPACITY],
            len: 0,
            consumed: 0,
        }
    }

    pub fn clear(&mut self) {
        self.len = 0;
        self.consumed = 0;
    }

    /// Feed a byte, then drain next_frame before feeding another.
    pub fn push(&mut self, byte: u8) {
        self.discard(self.consumed);
        self.consumed = 0;
        if self.len == CAPACITY {
            self.discard(1);
        }
        self.buffer[self.len] = byte;
        self.len += 1;
    }

    fn discard(&mut self, count: usize) {
        self.buffer.copy_within(count..self.len, 0);
        self.len -= count;
    }

    /// Invalid candidates discard only one byte so an embedded valid header
    /// survives corruption. Incomplete headers and frames remain buffered.
    pub fn next_frame<M: RadarModule>(&mut self, radar: &M) -> Option<(M::TargetFrame, &[u8])> {
        self.discard(self.consumed);
        self.consumed = 0;
        loop {
            match radar.target_frame_header_position(&self.buffer[..self.len]) {
                Some(offset) => self.discard(offset),
                None => {
                    let keep = self.len.min(radar.target_frame_header_length() - 1);
                    self.discard(self.len - keep);
                    return None;
                }
            }
            let length = match radar.target_frame_length(&self.buffer[..self.len]) {
                Ok(Some(length)) if length <= CAPACITY && length > 0 => length,
                Ok(None) => return None,
                _ => {
                    self.discard(1);
                    continue;
                }
            };
            if self.len < length {
                return None;
            }
            match radar.parse_target_frame(&self.buffer[..length]) {
                Ok(frame) => {
                    self.consumed = length;
                    return Some((frame, &self.buffer[..length]));
                }
                Err(_) => self.discard(1),
            }
        }
    }
}

/// The payload starts after header + length. A stale ACK for another command
/// must not acknowledge the current command; nonzero status means failure.
pub fn command_ack_status(payload: &[u8], command_word: &[u8]) -> Option<bool> {
    if payload.len() < 4
        || command_word.len() != 2
        || payload[0] != command_word[0]
        || payload[1] != (command_word[1] | 1)
    {
        return None;
    }
    Some(payload[2] == 0 && payload[3] == 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn acknowledgements_must_match_command_and_succeed() {
        assert_eq!(
            command_ack_status(&[255, 1, 0, 0, 1, 0, 0, 0], &[255, 0]),
            Some(true)
        );
        assert_eq!(command_ack_status(&[2, 1, 0, 0], &[2, 0]), Some(true));
        assert_eq!(command_ack_status(&[2, 1, 1, 0], &[2, 0]), Some(false));
        assert_eq!(command_ack_status(&[2, 1, 0, 1], &[2, 0]), Some(false));
        assert_eq!(command_ack_status(&[255, 1, 0, 0], &[2, 0]), None);
        assert_eq!(command_ack_status(&[2, 0, 0, 0], &[2, 0]), None);
        assert_eq!(command_ack_status(&[2, 1], &[2, 0]), None);
        assert_eq!(command_ack_status(&[], &[]), None);
    }
}
