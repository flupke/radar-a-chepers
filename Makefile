RADAR_BINARY := radar/target/xtensa-esp32s3-none-elf/debug/radar-a-chepers
API_KEY := radar-dev-key
API_ENDPOINT := http://localhost:4000
FLY_APP := rshep
RADAR_SOURCES := $(shell find radar -name '*.rs')

.PHONY: run-web
run-web:
	@if [ -z "$${GOOGLE_CLIENT_ID:-}" ] || [ -z "$${GOOGLE_CLIENT_SECRET:-}" ]; then \
		echo "==> Fetching Google OAuth secrets from Fly ($(FLY_APP))..."; \
		export GOOGLE_CLIENT_ID=$$(fly ssh console --app "$(FLY_APP)" -C "printenv GOOGLE_CLIENT_ID" -q); \
		export GOOGLE_CLIENT_SECRET=$$(fly ssh console --app "$(FLY_APP)" -C "printenv GOOGLE_CLIENT_SECRET" -q); \
	fi; \
	cd web || exit 1; \
	mix ecto.create --quiet 2>/dev/null || true; \
	mix ecto.migrate --quiet; \
	mix phx.server

run-uploader: $(RADAR_BINARY)
	cd uploader && \
		cargo run --bin uploader -- \
		--serial-port /dev/ttyACM0 \
		--api-key $(API_KEY) \
		--api-endpoint $(API_ENDPOINT) \
		--elf-path ../$(RADAR_BINARY) \
		--infractions-dir ../infractions

integration-test:
	bin/integration-test

$(RADAR_BINARY): $(RADAR_SOURCES)
	cd radar && cargo espflash flash
