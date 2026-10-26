PREFIX ?= $(HOME)/.local
BIN := $(PREFIX)/bin
LIBEXEC := $(PREFIX)/libexec/bibi

.PHONY: build release test install uninstall clean

build:
	swift build

release:
	swift build -c release

test:
	swift run bibi-tests

# The binary needs its resource bundle (web UI files) next to it, so both go to libexec and bin gets a symlink.
install: release
	mkdir -p $(BIN) $(LIBEXEC)
	cp .build/release/bibi $(LIBEXEC)/bibi
	rm -rf $(LIBEXEC)/bibi_BibiWeb.bundle
	cp -R .build/release/bibi_BibiWeb.bundle $(LIBEXEC)/
	ln -sf $(LIBEXEC)/bibi $(BIN)/bibi
	@echo "Installed $(BIN)/bibi (make sure $(BIN) is on your PATH)"

uninstall:
	rm -f $(BIN)/bibi
	rm -rf $(LIBEXEC)

clean:
	swift package clean
