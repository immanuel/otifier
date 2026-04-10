# Otifier — macOS OTP Auto-Capture

A macOS menu bar utility that automatically detects OTP codes from notification
banners and copies them to your clipboard. Works with mirrored iPhone
notifications (SMS, email, etc.) via the macOS Accessibility API.

## How it works

```
iPhone notification → mirrored to Mac → notification banner
    → AX tree poll (0.5s) → OTP regex match → clipboard + notification
```

Otifier polls the Notification Center's Accessibility tree every 0.5 seconds.
When a notification banner appears containing an OTP code (detected via regex
patterns and keyword matching), it automatically copies the code to your
clipboard and shows a confirmation notification.

This works with any notification that appears as a macOS banner — mirrored
iPhone texts, Gmail OTPs, app notifications, etc.

## Prerequisites

- macOS 13+ (Ventura or later)
- Xcode Command Line Tools (`xcode-select --install`)
- Accessibility permission granted to the app

## Build

```bash
# Build the menu bar app
make app

# Build the CLI tool (for debugging)
make otifier

# Build the AX tree explorer (for diagnostics)
make ax-explorer

# Run tests
make test
```

## Install and run

```bash
make app
open .build/Otifier.app
```

On first launch, grant Accessibility permission when prompted:
**System Settings → Privacy & Security → Accessibility → enable Otifier**

The app runs in the menu bar (key icon). Click it to see detected OTP codes
or check permission status.

To launch at login, add `Otifier.app` to your Login Items in System Settings.

## Menu bar app

- **Key icon** in the menu bar (filled when OTPs are present)
- **Monitoring panel** — shows recent OTP codes with source and timestamp;
  click any code to re-copy it to clipboard
- **On/off toggle** — pause and resume monitoring
- **Permission CTA** — shown when Accessibility permission is missing,
  with a button to open System Settings directly

## CLI tool

For debugging or headless use:

```bash
make otifier
.build/otifier
```

Prints detected notifications and OTPs to stdout. Useful for verifying that
the AX approach captures your specific notification type.

## AX Explorer

Diagnostic tool to inspect the Accessibility tree of notification-related
processes:

```bash
make ax-explorer
.build/ax-explorer            # one-shot dump
.build/ax-explorer --watch 30 # monitor for 30 seconds
```

Run this while a notification banner is visible to see its AX structure.

## OTP detection

Matches codes via regex patterns with keyword gating:

- **Patterns**: `code: 123456`, `OTP: 1234`, `G-583920`, bare 4-8 digit codes
- **Keywords**: verification, code, OTP, one-time, 2FA, sign in, 验证码, etc.
- **False positive filtering**: rejects repeated digits (1111), order/tracking
  numbers, codes shorter than 4 digits

## Project structure

```
Sources/
  OTifierLib/
    OTPExtractor.swift         # OTP regex matching + keyword gating
    ClipboardManager.swift     # Clipboard copy
    Notifier.swift             # osascript notification display
    NotificationWatcher.swift  # AX-based notification polling
  OTifierApp/
    OTifierApp.swift           # SwiftUI MenuBarExtra entry point
    AppState.swift             # App state, monitoring lifecycle
    OTifierMenu.swift          # Menu bar UI
    Info.plist                 # App bundle metadata (LSUIElement)
  otifier/
    main.swift                 # CLI entry point
  ax-explorer/
    main.swift                 # AX tree diagnostic tool
Tests/
  OTifierLibTests/
    OTPExtractorTests.swift    # OTP extraction test suite
Makefile                       # Build system (swiftc-based)
```
