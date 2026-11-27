# Security review

## Confirmed finding

| # | Severity | File | Lines | Vulnerability | Confidence |
|---|---|---|---|---|---|
| 1 | 🟡 MEDIUM | `lib/main.dart`; `packages/awaaz_sms/android/src/main/kotlin/com/awaaz/sos/sms/AwaazSmsPlugin.kt` | Original `main.dart:238-242, 755`; bridge `30-45` | Delimiter-based contact storage allowed a crafted name to alter the SMS destination after deserialization. | 8/10 |

**Status: fixed.** Contacts are now written as JSON. Legacy records migrate only when they have exactly one delimiter and pass name/phone validation. SMS destinations are normalized and checked in Dart, then constrained to valid Indian mobile numbers again in the Android bridge. The native bridge also rejects oversized SMS messages.

## Additional safeguards

- The contact-readiness test is disabled by default, requires a manual confirmation, sends a clearly marked test message without location, and does not invoke SOS behavior.
- The standard APK omits `SEND_SMS` and `ACCESS_BACKGROUND_LOCATION`. The optional Auto-SMS APK declares them; SMS is still off by default, and live location remains user-started and time-limited.
- Audio evidence is opt-in and encrypted at rest; trusted contact details and incident logs remain in app-local preferences and are not encrypted at rest.

## Limits

- A successful Android SMS API call means the message was queued by the device, not that the carrier delivered it.
- Background execution, location, Quick Settings behavior, and SMS delivery need physical-device testing across Android versions and manufacturers.
- This is a focused code review, not a penetration test or a guarantee that the app is unhackable.
- Google Play may restrict SMS and background-location permissions; review current Play policy before publishing there.
- Permission reduction cannot guarantee that Play Protect will accept a sideloaded or newly signed APK without warning.
