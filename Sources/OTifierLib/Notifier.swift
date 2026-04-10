import Foundation

/// Show a macOS notification using osascript.
func showNotification(otp: String, source: String) {
    let script = """
    display notification "Code: \(otp) — copied to clipboard" with title "OTP Detected" subtitle "\(source)" sound name "Glass"
    """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    try? process.run()
}
