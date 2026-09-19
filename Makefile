# Convenience wrappers. The real build is the Xcode project:
#   open FunkyShadow.xcodeproj   → ⌘R
CONFIG   ?= Release
XCODEGEN := ThirdParty/tools/bin/xcodegen
DERIVED  := build/DerivedData
APP      := $(DERIVED)/Build/Products/$(CONFIG)/FunkyShadow.app

.PHONY: xcodegen deps project build run test clean

xcodegen:        ## build the pinned XcodeGen into ThirdParty/tools
	mkdir -p ThirdParty/src ThirdParty/tools/bin ThirdParty/tools/share/xcodegen
	[ -d ThirdParty/src/XcodeGen ] || git clone -q --depth 1 --branch 2.38.0 https://github.com/yonaskolb/XcodeGen.git ThirdParty/src/XcodeGen
	cd ThirdParty/src/XcodeGen && swift build -c release --product xcodegen
	cp ThirdParty/src/XcodeGen/.build/release/xcodegen ThirdParty/tools/bin/
	cp -R ThirdParty/src/XcodeGen/SettingPresets ThirdParty/tools/share/xcodegen/

deps:            ## build spice-client-glib + dependencies into ThirdParty/prefix
	Scripts/build-spice.sh

project:         ## (re)generate FunkyShadow.xcodeproj from project.yml
	$(XCODEGEN) generate --quiet

build: project   ## command-line build
	xcodebuild -project FunkyShadow.xcodeproj -scheme FunkyShadow -configuration $(CONFIG) -derivedDataPath $(DERIVED) build | tail -3

run: build
	open $(APP)

test:            ## ShadowAPI unit tests
	swift test --package-path Packages/ShadowAPI

clean:
	rm -rf build FunkyShadow.xcodeproj
