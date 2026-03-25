# 🔊 Aksyn — Hybrid Audio Detection System

> **Aksyn** is a real-time audio threat detection platform combining a Python AI backend with a Flutter mobile frontend. It uses OpenAI Whisper for speech-to-text and Google YAMNet for audio event classification to detect distress signals, emergency keywords, and dangerous sounds — all streamed live or from uploaded clips.

---

## 📱 App Screenshots
<table>
  <tr>
    <td align="center"><b>Splash Screen</b></td>
    <td align="center"><b>Loading</b></td>
    <td align="center"><b>Ready State</b></td>
    <td align="center"><b>Live Recording</b></td>
  </tr>
  <tr>
    <td align="center"><img src="https://github.com/user-attachments/assets/6d860c8a-c5b7-4791-a914-402882144290" width="160"/></td>
    <td align="center"><img src="https://github.com/user-attachments/assets/4ca60a15-c3fc-4680-8376-6b8a5b38fab3" width="160"/></td>
    <td align="center"><img src="https://github.com/user-attachments/assets/d89ffb4e-53be-4b05-a19d-73d882453d07" width="160"/></td>
    <td align="center"><img src="https://github.com/user-attachments/assets/e1ced86a-5ada-4718-8cea-6cee85f0a47a" width="160"/></td>
  </tr>
</table>

---

## 🧠 How It Works

The system runs two parallel AI detectors on every audio chunk:

| Detector | Model | Detects |
|---|---|---|
| **STT** | OpenAI Whisper | Emergency keywords ("help", "fire", "call 911", etc.) |
| **Sound** | Google YAMNet | Audio events (screaming, gunshots, alarms, glass breaking, etc.) |

Audio is split into **4-second chunks with 1-second overlap**, processed in parallel threads, and alerts are fired immediately when a threat is detected. Results are logged to a **Supabase** database.

---

## 🗂️ Repository Structure

```
Aksyn/
├── Backend/                  # Python AI detection engine
│   ├── hybrid_audio_detector.py
│   ├── Dockerfile
│   ├── requirements.txt
│   └── .env                  # (you create this — see below)
└── omnimini/                 # Flutter mobile app
    ├── lib/
    ├── android/
    ├── ios/
    └── pubspec.yaml
```

---

## ⚙️ Prerequisites

Make sure the following are installed on your machine:

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (v4.x or later)
- [Flutter SDK](https://flutter.dev/docs/get-started/install) (v3.x or later)
- [Git](https://git-scm.com/)
- A [Supabase](https://supabase.com/) account (free tier works)

---

## 🛠️ Supabase Setup

Before running the app, set up your Supabase project:

### 1. Create a Storage Bucket

In the Supabase dashboard → **Storage** → create a bucket named `audio-clips`.

### 2. Create the Required Tables

Run the following SQL in the **Supabase SQL Editor**:

```sql
-- Stores detection alert results
CREATE TABLE audio_detections (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    file_name text,
    source text,
    label text,
    confidence float,
    transcript text,
    triggered_at timestamptz DEFAULT now()
);

-- Tracks which uploaded files have been processed
CREATE TABLE processed_audio (
    file_name text PRIMARY KEY,
    processed_at timestamptz DEFAULT now()
);
```

### 3. Get Your Credentials

Go to **Project Settings → API** and copy:
- **Project URL** (e.g. `https://xxxx.supabase.co`)
- **Service Role Key** (use the `service_role` secret key)

---

## 🐳 Running the Backend (Docker)

The Python backend runs as a Docker container. It automatically polls Supabase for new audio files when environment variables are set, or falls back to live microphone mode.

### Docker Desktop showing the backend container running
<img src="https://github.com/user-attachments/assets/942b7b6f-1daf-4bd9-9029-92d07eed209f" width="100%"/>

### Step 1 — Clone the Repository

```bash
git clone https://github.com/Confusedaff/Aksyn.git
cd Aksyn/Backend
```

### Step 2 — Create the `.env` File

Create a file called `.env` inside the `Backend/` folder:

```env
SUPABASE_URL=https://your-project-id.supabase.co
SUPABASE_KEY=your-service-role-key
SUPABASE_BUCKET=audio-clips
POLL_INTERVAL=10
```

> ⚠️ Never commit your `.env` file. It is already listed in `.gitignore`.

### Step 3 — Build the Docker Image

```bash
docker build -t aksyn-backend .
```

### Step 4 — Run the Container

**Supabase polling mode** (recommended — processes uploaded audio files automatically):

```bash
docker run --env-file .env aksyn-backend
```

**File mode** (analyse a single local WAV file):

```bash
docker run --env-file .env -v /path/to/audio:/audio aksyn-backend /audio/yourfile.wav
```

**Live microphone mode** (no env vars needed):

```bash
docker run --device /dev/snd aksyn-backend
```

> 💡 You can monitor the running container in **Docker Desktop** under the **Containers** tab.

---

## 📱 Running the Flutter App (omnimini)

The Flutter frontend (`omnimini`) records audio, uploads clips to Supabase, and displays live detection results.

### Step 1 — Install Flutter Dependencies

```bash
cd Aksyn/omnimini
flutter pub get
```

### Step 2 — Configure Supabase in the App

Open `lib/main.dart` (or your Supabase config file) and set your project URL and anon key:

```dart
await Supabase.initialize(
  url: 'https://your-project-id.supabase.co',
  anonKey: 'your-anon-public-key',
);
```

> Use the **anon/public** key here (not the service role key).

### Step 3 — Run on a Device or Emulator

```bash
flutter run
```

Or build a release APK for Android:

```bash
flutter build apk --release
```

---

## 🚀 Running on Another Device

To run the full stack on a new machine:

1. **Install Docker Desktop** and **Flutter SDK** on the target device.
2. **Clone the repo**: `git clone https://github.com/Confusedaff/Aksyn.git`
3. **Create the `.env`** file in `Backend/` with your Supabase credentials (see above).
4. **Build and run the backend container**: `docker build -t aksyn-backend . && docker run --env-file .env aksyn-backend`
5. **Set up the Flutter app**: `cd omnimini && flutter pub get && flutter run`

The backend and frontend both connect independently to Supabase, so no local networking between them is required.

---

## 🔑 Environment Variables Reference

| Variable | Description | Default |
|---|---|---|
| `SUPABASE_URL` | Your Supabase project URL | — |
| `SUPABASE_KEY` | Service role secret key | — |
| `SUPABASE_BUCKET` | Storage bucket name | `audio-clips` |
| `POLL_INTERVAL` | Seconds between bucket polls | `10` |

---

## 🐛 Troubleshooting

**Models loading slowly on first run**
Whisper and YAMNet are downloaded on first run. This may take a few minutes. Subsequent starts will use the cached models.

**`sounddevice` errors in Docker**
Live mic mode requires audio device passthrough (`--device /dev/snd`). This is Linux-only. On macOS/Windows, use Supabase polling mode instead.

**YAMNet class labels fetch fails**
The container needs internet access to download YAMNet labels from GitHub on startup. If behind a firewall, pre-bundle the CSV or provide it as a volume mount.

**Flutter build errors**
Run `flutter doctor` to check your environment. Make sure you have the Android SDK configured if targeting Android.

---
