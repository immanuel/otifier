import Foundation

// Simple test runner

var passed = 0
var failed = 0

func assertTrue(_ condition: @autoclosure () -> Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition() {
        passed += 1
    } else {
        failed += 1
        print("FAIL (\(file):\(line)): \(message)")
    }
}

func assertEqual(_ actual: String?, _ expected: String?, file: String = #file, line: Int = #line) {
    if actual == expected {
        passed += 1
    } else {
        failed += 1
        print("FAIL (\(file):\(line)): expected \(expected ?? "nil"), got \(actual ?? "nil")")
    }
}

func assertNil(_ actual: String?, file: String = #file, line: Int = #line) {
    if actual == nil {
        passed += 1
    } else {
        failed += 1
        print("FAIL (\(file):\(line)): expected nil, got \(actual!)")
    }
}

@main struct TestRunner {
    static func main() {
        // --- Should extract: classic OTPs ---
        assertEqual(extractOTP(from: "Your verification code is 847291"), "847291")
        assertEqual(extractOTP(from: "G-583920 is your Google verification code"), "583920")
        assertEqual(extractOTP(from: "Your OTP: 9182"), "9182")
        assertEqual(extractOTP(from: "Your security code: 482910"), "482910")
        assertEqual(extractOTP(from: "Your sign in code is 738291"), "738291")
        assertEqual(extractOTP(from: "您的验证码是 583920"), "583920")
        assertEqual(extractOTP(from: "Your 2FA code is 192837"), "192837")
        assertEqual(extractOTP(from: "Verification code: 83920147"), "83920147")

        // --- Should extract: variations ---
        assertEqual(extractOTP(from: "Your auth code is 928374"), "928374")
        assertEqual(extractOTP(from: "Your one-time passcode: 4827"), "4827")
        assertEqual(extractOTP(from: "Your one time code: 928374"), "928374")
        assertEqual(extractOTP(from: "Your login code is 192847"), "192847")
        assertEqual(extractOTP(from: "Tu código de verificación: 837465"), "837465")
        assertEqual(extractOTP(from: "コード: 192847"), "192847")
        assertEqual(extractOTP(from: "MFA code 554433"), "554433")

        // --- Should extract: boundary lengths ---
        assertEqual(extractOTP(from: "Your code: 1234"), "1234")          // exactly 4
        assertEqual(extractOTP(from: "Your code: 12345678"), "12345678")  // exactly 8

        // --- Should extract: strong marker overrides negative context ---
        // Realistic case: a code about an order is still an OTP.
        assertEqual(extractOTP(from: "Your verification code for order #99 is 871234"), "871234")

        // Bank-style notification with a masked account tail and a transaction
        // amount before the actual OTP — the extractor must skip "Account
        // ending: NNNNN" and "$NN.NN" and pick the code after "is:".
        assertEqual(
            extractOTP(from: "Your Verification Code, Do not share this code with anyone Account ending: 54321 Below is your Verification Code for a $250.00 transaction at MERCHANT is: 871234 Thanks"),
            "871234"
        )

        // --- Should NOT extract: not an OTP at all ---
        assertEqual(extractOTP(from: "Your balance is 847291"), nil)
        assertNil(extractOTP(from: "Your verification code is 1111"))     // all-same
        assertNil(extractOTP(from: "Your code is 000000"))                // all-zero
        assertNil(extractOTP(from: "Confirm your order #847291 has shipped"))
        assertNil(extractOTP(from: "Your tracking code is 847291"))
        assertNil(extractOTP(from: "Please verify your email address"))
        assertNil(extractOTP(from: "Your verification code is 123"))      // <4 digits
        assertNil(extractOTP(from: "Your code: 123456789"))               // >8 digits

        // --- Should NOT extract: false positives that the old extractor allowed ---
        assertNil(extractOTP(from: "Confirm your appointment at 14:30 — call 5551234567"))
        assertNil(extractOTP(from: "Password reset link sent to user 12345678"))
        assertNil(extractOTP(from: "Sign in attempt from IP 192.168.001.142 at 14:30"))
        assertNil(extractOTP(from: "Verification at 14:30"))              // no 4-8 digit run nearby

        // --- Should NOT extract: edge cases around \b ---
        assertNil(extractOTP(from: "decode 12345 binary string"))         // 'code' is inside 'decode'

        // --- Notification scan throttling ---
        var gate = NotificationScanGate()
        let empty = NotificationWindowFingerprint(values: [])
        let banner = NotificationWindowFingerprint(values: ["42:0:1.0:0,0,400,100"])
        let start = Date(timeIntervalSince1970: 1_000)

        assertTrue(gate.shouldScan(fingerprint: empty, now: start), "initial state must be scanned")
        assertTrue(gate.shouldScan(fingerprint: empty, now: start.addingTimeInterval(1)), "initial scan gets one content follow-up")
        assertTrue(!gate.shouldScan(fingerprint: empty, now: start.addingTimeInterval(2)), "unchanged idle state must not scan continuously")
        assertTrue(gate.shouldScan(fingerprint: banner, now: start.addingTimeInterval(3)), "a new banner window must trigger a scan")
        assertTrue(gate.shouldScan(fingerprint: banner, now: start.addingTimeInterval(4)), "a new banner gets one content follow-up")
        assertTrue(!gate.shouldScan(fingerprint: banner, now: start.addingTimeInterval(5)), "stable banner must not trigger repeated scans")
        assertTrue(gate.shouldScan(fingerprint: banner, now: start.addingTimeInterval(35)), "the safety interval must eventually rescan")

        // --- Summary ---
        print("\nOTP Extractor Tests: \(passed) passed, \(failed) failed")
        if failed > 0 {
            exit(1)
        }
    }
}
