import Foundation

// Extraction works in two stages:
//   1. Find OTP-related *keyword* spans and 4–8 digit *candidate* spans.
//   2. Pick the first candidate that sits within `proximityChars` of any keyword.
// This lets short digit groups (order numbers, dates, IPs) appear between the
// keyword and the real OTP without breaking the match, while still rejecting
// bare digits with no nearby OTP context.

private let proximityChars = 60

private let keywordRegex = try! NSRegularExpression(
    pattern: #"\b(?:code|otp|passcode|verification|2fa|mfa|verify|one[- ]?time|sign[- ]?in|auth(?:entication)?|login)\b|验证码|código|コード"#,
    options: [.caseInsensitive]
)

private let candidateRegex = try! NSRegularExpression(pattern: #"\b\d{4,8}\b"#)

// Words/symbols that, when they appear immediately before a digit run, mark it
// as something other than an OTP — masked card/account tails ("ending: 43001"),
// money ("$12481.16"), reference numbers, etc. Anchored at the end of the
// candidate's local prefix so unrelated earlier text doesn't trigger it.
private let candidatePrefixRejectRegex = try! NSRegularExpression(
    pattern: #"(?:\bending(?:\s+in)?|\baccount(?:\s+(?:number|no\.?|#))?|\bcard|\border|\btracking|\binvoice|\bphone|\bzip|\bappointment|\bamount|[\$#])[^A-Za-z0-9]{0,5}$"#,
    options: [.caseInsensitive]
)

private let googleStyleRegex = try! NSRegularExpression(pattern: #"\bG-(\d{4,8})\b"#)

private let negativeKeywords: [String] = [
    "order", "tracking", "invoice", "receipt", "shipping",
    "transaction", "payment", "balance",
    "phone", "appointment", "address", "zip code",
]

private let strongOTPMarkers: [String] = [
    "verification code", "otp", "passcode", "2fa", "mfa",
    "one-time code", "one time code", "auth code",
    "验证码",
]

/// Extract an OTP code from a text string, if present.
/// Returns the code, or nil if no plausible OTP was found.
public func extractOTP(from text: String) -> String? {
    let lower = text.lowercased()

    // Negative context (order/receipt/phone/appointment/…) wins unless a strong,
    // unambiguous OTP marker is also present — e.g. "Your verification code for
    // order #X is …" should still extract.
    let hasNegative = negativeKeywords.contains { lower.contains($0) }
    let hasStrong = strongOTPMarkers.contains { lower.contains($0) }
    if hasNegative && !hasStrong { return nil }

    let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)

    // Google-style explicit prefix wins outright.
    if let match = googleStyleRegex.firstMatch(in: text, options: [], range: fullRange),
       let r = Range(match.range(at: 1), in: text) {
        let code = String(text[r])
        if isValidOTPCode(code) { return code }
    }

    let keywordRanges = keywordRegex.matches(in: text, options: [], range: fullRange).map { $0.range }
    guard !keywordRanges.isEmpty else { return nil }

    let candidates = candidateRegex.matches(in: text, options: [], range: fullRange)
    for cand in candidates {
        guard let r = Range(cand.range, in: text) else { continue }
        let code = String(text[r])
        guard isValidOTPCode(code) else { continue }

        let candStart = cand.range.location
        let candEnd = candStart + cand.range.length

        let prefixLen = min(25, candStart)
        let prefixRange = NSRange(location: candStart - prefixLen, length: prefixLen)
        if candidatePrefixRejectRegex.firstMatch(in: text, options: [], range: prefixRange) != nil {
            continue
        }
        for kw in keywordRanges {
            let kwStart = kw.location
            let kwEnd = kwStart + kw.length
            let distance: Int
            if candStart >= kwEnd {
                distance = candStart - kwEnd
            } else if kwStart >= candEnd {
                distance = kwStart - candEnd
            } else {
                distance = 0
            }
            if distance <= proximityChars { return code }
        }
    }
    return nil
}

private func isValidOTPCode(_ code: String) -> Bool {
    guard (4...8).contains(code.count) else { return false }
    guard let first = code.first else { return false }
    if code.allSatisfy({ $0 == first }) { return false }   // 1111, 000000, …
    return true
}
