#![no_std]
#[cfg(all(feature = "rd03d", feature = "ld2451"))]
compile_error!(
    "radar module features are mutually exclusive; enable exactly one of `rd03d` or `ld2451`"
);
#[cfg(not(any(feature = "rd03d", feature = "ld2451")))]
compile_error!("no radar module feature selected; enable exactly one of `rd03d` or `ld2451`");

pub mod command;
#[cfg(feature = "ld2451")]
pub mod ld2451;
pub mod radar_module;
#[cfg(feature = "rd03d")]
pub mod rd03d;
pub mod selected_radar;
pub mod target;
