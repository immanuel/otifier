import Foundation

// Extraction works in two stages:
//   1. Find OTP-related *keyword* spans and 4–8 digit *candidate* spans.
//   2. Pick the first candidate that sits within `proximityChars` of any keyword.
// This lets short digit groups (order numbers, dates, IPs) appear between the
// keyword and the real OTP without breaking the match, while still rejecting
// bare digits with no nearby OTP context.

private let proximityChars = 60

/// The editable default keyword set. These values are recognition data, not UI
/// translations, so changing the menu language never changes the active rules.
public let defaultOTPKeywords: [String] = [
    "code", "otp", "passcode", "verification", "2fa", "mfa", "verify",
    "one-time", "one time", "onetime", "sign-in", "sign in", "signin",
    "auth", "authentication", "login",
    "验证码", "动态口令", "短信码", "安全码", "校验码", "登录码", "认证码",
    "确认码", "授权码", "一次性密码", "一次性口令", "código", "コード",
]

// ASCII word boundaries do not work for text such as "178452为您的验证码":
// ICU treats both digits and Han characters as word characters. Bound only on
// Latin letters/digits instead, and accept one visual separator in grouped codes.
private let candidateRegex = try! NSRegularExpression(
    pattern: #"(?<![A-Za-z0-9])(?:\d{4,8}|\d{2,4}[ ‐‑–-]\d{2,4})(?![A-Za-z0-9])"#
)

// Words/symbols that, when they appear immediately before a digit run, mark it
// as something other than an OTP — masked card/account tails ("ending: 43001"),
// money ("$12481.16"), reference numbers, etc. Anchored at the end of the
// candidate's local prefix so unrelated earlier text doesn't trigger it.
private let candidatePrefixRejectRegex = try! NSRegularExpression(
    pattern: #"(?:\bending(?:\s+in)?|\baccount(?:\s+(?:number|no\.?|#))?|\bcard|\border|\btracking|\binvoice|\bphone|\bzip|\bappointment|\bamount|\$)[^A-Za-z0-9]{0,5}$"#,
    options: [.caseInsensitive]
)

private let googleStyleRegex = try! NSRegularExpression(
    pattern: #"(?<![A-Za-z0-9])G-(\d{4,8})(?![A-Za-z0-9])"#
)

private let negativeKeywords: [String] = [
    "order", "tracking", "invoice", "receipt", "shipping",
    "transaction", "payment", "balance",
    "phone", "appointment", "address", "zip code",
]

private let strongOTPMarkers: [String] = [
    "verification code", "otp", "passcode", "2fa", "mfa",
    "one-time code", "one time code", "auth code",
    "验证码", "动态口令", "短信码", "安全码", "校验码", "登录码",
    "认证码", "确认码", "授权码", "一次性密码", "一次性口令",
]

private let weakOTPKeywords: Set<String> = ["code", "verify", "login"]

private struct CandidateMatch {
    let code: String
    let range: NSRange
}

/// Extract an OTP code from a text string, if present.
/// Returns the code, or nil if no plausible OTP was found.
public func extractOTP(
    from text: String,
    keywords: [String] = defaultOTPKeywords
) -> String? {
    let lower = text.lowercased()

    let keywordMatches = keywords.map { keyword in
        (keyword, matchingKeywordRanges(of: keyword, in: text))
    }
    let keywordRanges = keywordMatches.flatMap { $0.1 }

    // Negative context (order/receipt/phone/appointment/…) wins unless a strong,
    // unambiguous OTP marker is also present — e.g. "Your verification code for
    // order #X is …" should still extract.
    let hasNegative = negativeKeywords.contains { lower.contains($0) }
    let hasConfiguredStrongKeyword = keywordMatches.contains { keyword, ranges in
        !ranges.isEmpty && !weakOTPKeywords.contains(keyword.lowercased())
    }
    let hasStrong = strongOTPMarkers.contains { lower.contains($0) } || hasConfiguredStrongKeyword
    if hasNegative && !hasStrong { return nil }

    let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)

    // Google-style explicit prefix wins outright.
    if let match = googleStyleRegex.firstMatch(in: text, options: [], range: fullRange),
       let r = Range(match.range(at: 1), in: text) {
        let code = String(text[r])
        if isValidOTPCode(code) { return code }
    }

    guard !keywordRanges.isEmpty else { return nil }

    let candidates = candidateMatches(in: text)
    for cand in candidates {
        let code = cand.code

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

/// Returns plausible numeric candidates without requiring an OTP keyword. This
/// is used only by the in-memory "unrecognized notification" UI; automatic
/// copying remains gated by extractOTP's contextual checks.
public func extractOTPCandidates(from text: String) -> [String] {
    var seen = Set<String>()
    return candidateMatches(in: text).compactMap { candidate in
        seen.insert(candidate.code).inserted ? candidate.code : nil
    }
}

private func candidateMatches(in text: String) -> [CandidateMatch] {
    let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
    return candidateRegex.matches(in: text, options: [], range: fullRange).compactMap { match in
        guard let range = Range(match.range, in: text) else { return nil }
        let code = text[range].compactMap { character in
            character.wholeNumberValue.map(String.init)
        }.joined()
        guard isValidOTPCode(code) else { return nil }
        return CandidateMatch(code: code, range: match.range)
    }
}

private func literalRanges(of keyword: String, in text: String) -> [NSRange] {
    let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !keyword.isEmpty else { return [] }

    let source = text as NSString
    var ranges: [NSRange] = []
    var searchRange = NSRange(location: 0, length: source.length)
    while searchRange.length > 0 {
        let match = source.range(of: keyword, options: [.caseInsensitive], range: searchRange)
        guard match.location != NSNotFound else { break }
        ranges.append(match)
        let nextLocation = match.location + max(match.length, 1)
        searchRange = NSRange(location: nextLocation, length: source.length - nextLocation)
    }
    return ranges
}

/// Literal keyword matching with the same ASCII-letter boundary behavior as
/// the original regular expression. This prevents the editable keyword "code"
/// from matching inside words such as "decode", while still working next to
/// Han characters and digits.
private func matchingKeywordRanges(of keyword: String, in text: String) -> [NSRange] {
    literalRanges(of: keyword, in: text).filter { range in
        let source = text as NSString
        let keywordSource = keyword as NSString
        let first = keywordSource.length > 0 ? keywordSource.character(at: 0) : 0
        let last = keywordSource.length > 0 ? keywordSource.character(at: keywordSource.length - 1) : 0

        if isASCIILetter(first), range.location > 0,
           isASCIILetter(source.character(at: range.location - 1)) {
            return false
        }

        let end = range.location + range.length
        if isASCIILetter(last), end < source.length,
           isASCIILetter(source.character(at: end)) {
            return false
        }
        return true
    }
}

private func isASCIILetter(_ value: unichar) -> Bool {
    (65...90).contains(value) || (97...122).contains(value)
}

private func isValidOTPCode(_ code: String) -> Bool {
    guard (4...8).contains(code.count) else { return false }
    guard let first = code.first else { return false }
    if code.allSatisfy({ $0 == first }) { return false }   // 1111, 000000, …
    return true
}
