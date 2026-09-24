# Convenience wrappers. The real build is the Xcode project:
#   open ShadowPcAdvanced.xcodeproj   → ⌘R
CONFIG   ?= Release
XCODEGEN := ThirdParty/tools/bin/xcodegen
DERIVED  := build/DerivedData
APP      := $(DERIVED)/Build/Products/$(CONFIG)/ShadowPcAdvanced.app
# Every successful build lands next to the repo, and is then installed into
# /Applications; `make run` launches the installed copy.
DIST     ?= ../ShadowPcAdvanced.app
INSTALL  ?= /Applications/ShadowPcAdvanced.app

.PHONY: xcodegen deps project build run test clean

xcodegen:        ## build the pinned XcodeGen into ThirdParty/tools
	mkdir -p ThirdParty/src ThirdParty/tools/bin ThirdParty/tools/share/xcodegen
	[ -d ThirdParty/src/XcodeGen ] || git clone -q --depth 1 --branch 2.38.0 https://github.com/yonaskolb/XcodeGen.git ThirdParty/src/XcodeGen
	cd ThirdParty/src/XcodeGen && swift build -c release --product xcodegen
	cp ThirdParty/src/XcodeGen/.build/release/xcodegen ThirdParty/tools/bin/
	cp -R ThirdParty/src/XcodeGen/SettingPresets ThirdParty/tools/share/xcodegen/

deps:            ## build spice-client-glib + dependencies into ThirdParty/prefix
	Scripts/build-spice.sh

project:         ## (re)generate ShadowPcAdvanced.xcodeproj from project.yml
	$(XCODEGEN) generate --quiet

build: project   ## command-line build; a good build is copied to $(DIST) and installed to $(INSTALL)
	@mkdir -p build
	@if xcodebuild -project ShadowPcAdvanced.xcodeproj -scheme ShadowPcAdvanced -configuration $(CONFIG) -derivedDataPath $(DERIVED) build > build/xcodebuild.log 2>&1; then \
		rm -rf "$(DIST)" && ditto "$(APP)" "$(DIST)" && echo "BUILD SUCCEEDED → $(DIST)"; \
		rm -rf "$(INSTALL)" && ditto "$(DIST)" "$(INSTALL)" && echo "installed  → $(INSTALL)"; \
	else \
		grep -n "error:" build/xcodebuild.log | sort -u | head -40; echo "BUILD FAILED (full log: build/xcodebuild.log)"; exit 1; \
	fi

run: build       ## build, install, and launch the installed copy
	@pkill -x ShadowPcAdvanced 2>/dev/null; sleep 1; open "$(INSTALL)"

test:            ## ShadowAPI unit tests
	swift test --package-path Packages/ShadowAPI

clean:
	rm -rf build ShadowPcAdvanced.xcodeproj
