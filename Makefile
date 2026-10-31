APP      := Bosun
# main's bundle is the Bosun in daily use; any other branch, in this
# checkout or a worktree, builds a second bundle beside it, so a change
# under test runs as its own instance and never replaces the main one.
BRANCH   := $(shell git rev-parse --abbrev-ref HEAD)
BUNDLE   := build/$(if $(filter main,$(BRANCH)),$(APP),$(APP)-test).app
BINDIR    = $(shell swift build -c release --show-bin-path)
# The running copy of this bundle, as its command line reads.
INSTANCE := ^$(abspath $(BUNDLE))/Contents/MacOS/$(APP)$$

.PHONY: vendor build test bundle run stop stop-all clean

# libghostty static library + headers; see scripts/fetch-ghosttykit.sh.
vendor:
	scripts/fetch-ghosttykit.sh Vendor

build: vendor
	swift build -c release --product $(APP)

# BosunCoreTests only; the engine needs a GUI session, so it has no unit tests.
test: vendor
	swift test

# SwiftPM emits a bare binary; menu bar apps need a bundle for LSUIElement
# and a stable bundle identifier.
bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BINDIR)/$(APP) $(BUNDLE)/Contents/MacOS/$(APP)
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	cp Resources/AppIcon.icns $(BUNDLE)/Contents/Resources/
	codesign --force --sign - $(BUNDLE)

# `open` launches through LaunchServices, so the app never inherits a
# tmux or agent-deck environment from the calling shell. It only brings a
# running copy at this path forward, so that one quits first.
run: bundle stop
	open $(BUNDLE)

# This checkout's copy alone, and waits for it to go, so `open` sees none.
stop:
	-pkill -f '$(INSTANCE)'
	while pgrep -qf '$(INSTANCE)'; do sleep 0.2; done

# Every Bosun, whichever checkout built it.
stop-all:
	-pkill -x $(APP)

clean:
	rm -rf .build build
