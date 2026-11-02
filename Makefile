APP      := Bosun
# main's bundle is the Bosun in daily use; anywhere else, another branch
# or a worktree, builds a second bundle beside it, so a change under test
# runs as its own instance and never replaces the main one. A worktree on
# main counts as anywhere else: `--git-dir` is `.git` only in the main
# checkout.
BRANCH   := $(shell git rev-parse --abbrev-ref HEAD)
ON_MAIN  := $(and $(filter main,$(BRANCH)),$(filter .git,$(shell git rev-parse --git-dir)))
BUNDLE   := build/$(if $(ON_MAIN),$(APP),$(APP)-test).app
# The test copy is another app to macOS, so a notification click, an
# `open -b`, or a default saved by one copy never reaches the other.
BUNDLE_ID   := $(if $(ON_MAIN),com.bosun.$(APP),com.bosun.$(APP)-test)
BUNDLE_NAME := $(if $(ON_MAIN),$(APP),$(APP) Test)
BINDIR    = $(shell swift build -c release --show-bin-path)
# The running copy of this bundle, as its command line reads.
INSTANCE := ^$(abspath $(BUNDLE))/Contents/MacOS/$(APP)$$

.PHONY: vendor build test integration bundle run quit stop stop-all clean

# libghostty static library + headers; see scripts/fetch-ghosttykit.sh.
vendor:
	scripts/fetch-ghosttykit.sh Vendor

build: vendor
	swift build -c release --product $(APP)

# Unit tests: BosunCore, and the app's model on a fake agent-deck. The
# engine needs a GUI session, so the terminal has none.
test: vendor
	swift test

# The real agent-deck and tmux, in a sandbox HOME on a private tmux
# server; needs both installed, so CI does not run it.
integration: vendor
	BOSUN_INTEGRATION=1 swift test --filter AgentDeckIntegrationTests

# SwiftPM emits a bare binary; menu bar apps need a bundle for LSUIElement
# and a stable bundle identifier.
bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BINDIR)/$(APP) $(BUNDLE)/Contents/MacOS/$(APP)
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	plutil -replace CFBundleIdentifier -string $(BUNDLE_ID) $(BUNDLE)/Contents/Info.plist
	plutil -replace CFBundleName -string "$(BUNDLE_NAME)" $(BUNDLE)/Contents/Info.plist
	cp Resources/AppIcon.icns $(BUNDLE)/Contents/Resources/
	codesign --force --sign - $(BUNDLE)

# `open` hands the app the calling shell's environment, tmux's and an
# agent's included; the app drops what is not a terminal's at launch
# (`LaunchEnvironment`). `open` only brings a running copy at this path
# forward, so that one quits first.
run: bundle quit
	open $(BUNDLE)

# This checkout's copy alone, and waits for it to go, so `open` sees none.
quit:
	-pkill -f '$(INSTANCE)'
	while pgrep -qf '$(INSTANCE)'; do sleep 0.2; done

# A test copy's bundle goes with it: a notification it left in
# Notification Center would otherwise launch it again when clicked.
stop: quit
	$(if $(ON_MAIN),,rm -rf $(BUNDLE))

# Every Bosun, whichever checkout built it.
stop-all:
	-pkill -x $(APP)

clean:
	rm -rf .build build
