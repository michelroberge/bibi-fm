PREFIX ?= $(HOME)/.local
BIN := $(PREFIX)/bin
LIBEXEC := $(PREFIX)/libexec/bibi

.PHONY: build release test install uninstall clean bump signing-identity ci

# Builds are signed with "bibi local code signing" when it exists (make signing-identity), so macOS keeps
# bibi's permissions (Contacts, Calendars, Reminders, Automation) across builds.
build:
	swift build
	scripts/sign.sh .build/debug/bibi

# Only the bibi product: the test runner uses @testable imports, which exist in debug builds only.
release:
	swift build -c release --product bibi
	scripts/sign.sh .build/release/bibi

signing-identity:
	scripts/make-signing-identity.sh

test:
	swift run bibi-tests

# Everything that must pass before a merge to main (.github/workflows/ci.yml runs this): a strict build where any
# warning in bibi's code fails, the tests, a release build, and an install into a scratch prefix that is then run.
CI_PREFIX := $(CURDIR)/.build/ci-prefix
ci: export BIBI_STRICT := 1
ci: export BIBI_HOME := $(CURDIR)/.build/ci-home
ci:
	swift build
	swift run bibi-tests
	rm -rf $(CI_PREFIX) $(BIBI_HOME)
	$(MAKE) install PREFIX=$(CI_PREFIX)
	test "$$($(CI_PREFIX)/bin/bibi --version)" = "bibi $$(cat VERSION)"
	$(CI_PREFIX)/bin/bibi list > /dev/null
	$(CI_PREFIX)/bin/bibi apps scan > /dev/null
	@echo "ci: all checks passed"

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
