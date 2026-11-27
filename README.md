# AWAAZ Suraksha — Voice-First Native Android SOS App

> **Wispr Flow × Scaler AI Voice Hackathon** | Native Flutter Android app with **background voice wake-word detection** (`"Awaaz help me"`), GPS tracking, WhatsApp SOS dispatch, and audio evidence recording.

---

## Key Features

- **Background Voice Guard** — Runs as an Android Foreground Service (`microphone|location`), listening for `"Awaaz help me"` (English + Hinglish) even when the app is minimized or the screen is locked.
- **5-Second SOS Countdown** — Voice-announced countdown with instant **CANCEL SOS** or voice deactivation (`"Awaaz I'm safe"`).
- **Live GPS Capture** — High-accuracy GPS with network fallback and Google Maps link included in alerts.
- **One-Tap WhatsApp SOS** — Dispatches emergency message + live location link to all trusted contacts via `wa.me`.
- **Audio Evidence Recording** — Automatically records `.m4a` audio during an active SOS.
- **Fake Call & Shake-to-SOS** — Trigger a realistic incoming call screen or shake the phone to activate SOS.
- **Indian Emergency Helplines** — Quick-dial buttons for **112** (National Emergency), **181** (Women Helpline), **100** (Police), and **108** (Ambulance).

---

## Building the APK (GitHub Actions)

No local Flutter SDK required — GitHub Actions builds the Android APK automatically on every push:

1. Push this repository to GitHub.
2. Open the **Actions** tab in your GitHub repo.
3. Click the latest **Build AWAAZ Suraksha APK** workflow run.
4. Download the **`awaaz-sos-debug-apk`** artifact and install the `.apk` on your Android phone.
