#[cfg(all(feature = "ld2451", not(feature = "rd03d")))]
pub use crate::ld2451::Ld2451 as SelectedRadarModule;
#[cfg(all(feature = "rd03d", not(feature = "ld2451")))]
pub use crate::rd03d::Rd03d as SelectedRadarModule;

#[cfg(any(
    all(feature = "rd03d", not(feature = "ld2451")),
    all(feature = "ld2451", not(feature = "rd03d"))
))]
pub fn selected_radar_module() -> SelectedRadarModule {
    SelectedRadarModule
}
