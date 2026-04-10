SWIFT = swiftc
SWIFT_FLAGS = -O

LIB_SOURCES = Sources/OTifierLib/OTPExtractor.swift \
              Sources/OTifierLib/ClipboardManager.swift \
              Sources/OTifierLib/Notifier.swift \
              Sources/OTifierLib/NotificationWatcher.swift

APP_SOURCES = Sources/OTifierApp/OTifierApp.swift \
              Sources/OTifierApp/AppState.swift \
              Sources/OTifierApp/OTifierMenu.swift

BUILD_DIR = .build
APP_BUNDLE = $(BUILD_DIR)/Otifier.app

.PHONY: all clean otifier ax-explorer app test

all: otifier ax-explorer

otifier: $(BUILD_DIR)/otifier

$(BUILD_DIR)/otifier: Sources/otifier/main.swift $(LIB_SOURCES) | $(BUILD_DIR)
	$(SWIFT) $(SWIFT_FLAGS) -o $@ Sources/otifier/main.swift $(LIB_SOURCES)

ax-explorer: $(BUILD_DIR)/ax-explorer

$(BUILD_DIR)/ax-explorer: Sources/ax-explorer/main.swift | $(BUILD_DIR)
	$(SWIFT) $(SWIFT_FLAGS) -o $@ Sources/ax-explorer/main.swift

app: $(APP_BUNDLE)

$(APP_BUNDLE): $(APP_SOURCES) $(LIB_SOURCES) Sources/OTifierApp/Info.plist | $(BUILD_DIR)
	@echo "Building Otifier.app..."
	$(SWIFT) $(SWIFT_FLAGS) -o $(BUILD_DIR)/OTifierApp $(APP_SOURCES) $(LIB_SOURCES)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@cp $(BUILD_DIR)/OTifierApp $(APP_BUNDLE)/Contents/MacOS/Otifier
	@cp Sources/OTifierApp/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	@codesign --force --sign - $(APP_BUNDLE)
	@echo "Built $(APP_BUNDLE)"

test: $(BUILD_DIR)/test-runner
	$(BUILD_DIR)/test-runner

$(BUILD_DIR)/test-runner: Tests/OTifierLibTests/OTPExtractorTests.swift $(LIB_SOURCES) | $(BUILD_DIR)
	$(SWIFT) $(SWIFT_FLAGS) -o $@ Tests/OTifierLibTests/OTPExtractorTests.swift $(LIB_SOURCES)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

clean:
	rm -rf $(BUILD_DIR)
