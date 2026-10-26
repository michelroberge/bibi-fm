PREFIX ?= $(HOME)/.local
BIN := $(PREFIX)/bin
LIBEXEC := $(PREFIX)/libexec/bibi

.PHONY: build release test install uninstall clean bump signing-identity

# Builds are signed with "bibi local code signing" when it exists (make signing-identity), so macOS keeps
# bibi's permissions (Contacts, Calendars, Reminders, Automation) across builds.
build:
	swift build
	scripts/sign.sh .build/debug/bibi

release:
	swift build -c release
	scripts/sign.sh .build/release/bibi

signing-identity:
	scripts/make-signing-identity.sh

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

# Sets the version in VERSION and Sources/BibiCore/Version.swift: make bump V=0.4.0
bump:
	@test -n "$(V)" || (echo "usage: make bump V=x.y.z" && exit 2)
	echo "$(V)" > VERSION
	sed -i '' 's/static let version = "[^"]*"/static let version = "$(V)"/' Sources/BibiCore/Version.swift
	@echo "bibi is now $(V)"
