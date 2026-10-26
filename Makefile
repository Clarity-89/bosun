APP     := Bosun
BUNDLE  := build/$(APP).app
BINDIR   = $(shell swift build -c release --show-bin-path)

.PHONY: vendor build bundle run stop clean

# libghostty static library + headers; see scripts/fetch-ghosttykit.sh.
vendor:
	scripts/fetch-ghosttykit.sh Vendor

build: vendor
	swift build -c release --product $(APP)

# SwiftPM emits a bare binary; menu bar apps need a bundle for LSUIElement
# and a stable bundle identifier.
bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp $(BINDIR)/$(APP) $(BUNDLE)/Contents/MacOS/$(APP)
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	codesign --force --sign - $(BUNDLE)

# `open` launches through LaunchServices, so the app never inherits a
# tmux or agent-deck environment from the calling shell.
run: bundle
	open $(BUNDLE)

stop:
	-pkill -x $(APP)

clean:
	rm -rf .build build
