use core::ops::Deref;

use once_cell::sync::Lazy;

pub const FRAME_HEADER: [u8; 4] = [0xFD, 0xFC, 0xFB, 0xFA];
pub const FRAME_FOOTER: [u8; 4] = [0x04, 0x03, 0x02, 0x01];
pub static OPEN_COMMAND_MODE: Lazy<Frame> = Lazy::new(|| Frame::new(&[0xFF, 0x00, 0x01, 0x00]));
pub static CLOSE_COMMAND_MODE: Lazy<Frame> = Lazy::new(|| Frame::new(&[0xFE, 0x00]));
pub static SET_SINGLE_TARGET: Lazy<Frame> = Lazy::new(|| Frame::new(&[0x80, 0x00]));
pub static SET_MULTI_TARGET: Lazy<Frame> = Lazy::new(|| Frame::new(&[0x90, 0x00]));

pub struct Frame {
    // General frame structure:
    //   header(4) + data_length(2) + data(N) + footer(4)
    //
    // Biggest data length is 8 so max size is 18 bytes
    buffer: [u8; 18],
    length: usize,
}

impl Frame {
    fn new(data: &[u8]) -> Self {
        assert!(data.len() <= 8);
        let mut buffer = [0u8; 18];
        buffer[0..4].copy_from_slice(&FRAME_HEADER);
        buffer[4..6].copy_from_slice(&(data.len() as u16).to_le_bytes());
        buffer[6..6 + data.len()].copy_from_slice(data);
        let footer_start = 6 + data.len();
        buffer[footer_start..footer_start + 4].copy_from_slice(&FRAME_FOOTER);
        Self {
            buffer,
            length: footer_start + 4,
        }
    }
}

impl Deref for Frame {
    type Target = [u8];

    fn deref(&self) -> &Self::Target {
        self.buffer[..self.length].as_ref()
    }
}
