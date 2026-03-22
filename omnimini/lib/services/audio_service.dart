import 'dart:async';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';

class AudioService {
  final AudioRecorder _recorder = AudioRecorder();
  String? _currentPath;

  AudioRecorder get recorder => _recorder;

  Future<void> initialize() async {
    final status = await Permission.microphone.request();
    if (!status.isGranted) throw Exception('Microphone permission denied');
  }

  /// Start recording to a local WAV file (for upload-after-stop mode)
  Future<String> startRecording() async {
    if (!await _recorder.hasPermission()) {
      throw Exception('No microphone permission');
    }
    final directory = await getTemporaryDirectory();
    _currentPath =
        '${directory.path}/recording_${DateTime.now().millisecondsSinceEpoch}.wav';

    const config = RecordConfig(
      encoder: AudioEncoder.wav,
      sampleRate: 44100,
      bitRate: 128000,
      numChannels: 1,
    );

    await _recorder.start(config, path: _currentPath!);
    return _currentPath!;
  }

  /// Start recording AND return a stream of raw PCM bytes (for live streaming)
  /// Each event is a Uint8List of raw int16 PCM at 44100 Hz mono.
  Future<Stream<Uint8List>> startStreamingRecording() async {
    if (!await _recorder.hasPermission()) {
      throw Exception('No microphone permission');
    }

    const config = RecordConfig(
      encoder: AudioEncoder.pcm16bits, // raw int16 PCM — no WAV header
      sampleRate: 44100,
      numChannels: 1,
    );

    final stream = await _recorder.startStream(config);
    return stream;
  }

  Future<void> stopRecording() async {
    await _recorder.stop();
  }

  String? get currentRecordingPath => _currentPath;

  Future<void> dispose() async {
    await _recorder.dispose();
  }
}