RADAR_BINARY := radar/target/xtensa-esp32s3-none-elf/debug/radar-a-chepers
API_KEY := 1234567890
API_ENDPOINT := http://localhost:4000
RADAR_SOURCES := $(shell find radar -name '*.rs')

run-uploader: $(RADAR_BINARY)
	cd uploader && \
		cargo run -- \
		--serial-port /dev/ttyACM0 \
		--api-key $(API_KEY) \
		--api-endpoint $(API_ENDPOINT) \
		--elf-path ../$(RADAR_BINARY) \
		--photos-dir ../photos

$(RADAR_BINARY): $(RADAR_SOURCES)
	cd radar && cargo espflash flash
