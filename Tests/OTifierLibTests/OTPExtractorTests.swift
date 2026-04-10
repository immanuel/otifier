import Foundation

// Simple test runner

var passed = 0
var failed = 0

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
        // --- Should extract ---
        assertEqual(extractOTP(from: "Your verification code is 847291"), "847291")
        assertEqual(extractOTP(from: "G-583920 is your Google verification code"), "583920")
        assertEqual(extractOTP(from: "Your OTP: 9182"), "9182")
        assertEqual(extractOTP(from: "Your security code: 482910"), "482910")
        assertEqual(extractOTP(from: "Your sign in code is 738291"), "738291")
        assertEqual(extractOTP(from: "您的验证码是 583920"), "583920")
        assertEqual(extractOTP(from: "Your 2FA code is 192837"), "192837")
        assertEqual(extractOTP(from: "Verification code: 83920147"), "83920147")

        // --- Should NOT extract ---
        assertNil(extractOTP(from: "Your balance is 847291"))
        assertNil(extractOTP(from: "Your verification code is 1111"))
        assertNil(extractOTP(from: "Confirm your order #847291 has shipped"))
        assertNil(extractOTP(from: "Your tracking code is 847291"))
        assertNil(extractOTP(from: "Please verify your email address"))
        assertNil(extractOTP(from: "Your verification code is 123"))

        // --- Summary ---
        print("\nOTP Extractor Tests: \(passed) passed, \(failed) failed")
        if failed > 0 {
            exit(1)
        }
    }
}
