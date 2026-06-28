RADAR_DEVICE ?= rd03d

deploy-all: deploy-web deploy-radar

deploy-radar:
	./install.sh --radar-device $(RADAR_DEVICE) rshep.local

deploy-web:
	$(MAKE) -C web deploy
