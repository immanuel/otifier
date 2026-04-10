import Foundation

/// Regex patterns to match common OTP formats
let otpPatterns: [NSRegularExpression] = {
    let patterns = [
        #"(?:code|码|código)\s*[:：]?\s*(\d{4,8})"#,     // "code: 123456"
        #"(?:OTP|otp)\s*[:：]?\s*(\d{4,8})"#,             // "OTP: 123456"
        #"G-(\d{4,8})"#,                                   // Google-style "G-123456"
        #"\b(\d{4,8})\b"#,                                 // 4-8 digit codes (broad, checked last)
    ]
    return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: []) }
}()

/// Keywords that suggest a message contains a verification code
let otpKeywords: [String] = [
    "verification", "verify", "code", "otp", "one-time",
    "passcode", "password", "pin", "authenticate", "confirm",
    "security code", "login code", "sign in", "sign-in",
    "2fa", "two-factor", "multi-factor", "mfa",
    "验证码", "código", "コード",
]

/// Keywords that suggest a message is NOT about OTPs (reduces false positives)
let negativeKeywords: [String] = [
    "order", "tracking", "invoice", "receipt", "shipping",
    "transaction", "payment", "balance",
]

/// Extract an OTP code from a text string, if present.
/// Returns the code string, or nil if no OTP was found.
func extractOTP(from text: String) -> String? {
    let lower = text.lowercased()

    // Must contain at least one OTP keyword
    let hasKeyword = otpKeywords.contains { lower.contains($0) }
    guard hasKeyword else { return nil }

    // If negative keywords dominate, skip (unless an explicit OTP keyword is present)
    let hasExplicitOTP = ["otp", "verification code", "security code", "验证码", "one-time"].contains { lower.contains($0) }
    if !hasExplicitOTP {
        let hasNegative = negativeKeywords.contains { lower.contains($0) }
        if hasNegative { return nil }
    }

    // Try each pattern, return the first valid match
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    for pattern in otpPatterns {
        if let match = pattern.firstMatch(in: text, options: [], range: range) {
            let groupIndex = match.numberOfRanges > 1 ? 1 : 0
            if let matchRange = Range(match.range(at: groupIndex), in: text) {
                let code = String(text[matchRange])
                // Filter: at least 4 chars, not all same digit
                if code.count >= 4 && code != String(repeating: String(code.first!), count: code.count) {
                    return code
                }
            }
        }
    }
    return nil
}
