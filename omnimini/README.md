# Audio Recorder App

A Flutter application that records audio from the microphone and uploads it to Supabase Storage.

## Features

- Record audio from microphone
- Save recordings locally
- Upload to Supabase Storage
- Display upload progress
- List uploaded recordings
- Playback recordings

## Setup

### Prerequisites

- Flutter SDK (latest stable version)
- Supabase account

### Flutter Setup

1. Install Flutter: https://flutter.dev/docs/get-started/install
2. Clone or download this project
3. Run `flutter pub get` to install dependencies

### Supabase Setup

1. Create a new Supabase project at https://supabase.com
2. Go to Settings > API to get your Project URL and anon key
3. Create a new storage bucket named "audio-recordings"
4. Set the bucket to public (for simplicity, or configure RLS policies)

### Configuration

In `lib/main.dart`, replace the placeholders with your Supabase credentials:

```dart
await Supabase.initialize(
  url: 'YOUR_SUPABASE_URL',
  anonKey: 'YOUR_SUPABASE_ANON_KEY',
);
```

## Platform Setup

### Android

Add microphone permission to `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" />
```

### iOS

Add microphone permission to `ios/Runner/Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>This app needs microphone access to record audio</string>
```

## Running the App

1. Ensure you have a connected device or emulator
2. Run `flutter run` in the project directory

## Usage

1. Tap "Start Recording" to begin recording
2. Tap "Stop Recording" to stop
3. The app will automatically upload the recording to Supabase
4. View uploaded recordings in the list below
5. Tap play button to open the recording URL

## Dependencies

- supabase_flutter: ^2.0.0
- record: ^5.0.0
- permission_handler: ^11.0.0
- just_audio: ^0.9.0
- path_provider: ^2.0.0
- uuid: ^4.0.0

## Code Structure

- `lib/main.dart`: App entry point and Supabase initialization
- `lib/screens/audio_recorder_screen.dart`: Main UI screen
- `lib/services/audio_service.dart`: Audio recording functionality
- `lib/services/supabase_service.dart`: Supabase upload service

## Notes

- Recordings are saved temporarily on device
- Files are uploaded as WAV format
- Unique filenames are generated using UUID
- Public URLs are displayed for uploaded files