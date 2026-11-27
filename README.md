<div align="center">

<img src="assets/app_logo.png" width="120" alt="Awaaz Suraksha Logo"/>

# 🛡️ Awaaz Suraksha — आवाज़ सुरक्षा

**Voice-First Emergency Safety App for Women in India**

[![Build Status](https://github.com/alwayspositivevibes/Awaaz-Suraksha-App/actions/workflows/build.yml/badge.svg)](https://github.com/alwayspositivevibes/Awaaz-Suraksha-App/actions)
![Flutter](https://img.shields.io/badge/Flutter-3.27.1-blue?logo=flutter)
![Android](https://img.shields.io/badge/Android-API%2024+-green?logo=android)
![Made in India](https://img.shields.io/badge/Made%20with%20%E2%9D%A4%EF%B8%8F-India-orange)
![License](https://img.shields.io/badge/License-MIT-yellow)

> Built for the **Wispr Flow × Scaler AI Voice Hackathon** by **Team CTRL ALT ELITE**

[📥 Download APK](#-download-apk) • [✨ Features](#-features) • [🔒 Security](#-security) • [📱 Triggers](#-multi-trigger-sos)

</div>

---

## 📥 Download APK

Download the APK attached to the latest **[GitHub Release](https://github.com/alwayspositivevibes/Awaaz-Suraksha-App/releases)**. If no release has an APK attached yet, the maintainer has not published one.

Two APK variants are built:

- **Standard** — omits `SEND_SMS` and background-location permissions; SOS uses WhatsApp drafts or manual calls, and recurring background location texts are unavailable.
- **Auto-SMS** — includes SMS and background-location permissions for opted-in automatic alerts and live sharing. The in-app SMS switch remains off by default. Android or Play Protect may still warn about this variant.

The APKs in **Actions** are debug/testing artifacts, not recommended public release builds. Before publishing either variant, sign it with a private release key; never commit the keystore or its passwords to this repository. Sideloading itself may still prompt Android or Play Protect warnings.

To install a downloaded APK on Android, allow installation for the browser or file manager that opened it. Only install APKs from a release you trust.

---

## 🎯 Problem We Solve

Every 16 minutes, a woman is harassed in India. Existing SOS apps require manual taps — useless in a real emergency. **Awaaz Suraksha** activates with just your voice or a shake, even when your phone is in your pocket.

---

## ✨ Features

### 🗣️ Voice SOS (App Open)
- Says **"Help me now"** or **"Bachao"** — triggers SOS instantly
- Listens while Awaaz Suraksha is open; stops listening when the app is backgrounded
- Uses an offline Indian-English Vosk model, so Android speech-service tones are not used
- Hindi wake words may be less reliable than English; the model is about 38 MB
- Voice cancel: Say **"I'm safe"** to deactivate
- Model: [Vosk small Indian-English 0.4](https://alphacephei.com/vosk/models), Apache-2.0

### 📳 Background Shake Detection
- Shake the phone 3× within 1.5 seconds to trigger SOS, including while the screen is locked
- Raises an immediate SOS notification; if automatic SMS is enabled, texts saved contacts with location when available
- Continues after dismissing the app from Recents, but not after Android force-stop or device reboot

### ⏱️ Persistent Check-In
- Arms a deadline that survives app backgrounding; if it expires, the foreground service raises SOS
- Automatic SMS is sent only when enabled and SMS permission is granted

### 📍 Time-Limited Live Location
- Sends an initial map link, then updated map links at the selected interval
- Stops automatically after the selected duration; user can stop earlier
- Requires SMS permission, foreground location, and Android “Allow all the time” location permission
- SMS and carrier charges may apply; no location server or cloud account is used

### ⚡ Quick Settings SOS Tile
- Add “Awaaz SOS” from Android’s Quick Settings tile editor for a one-tap SOS shortcut
- Lock-screen access varies by Android version and device security settings

### 🚨 Multi-Trigger SOS
| Trigger | How |
|---------|-----|
| 🗣️ Voice | Say "Help me now" / "Bachao" |
| 👆 Tap | Tap the big red SOS button |
| 📳 Shake | Shake phone 3× within 1.5 seconds |
| 🤫 Silent | Hold the shield logo 3 seconds (zero sound) |

### 📍 GPS + WhatsApp Alert
- Captures GPS in 5–8s (high accuracy first, falls back to network)
- Opens a Google Maps link to trusted contacts through WhatsApp; the user taps Send
- Optional automatic SMS sends a shorter SOS and map link directly to saved contacts
- Alert message includes coordinates, timestamp, emergency numbers
- Fallback: WhatsApp or direct call buttons if SMS is disabled or unavailable

### ✅ Contact Readiness Test
- Enable **Contact test alerts** in Settings to reveal the manual test action in Tools
- The feature is off by default and always asks for confirmation before contacting saved people
- Test messages are clearly labeled, contain no location, and do not start an SOS
- Direct SMS is used only when automatic SMS is enabled; otherwise WhatsApp opens a draft for you to send

### 🎙️ Audio Evidence Vault
- Recording is off by default; enable “Encrypted audio evidence” in Settings to opt in
- Encrypts saved recordings with AES-GCM and stores the key in Android secure storage
- Share decrypts to a temporary file and removes that copy after sharing
- Recording is limited to 10 minutes per SOS; legacy unencrypted recordings can be encrypted from the Vault
- 128kbps AAC — clear voice quality
- Shows live recording duration on SOS screen

### 👥 Trusted Contacts (up to 5)
- Indian phone validation (+91, 10-digit)
- Priority ordering (1 → 5)
- Edit/delete with one tap

### 📞 Fake Call Screen
- Pretend you're on a call to escape situations
- Choose caller: Maa / Dad / Didi / Bhai / 112 Control Room
- 0s / 5s / 10s / 30s delay
- Live call timer display

### 🏥 Emergency Helplines
- One-tap dial: **112** (Emergency) · **181** (Women) · **100** (Police) · **108** (Ambulance)

### 🔇 Silent SOS Mode
- Zero audio output — camera-off stealth mode
- Heavy vibration siren (triple haptic pulses)
- No TTS announcements

---

## 🔒 Security

| Feature | Status |
|---------|--------|
| Root detection | ✅ Warns user |
| Screenshot prevention | ✅ FLAG_SECURE via System |
| Encrypted audio | ✅ AES-GCM; opt-in; device-held key |
| Location sharing | ✅ SMS only to user-selected contacts; no server |
| SMS destinations | ✅ Validated in Dart and again in the Android bridge |
| Contact storage | ⚠️ Local app storage; not encrypted at rest |
| Reduced-permission default | ✅ Standard APK omits SMS and background-location permissions |
| No analytics/tracking | ✅ Zero data collection |
| Offline-first | ✅ Works with no internet |

Emergency and live-location SMS leave the phone through the cellular carrier when enabled. Automatic SMS requires Android’s restricted `SEND_SMS` permission, and continuous sharing requires background location. Google Play may restrict these permissions; this project’s APK is intended for direct installation. Force-stop, battery restrictions, or manufacturer task-killing can stop background work.

---

## 🏗️ Architecture

```
lib/main.dart (Flutter app and service layer)
├── _BgHandler                — Background shake, check-in, and live-share tasks
├── StorageService            — SharedPreferences (contacts, settings)
├── TtsService                — flutter_tts (en-IN, rate 0.52)
├── LocationService           — geolocator (high-acc + network fallback)
├── RecordingService          — record (AAC 128kbps)
├── AwaazSms                  — native bridge with a +91 destination allowlist
├── EvidenceStorage           — AES-GCM files + Android secure key storage
├── SosTileService            — Android Quick Settings SOS tile
├── SecurityService           — Root detection
├── HomeScreen                — Main UI + shake/voice guard
├── SosActiveScreen           — Active SOS countdown + dispatch
└── FakeCallScreen            — Fake call UI
```

---

## 📦 Stack

| Layer | Technology |
|-------|-----------|
| Framework | Flutter 3.27.1 |
| Language | Dart 3.3+ |
| Background | flutter_foreground_task 8.11 |
| Voice | Offline Vosk Indian-English model |
| TTS | flutter_tts 4.0.2 |
| GPS | geolocator 13.0.2 |
| Audio | record 6.0.0 |
| Sensors | sensors_plus 5.0.1 |
| Storage | shared_preferences + flutter_secure_storage |
| Permissions | permission_handler 11.3.1 |
| Build | GitHub Actions + Flutter 3.27.1 + Java 17 |

---

## 🏃 Build Locally

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --debug --flavor standard --target-platform android-arm64 --dart-define=AUTO_SMS_ENABLED=false
# Standard APK: build/app/outputs/flutter-apk/app-standard-debug.apk
flutter build apk --debug --flavor autoSms --target-platform android-arm64 --dart-define=AUTO_SMS_ENABLED=true
# Auto-SMS APK: build/app/outputs/flutter-apk/app-autosms-debug.apk
```

The workflow artifacts are for testing. Attach the chosen, privately signed APK variant to **GitHub Releases** for public downloads; keep release signing keys out of Git and Actions logs.

---

## 🏆 Hackathon

Built for the **Wispr Flow × Scaler AI Voice Hackathon**

**Team CTRL ALT ELITE**

> *Made with ❤️ in India*

---

<div align="center">
<sub>Offline-ready · Local storage only · No tracking · No cloud · Open source</sub>
</div>