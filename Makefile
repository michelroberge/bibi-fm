PREFIX ?= $(HOME)/.local/bin

.PHONY: install uninstall test

install:
	mkdir -p $(PREFIX)
	ln -sf $(CURDIR)/bin/bibi $(PREFIX)/bibi
	@echo "Installed $(PREFIX)/bibi (make sure $(PREFIX) is on your PATH)"

uninstall:
	rm -f $(PREFIX)/bibi

test:
	python3 -m unittest discover -s tests -v
