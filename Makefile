update-all:
	./install.sh
	$(MAKE) -C web deploy
