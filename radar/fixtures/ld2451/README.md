# LD2451 protocol and fixtures

Protocol source: Hi-Link's [serial communication protocol V1.03 (2024-07-01)](https://h.hlktech.com/download/HLK-LD2451-24G/1/LD2451%20%E4%B8%B2%E5%8F%A3%E9%80%9A%E4%BF%A1%E5%8D%8F%E8%AE%AE%20V1.03.pdf), sections 1.1–1.3.
Wiring source: Hi-Link's [user manual V1.03 (2024-08-21)](https://h.hlktech.com/download/HLK-LD2451-24G/1/HLK-LD2451%E4%BD%BF%E7%94%A8%E6%89%8B%E5%86%8C_V1.03%20.pdf), sections 4.2 and 5.1.

UART uses 115200 baud, 8N1, little-endian lengths. Target frames contain
`F4 F3 F2 F1`, a two-byte payload length, payload, then `F8 F7 F6 F5`.
An empty frame has no payload. Otherwise the payload contains count and alarm
bytes followed by five bytes per target: angle (degrees offset by 128), distance
(metres), direction, speed (km/h), and SNR. Documented distance and speed ranges
are 0–100 metres and 0–120 km/h.

**Direction ambiguity:** table 9 says 1 = approaching, 0 = receding; the worked
example says the reverse. The implementation follows table 9. Confirm the sign
with a known-direction hardware capture. The example also prints `IE` where
its explanation specifies `0x1E`; the fixture uses `1E`.

## Implementation choices

We convert polar positions to x = distance × sin(angle) and y = distance ×
cos(angle), in signed 32-bit millimetres. Positive speed means approaching;
both directions are eligible for capture using absolute speed. The parser
accepts both zero-length and count-zero empty payloads, validates boundaries,
and supports the complete one-byte target count without allocating.

Initialization enables configuration, sets 100m/both directions/0km/h minimum
and a one-second alarm delay, then closes configuration. These module settings
are separate from the application's per-device capture filters. Sensitivity
and UART baud settings are left as stored on the module. Each command requires
a matching successful ACK; LD2451 initialization retries on failure.

## Fixture provenance and tests

All files in `synthetic/` are **synthetic protocol test vectors**, not captures.
`manual-three-targets.hex` transcribes the manual's example with the hex typo
corrected. `empty.hex` and `approaching.hex` exercise empty output and maximum
range/speed. Tests generate malformed streams, count limits, and split frames.

Run from the repository root, substituting your host target if needed:

```sh
cargo +stable test --manifest-path radar/Cargo.toml --target x86_64-unknown-linux-gnu --lib
cargo +stable test --manifest-path radar/Cargo.toml --target x86_64-unknown-linux-gnu --lib --no-default-features --features ld2451
```

## Physical validation still required

There are no real UART captures in this repository. Save those under `captures/`
with module firmware version, baud, wiring, mounting orientation, capture method,
and observed motion. Include empty output, motion in each direction, multiple
targets, and a trigger-worthy pass. Compare the direction byte against motion.

Use a separate 3.3V TTL receiver to sniff module TX without a second transmitter
on the line. Module TX connects to ESP GPIO18; module RX connects to ESP GPIO17.
Supply the module with 5V (>200mA capacity) and common ground. Its UART is 3.3V.
Do not confuse this UART with the Pi config connection on GPIO40/41.

See [workflows](../../../docs/workflows.md#ld2451) for build, deployment and
validation steps. Passing synthetic tests does not establish physical accuracy.
