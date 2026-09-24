# Convenience wrappers. The real build is the Xcode project:
#   open ShadowPcAdvanced.xcodeproj   → ⌘R
CONFIG   ?= Release
XCODEGEN := ThirdParty/tools/bin/xcodegen
DERIVED  := build/DerivedData
APP      := $(DERIVED)/Build/Products/$(CONFIG)/ShadowPcAdvanced.app
# Where every successful build is installed: /Applications, and `make run`
# launches that copy.
DIST     ?= /Applications/ShadowPcAdvanced.app

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

build: project   ## command-line build; a good build is also copied to $(DIST)
	@mkdir -p build
	@if xcodebuild -project ShadowPcAdvanced.xcodeproj -scheme ShadowPcAdvanced -configuration $(CONFIG) -derivedDataPath $(DERIVED) build > build/xcodebuild.log 2>&1; then \
		rm -rf "$(DIST)" && ditto "$(APP)" "$(DIST)" && echo "BUILD SUCCEEDED → $(DIST)"; \
	else \
		grep -n "error:" build/xcodebuild.log | sort -u | head -40; echo "BUILD FAILED (full log: build/xcodebuild.log)"; exit 1; \
	fi

run: build       ## build, install to $(DIST) and launch it from there
	@pkill -x ShadowPcAdvanced 2>/dev/null; sleep 1; open "$(DIST)"

test:            ## ShadowAPI unit tests
	swift test --package-path Packages/ShadowAPI

clean:
	rm -rf build ShadowPcAdvanced.xcodeproj
