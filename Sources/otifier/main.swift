import Foundation

print("Otifier — OTP Auto-Capture")
print("==========================")
print("Watching for OTP codes in notification banners...")
print("Press Ctrl+C to stop.\n")

let watcher = NotificationWatcher()
watcher.onOTPDetected = { otp, source in
    copyToClipboard(otp)
    print("[Otifier] OTP copied to clipboard: \(otp)")
    showNotification(otp: otp, source: source)
}
watcher.start()

RunLoop.main.run()
