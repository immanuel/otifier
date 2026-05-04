SWIFT = swiftc
SWIFT_FLAGS = -O

LIB_SOURCES = Sources/OTifierLib/OTPExtractor.swift \
              Sources/OTifierLib/ClipboardManager.swift \
              Sources/OTifierLib/Notifier.swift \
              Sources/OTifierLib/NotificationWatcher.swift

APP_SOURCES = Sources/OTifierApp/OTifierApp.swift \
              Sources/OTifierApp/AppState.swift \
              Sources/OTifierApp/OTifierMenu.swift \
              Sources/OTifierApp/AccessibilityDragPanel.swift

BUILD_DIR = .build
APP_BUNDLE = $(BUILD_DIR)/Otifier.app
APP_ZIP = Otifier.zip
DMG = Otifier.dmg

ENTITLEMENTS = Otifier.entitlements
NOTARY_PROFILE = otifier-notary

# Optional local overrides (e.g. DEVELOPER_ID). Not checked in.
-include Makefile.local

.PHONY: all clean otifier ax-explorer app release verify test \
        notarize-app staple-app dmg notarize-dmg staple-dmg dist

all: otifier ax-explorer

otifier: $(BUILD_DIR)/otifier

$(BUILD_DIR)/otifier: Sources/otifier/main.swift $(LIB_SOURCES) | $(BUILD_DIR)
	$(SWIFT) $(SWIFT_FLAGS) -o $@ Sources/otifier/main.swift $(LIB_SOURCES)

ax-explorer: $(BUILD_DIR)/ax-explorer

$(BUILD_DIR)/ax-explorer: Sources/ax-explorer/main.swift | $(BUILD_DIR)
	$(SWIFT) $(SWIFT_FLAGS) -o $@ Sources/ax-explorer/main.swift

app: $(APP_BUNDLE)

$(APP_BUNDLE): $(APP_SOURCES) $(LIB_SOURCES) Sources/OTifierApp/Info.plist AppIcon.icns | $(BUILD_DIR)
	@echo "Building Otifier.app..."
	$(SWIFT) $(SWIFT_FLAGS) -o $(BUILD_DIR)/OTifierApp $(APP_SOURCES) $(LIB_SOURCES)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@cp $(BUILD_DIR)/OTifierApp $(APP_BUNDLE)/Contents/MacOS/Otifier
	@cp Sources/OTifierApp/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	@cp AppIcon.icns $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
	@codesign --force --sign - $(APP_BUNDLE)
	@echo "Built $(APP_BUNDLE)"

release: $(APP_SOURCES) $(LIB_SOURCES) Sources/OTifierApp/Info.plist AppIcon.icns $(ENTITLEMENTS) | $(BUILD_DIR)
	@if [ -z "$(DEVELOPER_ID)" ]; then \
		echo "ERROR: DEVELOPER_ID is not set."; \
		echo "Set it via env var or Makefile.local, e.g.:"; \
		echo "  export DEVELOPER_ID=\"Developer ID Application: Your Name (TEAMID)\""; \
		echo "  make release"; \
		echo "Find yours with: security find-identity -v -p codesigning"; \
		exit 1; \
	fi
	@echo "Building release Otifier.app..."
	$(SWIFT) $(SWIFT_FLAGS) -o $(BUILD_DIR)/OTifierApp $(APP_SOURCES) $(LIB_SOURCES)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@cp $(BUILD_DIR)/OTifierApp $(APP_BUNDLE)/Contents/MacOS/Otifier
	@cp Sources/OTifierApp/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	@cp AppIcon.icns $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
	@echo "Signing with $(DEVELOPER_ID)..."
	codesign --force --options runtime --timestamp \
		--entitlements $(ENTITLEMENTS) \
		--sign "$(DEVELOPER_ID)" \
		$(APP_BUNDLE)
	@echo "Built and signed $(APP_BUNDLE)"
	@$(MAKE) verify

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

dmg: $(APP_BUNDLE) AppIcon.icns
	@if [ -z "$(DEVELOPER_ID)" ]; then echo "ERROR: DEVELOPER_ID is not set."; exit 1; fi
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

test: $(BUILD_DIR)/test-runner
	$(BUILD_DIR)/test-runner

$(BUILD_DIR)/test-runner: Tests/OTifierLibTests/OTPExtractorTests.swift $(LIB_SOURCES) | $(BUILD_DIR)
	$(SWIFT) $(SWIFT_FLAGS) -o $@ Tests/OTifierLibTests/OTPExtractorTests.swift $(LIB_SOURCES)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

clean:
	rm -rf $(BUILD_DIR)
	rm -f $(APP_ZIP) $(DMG)
