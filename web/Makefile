FLY_APP = rshep
GCP_PROJECT = radar-a-chepers

.PHONY: bootstrap
bootstrap: ## Full first-time Fly.io setup (Tigris, secrets, deploy)
	@echo "==> Checking fly CLI..."
	@command -v fly >/dev/null 2>&1 || { echo "Error: fly CLI not installed. See https://fly.io/docs/flyctl/install/"; exit 1; }
	@echo ""
	@echo "==> Creating Fly app..."
	fly apps create $(FLY_APP) || true
	@echo ""
	@echo "==> Creating Tigris storage bucket..."
	fly storage create --app $(FLY_APP) --name $(FLY_APP)-photos
	@echo ""
	@echo "==> Tigris secrets (AWS_*) have been set automatically."
	@echo "==> Now setting remaining secrets..."
	@echo ""
	fly secrets set --app $(FLY_APP) \
		SECRET_KEY_BASE=$$(mix phx.gen.secret) \
		RADAR_API_KEY=$$(openssl rand -hex 32)
	@echo ""
	@echo "==> Deploying..."
	fly deploy --app $(FLY_APP)
	@echo ""
	@echo "==> Done! Your app is live at https://$(FLY_APP).fly.dev"
	@echo "==> API key was auto-generated. Retrieve it with: fly secrets list --app $(FLY_APP)"

.PHONY: setup-google-oauth
setup-google-oauth: ## Create Google OAuth credentials and set Fly secrets
	@read -p "Enter Client ID: " client_id && \
		read -p "Enter Client Secret: " client_secret && \
		read -p "Enter comma-separated admin emails: " emails && \
		fly secrets set --app $(FLY_APP) \
			GOOGLE_CLIENT_ID="$$client_id" \
			GOOGLE_CLIENT_SECRET="$$client_secret" \
			ADMIN_EMAILS="$$emails" && \
		echo "" && \
		echo "==> Fly secrets set. For local dev, add to your shell:" && \
		echo "    export GOOGLE_CLIENT_ID=$$client_id" && \
		echo "    export GOOGLE_CLIENT_SECRET=$$client_secret"

.PHONY: deploy
deploy: ## Deploy to Fly.io
	fly deploy --app $(FLY_APP)

.PHONY: console
console: ## Open a remote IEx console on Fly
	fly ssh console --app $(FLY_APP) -C "/app/bin/radar remote"

.PHONY: fly-seed
fly-seed: ## Push seed data to Fly.io via the API
	mix radar.fly_seed \
		--url https://$(FLY_APP).fly.dev \
		--api-key $$(fly ssh console --app $(FLY_APP) -C "printenv RADAR_API_KEY" -q)

.PHONY: fly-seed-rs
fly-seed-rs: ## Push seed data to Fly.io via the Rust uploader pipeline
	cd ../uploader && cargo run --bin seed -- \
		--api-endpoint https://$(FLY_APP).fly.dev \
		--api-key $$(fly ssh console --app $(FLY_APP) -C "printenv RADAR_API_KEY" -q)

.PHONY: fly-unseed
fly-unseed: ## Remove seed data from Fly.io
	fly ssh console --app $(FLY_APP) -C "/app/bin/radar eval Radar.Release.unseed"

.PHONY: fly-reset-db
fly-reset-db: ## Drop and recreate the prod database (DESTRUCTIVE)
	@echo "WARNING: This will destroy all data in the production database!"
	@read -p "Are you sure? [y/N] " confirm && [ "$$confirm" = "y" ] || exit 1
	fly ssh console --app $(FLY_APP) -C "rm -f /mnt/name/name.db /mnt/name/name.db-shm /mnt/name/name.db-wal"
	fly apps restart $(FLY_APP)
	@echo "==> Database reset. Migrations will run automatically on restart."

.PHONY: logs
logs: ## Tail Fly.io logs
	fly logs --app $(FLY_APP)

.PHONY: secrets
secrets: ## List Fly.io secrets
	fly secrets list --app $(FLY_APP)
