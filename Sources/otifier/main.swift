import Foundation

print("Otifier — OTP Auto-Capture")
print("==========================")
print("Watching for OTP codes in notification banners...")
print("Press Ctrl+C to stop.\n")

let watcher = NotificationWatcher()
watcher.onOTPDetected = { otp, _ in
    copyToClipboard(otp)
    print("[Otifier] OTP copied to clipboard: \(otp)")
}
watcher.start()

RunLoop.main.run()
