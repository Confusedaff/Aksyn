import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';

class AudioService {
  final AudioRecorder _recorder = AudioRecorder();
  String? _currentPath;

  // Expose recorder so the screen can call getAmplitude() on the SAME instance
  AudioRecorder get recorder => _recorder;

  Future<void> initialize() async {
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      throw Exception('Microphone permission denied');
    }
  }

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
    );

    await _recorder.start(config, path: _currentPath!);
    return _currentPath!;
  }

  Future<void> stopRecording() async {
    await _recorder.stop();
  }

  String? get currentRecordingPath => _currentPath;

  Future<void> dispose() async {
    await _recorder.dispose();
  }
}