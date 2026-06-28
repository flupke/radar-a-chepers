# LD2451 protocol capture fixtures

This directory is reserved for real LD2451 UART captures and protocol notes.
No real LD2451 byte captures are currently present in this repository.

Do not add hand-written or guessed UART bytes here. Parser tests that need
synthetic malformed streams should label them as synthetic in the test itself,
not as hardware captures.

## Local search result

Searched the repository for existing LD2451/HLK captures, logs, serial dumps,
and protocol notes. The only LD2451-specific content found was the placeholder
firmware module added for feature selection:

- `radar/src/ld2451.rs`

No `.bin`, `.hex`, `.csv`, `.log`, Saleae, sigrok, or raw UART fixture files
for LD2451 were found.

## Known project wiring

These values come from the current ESP firmware and repo workflow docs, not
from an LD2451 capture:

- Radar UART on ESP32-S3: `UART1`
- ESP radar TX: `GPIO17`
- ESP radar RX: `GPIO18`
- ESP config UART from Raspberry Pi: `UART2`, Pi `/dev/serial0`, ESP RX
  `GPIO40`, ESP TX `GPIO41`
- Camera trigger output: `GPIO42`
- Current RD03-D firmware baud: `256000`; do not assume this is correct for
  LD2451.

## Missing protocol facts

These must be confirmed from the LD2451 datasheet or from real captures before
implementing the parser:

| Fact | Current status |
| --- | --- |
| LD2451 UART baud rate | Unknown; capture metadata must record the exact baud. |
| Passive stream vs command mode | Unknown; capture boot/passive output before sending commands. |
| Required initialization commands | Unknown; record all bytes sent to the module before each capture. |
| Target frame header/footer | Unknown; derive only from real captures or vendor protocol docs. |
| Frame length and checksum rules | Unknown. |
| Coordinate units and axes | Unknown; record physical target positions with captures. |
| Speed units and sign convention | Unknown; capture approaching and receding motion with notes. |
| Multiple target support and slot count | Unknown; capture two-person scenarios and document observed output. |

## Required fixture coverage

When hardware captures are available, add raw byte files under `captures/` with
matching `.meta.md` files. Use these scenario names unless the parser task has
a stronger naming convention:

| Scenario | Capture file | Purpose |
| --- | --- | --- |
| Empty frame | `captures/empty.bin` | Valid stream while the field of view is empty. |
| One target | `captures/one-target.bin` | One person at measured positions. |
| Multiple targets | `captures/multiple-targets.bin` | Two or more people, if supported by the module. |
| Malformed/noisy stream | `captures/noisy-stream.bin` | Real startup, hot-plug, partial, or noise bytes. |
| Trigger-worthy motion | `captures/trigger-worthy-motion.bin` | Motion that should exceed the configured speed threshold. |

Each metadata file should include:

- Capture date, operator, module marking, and firmware/app version if visible.
- Wiring and power supply voltage.
- UART baud, data bits, parity, stop bits, and logic level.
- Capture tool and sample rate.
- Exact bytes transmitted to the module before and during capture.
- Physical scenario: target count, approximate positions, movement direction,
  and whether the motion should trigger the camera.
- Expected decoded observations, if known after manual decoding.

## Repeatable capture procedure

1. Wire the LD2451 with common ground and 3.3 V TTL UART levels. Sniff module
   TX on the ESP `GPIO18` side or connect a USB UART/logic analyzer directly
   to the module TX. If sending commands, also capture ESP/module RX.
2. Determine the real UART baud from vendor docs, module tooling, or logic
   analyzer autobaud. Record the baud in metadata. Do not reuse the RD03-D
   `256000` baud without confirmation.
3. Capture at least 10 seconds immediately after module power-up with no
   firmware init commands. Save this as the passive boot/empty baseline if it
   produces valid frames.
4. If the module needs initialization, send the minimum documented commands and
   capture both TX and RX bytes. Save the command transcript in metadata.
5. Capture the five required scenarios from the coverage table. Keep raw files
   unmodified; trim only by copying to a new file and documenting the offset.
6. For one-target and trigger-worthy captures, note whether the person is
   approaching or receding from the radar and include approximate distance and
   lateral offset in millimeters.
7. For multiple-target captures, note if the module emits only one target. That
   is valid evidence if LD2451 does not support multiple simultaneous targets.
8. Add parser tests against the raw capture files only after the frame shape,
   units, and sign conventions are confirmed.

## Current blocker

Full fixture coverage is blocked on real LD2451 UART captures or an authoritative
LD2451 protocol document. Until then, the parser task should treat every protocol
detail above as unknown rather than borrowing RD03-D or LD2450 assumptions.
