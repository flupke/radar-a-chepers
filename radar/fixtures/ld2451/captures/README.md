# LD2451 raw capture files

Add only real LD2451 UART captures to this directory.

Expected files once hardware data is available:

- `empty.bin`
- `one-target.bin`
- `multiple-targets.bin`
- `noisy-stream.bin`
- `trigger-worthy-motion.bin`

For every `.bin` file, add a matching `.meta.md` file with capture conditions,
UART settings, wiring, initialization bytes, and expected decoded observations.

This directory intentionally has no byte captures yet.
