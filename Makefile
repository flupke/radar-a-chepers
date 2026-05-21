deploy-all: deploy-web deploy-radar

deploy-radar:
	./install.sh rshep.local

deploy-web:
	$(MAKE) -C web deploy
