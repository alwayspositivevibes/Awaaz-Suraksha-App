# 🛡️ AWAAZ Suraksha (आवाज़ सुरक्षा)
### Voice-First Native Emergency SOS System for Women Safety in India

[![Built for](https://img.shields.io/badge/Hackathon-Wispr_Flow_x_Scaler_AI_Voice-ff4b4b?style=for-the-badge)](https://scaler.com)
[![Platform](https://img.shields.io/badge/Platform-Android_Native_(Flutter)-02569B?style=for-the-badge&logo=flutter&logoColor=white)](https://flutter.dev)
[![Architecture](https://img.shields.io/badge/Architecture-Zero--Cloud_/_Zero--API_Keys-10B981?style=for-the-badge)](#zero-backend-guarantee)
[![Build Status](https://img.shields.io/badge/Build-GitHub_Actions_CI-success?style=for-the-badge&logo=githubactions&logoColor=white)](#automated-apk-builds)

---

## 📌 Problem Statement & Innovation
In high-stress emergency situations, victims cannot unlock their phones, browse contacts, or type messages. Most existing SOS tools fail because:
1. **Physical Interaction Dependency:** Require unlocking device & navigating UI.
2. **Cloud/Server Latency:** Rely on paid cloud APIs (Twilio/AWS) which fail without stable internet or active credits.
3. **Background Limitations:** Web browsers block microphone & GPS when minimized or screen-locked.

**AWAAZ Suraksha solves this at the native hardware level:**
A zero-cloud, 100% on-device Android safety system that listens continuously in the background using Android **Foreground Services**, triggering multi-channel emergency dispatches, high-accuracy GPS coordinates, and covert audio evidence recording via simple voice commands.

---

## ⚡ How It Works (The Emergency Pipeline)

```
[ 🎙️ Background Voice Guard (Foreground Service) ]
                  │
                  ▼  Hears: "Help me now" / "Bachao" / "SOS Help"
[ ⏱️ 5-Second Fail-Safe Countdown (Bilingual Voice Alert) ]
       │                                     │
       ├─ If Safe: "I'm safe" ──► CANCELLED   │ (No cancel within 5s)
       │                                     ▼
[ 🚨 ACTIVE SOS STATE ENGAGED ]
  ├── 📍 GPS Capture (High-accuracy satellite + network fallback)
  ├── 💬 WhatsApp Multi-Dispatch (Pre-filled live maps link to trusted contacts)
  ├── 🎙️ Local Audio Evidence Recording (.m4a secure local storage)
  └── 📞 Quick Access to Indian Emergency Helplines (112, 181, 100, 108)
```

---

## 🎯 Key Features

<details open>
<summary><b>1. 🎙️ Background Voice Detection (True On-Device Guard)</b></summary>
<br>

- Uses Android **Foreground Service** (`microphone|location` foreground service types).
- Stays active when the app is minimized, swapped out, or screen-locked.
- **Wake Phrases:**
  - `"Help me now"`
  - `"Bachao"` (Devanagari: `बचाओ` & Hinglish)
  - `"SOS help"`
  - `"Awaaz help me"` / phonetic variations
- **Deactivation Phrase:** `"I'm safe"` / `"Cancel SOS"`
</details>

<details open>
<summary><b>2. 📍 High-Accuracy Instant GPS Capture</b></summary>
<br>

- Queries dual-provider location (GPS Satellite + Network Triangulation).
- Formats direct Google Maps navigation coordinates: `https://maps.google.com/?q=LAT,LNG`.
- Included directly in the emergency alert payload.
</details>

<details open>
<summary><b>3. 💬 Zero-Cost WhatsApp Emergency Dispatch</b></summary>
<br>

- Directly utilizes the native `wa.me` deep-linking URL scheme.
- Zero SMS gateway fees, zero Twilio API keys, zero reliance on external third-party servers.
- Broadcasts to all user-configured emergency contacts with one tap.
</details>

<details open>
<summary><b>4. 📼 Covert Evidence Recording</b></summary>
<br>

- Activates on-device audio recording (`.m4a`) the second an SOS is confirmed.
- Stored locally in app sandbox storage for evidentiary use.
</details>

<details open>
<summary><b>5. 🚨 Indian Emergency Quick-Dial</b></summary>
<br>

- **112** — National Emergency All-In-One Number
- **181** — National Women Helpline
- **100** — Police Control Room
- **108** — Disaster & Ambulance Services
</details>

<details open>
<summary><b>6. 🎭 Discrete Features: Fake Call & Shake-to-SOS</b></summary>
<br>

- **Shake Detection:** Built-in 3-axis accelerometer sensor triggers countdown when shaken violently.
- **Fake Call Generator:** Simulates a realistic incoming call screen with ringtone to excuse oneself from unsafe environments.
</details>

---

## 🛡️ Zero-Backend Architecture Guarantee

| Concern | How AWAAZ Suraksha Handles It |
| :--- | :--- |
| **Privacy** | Audio processing is 100% on-device via native speech engines. Nothing is recorded or uploaded to any cloud server. |
| **Cost** | 0 cloud subscriptions, 0 database fees, 0 SMS fees. |
| **Reliability** | Operates even in low network conditions; core alarms, recording, and location tracking require no cloud servers. |

---

## 🛠️ Tech Stack & Native APIs

- **Framework:** Flutter (Android SDK 36, compileSdk 36, minSdk 24)
- **Speech Engine:** `speech_to_text` (Native Android SpeechRecognizer)
- **Voice Feedback:** `flutter_tts` (Local Text-to-Speech Engine)
- **Background Daemon:** `flutter_foreground_task` (Android Foreground Service with `WAKE_LOCK`)
- **Sensor Telemetry:** `sensors_plus` (Hardware Accelerometer)
- **Geolocation:** `geolocator` (FusedLocationProviderClient)
- **Audio Capture:** `record` (AAC/M4A Local Audio Recorder)
- **CI/CD:** Automated cloud APK builds via **GitHub Actions** (`ubuntu-latest`)

---

## 📦 Automated APK Builds

Every commit to `main` builds a sideloadable Android ARM64 APK automatically:

1. Go to the **Actions** tab in this repository.
2. Select the latest workflow run.
3. Download the **`awaaz-sos-debug-apk`** artifact.
4. Extract the `.zip` and sideload the `.apk` on any Android device running Android 7.0 (Nougat) or newer.

---

## 👩‍💻 Author
**Wispr Flow × Scaler AI Voice Hackathon Submission**  
Built by a 1st Semester Electronics & Communication Engineering student.
