SWIFT = swiftc
SWIFT_FLAGS = -O

SPARKLE_DIR = Vendor/Sparkle
SPARKLE_FRAMEWORK = $(SPARKLE_DIR)/Sparkle.framework
SPARKLE_BIN = $(SPARKLE_DIR)/bin
RELEASES_DIR = Releases

DOWNLOAD_URL_PREFIX = https://otifier.com/downloads/

LIB_SOURCES = Sources/OTifierLib/OTPExtractor.swift \
              Sources/OTifierLib/ClipboardManager.swift \
              Sources/OTifierLib/Notifier.swift \
              Sources/OTifierLib/NotificationWatcher.swift

APP_SOURCES = Sources/OTifierApp/OTifierApp.swift \
              Sources/OTifierApp/AppState.swift \
              Sources/OTifierApp/OTifierMenu.swift \
              Sources/OTifierApp/AccessibilityDragPanel.swift \
              Sources/OTifierApp/LocalizationManager.swift

LOCALIZATION_CONFIG = Sources/OTifierApp/Localizations.json

BUILD_DIR = .build
APP_BUNDLE = $(BUILD_DIR)/Otifier.app
APP_ZIP = Otifier.zip
DMG = Otifier.dmg

ENTITLEMENTS = Otifier.entitlements
NOTARY_PROFILE = otifier-notary

# Optional local overrides (e.g. DEVELOPER_ID). Not checked in.
-include Makefile.local

.PHONY: all clean otifier ax-explorer app release verify test \
        notarize-app staple-app dmg notarize-dmg staple-dmg dist \
        check-sparkle sign-sparkle appcast site

all: otifier ax-explorer

check-sparkle:
	@if [ ! -d "$(SPARKLE_FRAMEWORK)" ]; then \
		echo "ERROR: Sparkle.framework not found at $(SPARKLE_FRAMEWORK)"; \
		echo ""; \
		echo "Download the latest Sparkle 2.x binary release from:"; \
		echo "  https://github.com/sparkle-project/Sparkle/releases"; \
		echo ""; \
		echo "Extract it so the layout looks like:"; \
		echo "  Vendor/Sparkle/Sparkle.framework"; \
		echo "  Vendor/Sparkle/bin/{generate_keys,sign_update,generate_appcast}"; \
		exit 1; \
	fi

otifier: $(BUILD_DIR)/otifier

$(BUILD_DIR)/otifier: Sources/otifier/main.swift $(LIB_SOURCES) | $(BUILD_DIR)
	$(SWIFT) $(SWIFT_FLAGS) -o $@ Sources/otifier/main.swift $(LIB_SOURCES)

ax-explorer: $(BUILD_DIR)/ax-explorer

$(BUILD_DIR)/ax-explorer: Sources/ax-explorer/main.swift | $(BUILD_DIR)
	$(SWIFT) $(SWIFT_FLAGS) -o $@ Sources/ax-explorer/main.swift

app: $(APP_BUNDLE)

$(APP_BUNDLE): check-sparkle $(APP_SOURCES) $(LIB_SOURCES) $(LOCALIZATION_CONFIG) Sources/OTifierApp/Info.plist AppIcon.icns | $(BUILD_DIR)
	@echo "Building Otifier.app..."
	$(SWIFT) $(SWIFT_FLAGS) \
		-F $(SPARKLE_DIR) -framework Sparkle \
		-Xlinker -rpath -Xlinker @executable_path/../Frameworks \
		-o $(BUILD_DIR)/OTifierApp $(APP_SOURCES) $(LIB_SOURCES)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@mkdir -p $(APP_BUNDLE)/Contents/Frameworks
	@cp $(BUILD_DIR)/OTifierApp $(APP_BUNDLE)/Contents/MacOS/Otifier
	@cp Sources/OTifierApp/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	@cp AppIcon.icns $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
	@cp $(LOCALIZATION_CONFIG) $(APP_BUNDLE)/Contents/Resources/Localizations.json
	@rm -rf $(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework
	@cp -R $(SPARKLE_FRAMEWORK) $(APP_BUNDLE)/Contents/Frameworks/
	@codesign --force --sign - --deep $(APP_BUNDLE)
	@echo "Built $(APP_BUNDLE)"

release: check-sparkle $(APP_SOURCES) $(LIB_SOURCES) $(LOCALIZATION_CONFIG) Sources/OTifierApp/Info.plist AppIcon.icns $(ENTITLEMENTS) | $(BUILD_DIR)
	@if [ -z "$(DEVELOPER_ID)" ]; then \
		echo "ERROR: DEVELOPER_ID is not set."; \
		echo "Set it via env var or Makefile.local, e.g.:"; \
		echo "  export DEVELOPER_ID=\"Developer ID Application: Your Name (TEAMID)\""; \
		echo "  make release"; \
		echo "Find yours with: security find-identity -v -p codesigning"; \
		exit 1; \
	fi
	@echo "Building release Otifier.app..."
	$(SWIFT) $(SWIFT_FLAGS) \
		-F $(SPARKLE_DIR) -framework Sparkle \
		-Xlinker -rpath -Xlinker @executable_path/../Frameworks \
		-o $(BUILD_DIR)/OTifierApp $(APP_SOURCES) $(LIB_SOURCES)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@mkdir -p $(APP_BUNDLE)/Contents/Frameworks
	@cp $(BUILD_DIR)/OTifierApp $(APP_BUNDLE)/Contents/MacOS/Otifier
	@cp Sources/OTifierApp/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	@cp AppIcon.icns $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
	@cp $(LOCALIZATION_CONFIG) $(APP_BUNDLE)/Contents/Resources/Localizations.json
	@rm -rf $(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework
	@cp -R $(SPARKLE_FRAMEWORK) $(APP_BUNDLE)/Contents/Frameworks/
	@$(MAKE) sign-sparkle
	@echo "Signing app with $(DEVELOPER_ID)..."
	codesign --force --options runtime --timestamp \
		--entitlements $(ENTITLEMENTS) \
		--sign "$(DEVELOPER_ID)" \
		$(APP_BUNDLE)
	@echo "Built and signed $(APP_BUNDLE)"
	@$(MAKE) verify

# Sign the embedded Sparkle.framework from the inside out, in the order Sparkle
# requires: nested XPC services, Updater.app, Autoupdate, then the framework
# itself. Apple discourages --deep for Developer ID, so we walk it explicitly.
sign-sparkle:
	@if [ -z "$(DEVELOPER_ID)" ]; then echo "ERROR: DEVELOPER_ID is not set."; exit 1; fi
	@echo "Signing embedded Sparkle.framework..."
	@SPARKLE_IN_APP="$(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework"; \
	for inner in \
		"$$SPARKLE_IN_APP/Versions/B/XPCServices/Downloader.xpc" \
		"$$SPARKLE_IN_APP/Versions/B/XPCServices/Installer.xpc" \
		"$$SPARKLE_IN_APP/Versions/B/Updater.app" \
		"$$SPARKLE_IN_APP/Versions/B/Autoupdate"; do \
		if [ -e "$$inner" ]; then \
			echo "  signing $$inner"; \
			codesign --force --options runtime --timestamp \
				--sign "$(DEVELOPER_ID)" "$$inner" || exit 1; \
		fi; \
	done; \
	echo "  signing $$SPARKLE_IN_APP"; \
	codesign --force --options runtime --timestamp \
		--sign "$(DEVELOPER_ID)" "$$SPARKLE_IN_APP"

verify:
	@echo "Verifying signature..."
	codesign --verify --deep --strict --verbose=2 $(APP_BUNDLE)
	@echo "Assessing with Gatekeeper..."
	spctl --assess --verbose $(APP_BUNDLE) || true

notarize-app:
	@echo "Zipping app for notarization..."
	ditto -c -k --keepParent $(APP_BUNDLE) $(APP_ZIP)
	@echo "Submitting to Apple notary service (this can take a few minutes)..."
	xcrun notarytool submit $(APP_ZIP) --keychain-profile $(NOTARY_PROFILE) --wait
	@rm -f $(APP_ZIP)

staple-app:
	xcrun stapler staple $(APP_BUNDLE)
	spctl --assess -vv $(APP_BUNDLE)

dmg: AppIcon.icns
	@if [ -z "$(DEVELOPER_ID)" ]; then echo "ERROR: DEVELOPER_ID is not set."; exit 1; fi
	@if [ ! -d "$(APP_BUNDLE)" ]; then \
		echo "ERROR: $(APP_BUNDLE) not found. Run 'make release' first,"; \
		echo "or use 'make dist' for the full release pipeline."; \
		exit 1; \
	fi
	@if codesign -dv $(APP_BUNDLE) 2>&1 | grep -q "Signature=adhoc"; then \
		echo "ERROR: $(APP_BUNDLE) is ad-hoc signed (built with 'make app')."; \
		echo "Run 'make release' first to produce a Developer ID-signed bundle,"; \
		echo "or use 'make dist' for the full release pipeline."; \
		exit 1; \
	fi
	@rm -f $(DMG)
	@echo "Building $(DMG)..."
	create-dmg \
		--volname "Otifier" \
		--volicon AppIcon.icns \
		--window-pos 200 120 \
		--window-size 600 400 \
		--icon-size 110 \
		--icon "Otifier.app" 160 200 \
		--hide-extension "Otifier.app" \
		--app-drop-link 440 200 \
		--no-internet-enable \
		$(DMG) \
		$(APP_BUNDLE)
	@echo "Signing DMG..."
	codesign --force --sign "$(DEVELOPER_ID)" --timestamp $(DMG)

notarize-dmg:
	@echo "Submitting DMG to Apple notary service..."
	xcrun notarytool submit $(DMG) --keychain-profile $(NOTARY_PROFILE) --wait

staple-dmg:
	xcrun stapler staple $(DMG)
	spctl --assess --type open --context context:primary-signature -vv $(DMG)

# End-to-end: build, sign, notarize/staple app, package DMG, notarize/staple DMG.
dist: release notarize-app staple-app dmg notarize-dmg staple-dmg
	@echo ""
	@echo "Done. Distributable: $(DMG)"

# Drop the freshly-stapled DMG into Releases/ under a versioned name, then
# regenerate the appcast feed using Sparkle's tools. Run this after `make dist`.
appcast: check-sparkle
	@if [ ! -f "$(DMG)" ]; then echo "ERROR: $(DMG) not found. Run 'make dist' first."; exit 1; fi
	@VERSION=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Sources/OTifierApp/Info.plist); \
	mkdir -p $(RELEASES_DIR); \
	cp "$(DMG)" "$(RELEASES_DIR)/Otifier-$$VERSION.dmg"; \
	echo "Copied to $(RELEASES_DIR)/Otifier-$$VERSION.dmg"
	$(SPARKLE_BIN)/generate_appcast --download-url-prefix $(DOWNLOAD_URL_PREFIX) $(RELEASES_DIR)/
	@echo ""
	@echo "Appcast generated. Upload these to your host:"
	@echo "  $(RELEASES_DIR)/appcast.xml"
	@ls $(RELEASES_DIR)/*.dmg | sed 's/^/  /'

# Stage the otifier.com landing site for nginx upload. Copies the latest
# versioned DMG from $(RELEASES_DIR) into site/downloads/Otifier.dmg so the
# stable download CTA on the site keeps working without per-release edits.
site:
	@mkdir -p site/downloads
	@LATEST_DMG=$$(ls -t $(RELEASES_DIR)/Otifier-*.dmg 2>/dev/null | head -n 1); \
	if [ -z "$$LATEST_DMG" ]; then \
	  echo "ERROR: no Otifier-*.dmg in $(RELEASES_DIR)/ — run 'make appcast' first."; \
	  exit 1; \
	fi; \
	cp "$$LATEST_DMG" site/downloads/Otifier.dmg; \
	cp $(RELEASES_DIR)/appcast.xml site/appcast.xml 2>/dev/null || true; \
	echo "Staged: $$LATEST_DMG -> site/downloads/Otifier.dmg"
	@echo "Site ready in ./site — upload to nginx web root."

test: $(BUILD_DIR)/test-runner
	$(BUILD_DIR)/test-runner

$(BUILD_DIR)/test-runner: Tests/OTifierLibTests/OTPExtractorTests.swift $(LIB_SOURCES) $(LOCALIZATION_CONFIG) | $(BUILD_DIR)
	$(SWIFT) $(SWIFT_FLAGS) -o $@ Tests/OTifierLibTests/OTPExtractorTests.swift $(LIB_SOURCES)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

clean:
	rm -rf $(BUILD_DIR)
	rm -f $(APP_ZIP) $(DMG)
