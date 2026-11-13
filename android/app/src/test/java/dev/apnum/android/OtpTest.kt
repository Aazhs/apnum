package dev.apnum.android

import dev.apnum.android.phone.Otp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class OtpTest {
    private fun code(body: String) = Otp.extract(body)

    @Test fun hdfcStyleLeadingCode() =
        assertEquals("123456", code("123456 is your OTP for HDFC Bank NetBanking. Do not share it with anyone."))

    @Test fun sbiCardTransactionIgnoresAmountAndCardDigits() =
        assertEquals("884213", code("OTP for txn of Rs.2,500.00 at AMAZON on card ending 4321 is 884213. Valid for 10 mins. -SBI"))

    @Test fun iciciFourDigit() = assertEquals("4521", code("Dear Customer, Your OTP is 4521 for login. Do not share. -ICICI Bank"))

    @Test fun useCodeAsLogin() = assertEquals("654321", code("Use 654321 as your Swiggy login code. Valid for 5 minutes."))

    @Test fun googleStyleDash() = assertEquals("482913", code("G-482913 is your Google verification code."))

    @Test fun instagramBrackets() = assertEquals("912345", code("<#> 912345 is your Instagram code. Tap to copy"))

    @Test fun paytm() = assertEquals("341092", code("Your Paytm OTP is 341092. Do not share with anyone. Paytm never calls you for OTP."))

    @Test fun debitAlertHasNoCode() =
        assertNull(code("Rs 4500.00 debited from A/c XX1234 on 12-11-2026. Avl bal Rs 12,345.67"))

    @Test fun appointmentDateIsNotACode() = assertNull(code("Your appointment is on 12/11/2026 at 1030"))

    @Test fun tollFreeNumberIsNotACode() = assertNull(code("Call us at 1800 123 4567 for help with your code"))

    @Test fun shortCodeColon() = assertEquals("4821", code("Your Uber code: 4821"))

    @Test fun spacedSixDigits() = assertEquals("785412", code("Verification code 785 412"))

    @Test fun referenceNumberIgnored() =
        assertEquals("123456", code("Your Amazon OTP is 123456. Do not disclose it to anyone. Valid for 10 minutes. Ref 98765432"))

    @Test fun creditAlertNoKeyword() = assertNull(code("Your SBI A/c X1234 credited Rs.10000 on 11Nov. Ref 123456789"))

    @Test fun useCodeToVerify() = assertEquals("2468", code("Use code 2468 to verify your Zomato account"))

    @Test fun oneTimePassword() = assertEquals("7391", code("Your one time password is 7391. It is valid for 30 minutes"))

    @Test fun pinToConfirm() = assertEquals("8820", code("PIN 8820 to confirm your Ola ride"))

    @Test fun phoneNumberIsNotACode() = assertNull(code("Hi! Meeting at 5pm, call me on +91 98765 43210"))

    @Test fun rechargeAmountAndDate() = assertNull(code("Your Airtel recharge of Rs 299 is successful. Valid till 2026-12-10"))

    @Test fun upiDebitWithRefNumber() =
        assertNull(code("Dear UPI user A/C X6789 debited by 1500.0 on date 12Nov26 trf to RAHUL Refno 432156789012"))

    @Test fun aadhaarSpaced() = assertEquals("654321", code("Your OTP for Aadhaar authentication is 654 321"))

    @Test fun codeBeforeIsYourOtp() = assertEquals("5432", code("JioFiber: 5432 is the OTP for your account. Expires in 5 minutes."))

    @Test fun neftCredit() = assertNull(code("NEFT of Rs 25000 credited to your account. Your A/c balance is Rs 1,25,000"))

    @Test fun passwordReset() = assertEquals("120934", code("Your password reset code is: 120934"))

    @Test fun orderNumberIsNotACode() = assertNull(code("Order #482913 shipped. Track it in the app."))

    @Test fun sevenDigits() = assertEquals("1234567", code("Your verification code is 1234567"))

    @Test fun noSpaceAfterColon() = assertEquals("998877", code("OTP:998877"))

    @Test fun amountBeforeOtp() = assertEquals("123456", code("Txn of 5000 on card. OTP 123456"))

    @Test fun plainChat() = assertNull(code("Running late, see you at 7 near gate 2"))
}
