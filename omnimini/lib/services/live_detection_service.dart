import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:uuid/uuid.dart';

/// Connects to the Python FastAPI WebSocket, streams PCM audio chunks,
/// and surfaces detection alerts in real time.
class LiveDetectionService {
  // ── Change this to your server IP/hostname ───────────────────
  static const String _serverHost = '192.168.1.37'; // ← your machine's LAN IP
  static const int    _serverPort = 8000;
  // ─────────────────────────────────────────────────────────────

  WebSocketChannel? _channel;
  StreamSubscription? _wsSubscription;
  final _alertController = StreamController<DetectionAlert>.broadcast();
  final _statusController = StreamController<StreamStatus>.broadcast();

  Stream<DetectionAlert> get alerts => _alertController.stream;
  Stream<StreamStatus>   get status => _statusController.stream;

  bool _connected = false;
  String? _currentFileName;

  /// Connect to the WebSocket server
  Future<void> connect() async {
    final uri = Uri.parse('ws://$_serverHost:$_serverPort/ws/stream');
    _channel  = WebSocketChannel.connect(uri);
    _connected = true;
    _currentFileName = 'recording_${const Uuid().v4()}.wav';
    _statusController.add(StreamStatus.connected);

    _wsSubscription = _channel!.stream.listen(
      (message) {
        try {
          final json = jsonDecode(message as String) as Map<String, dynamic>;
          final type = json['type'] as String?;

          if (type == 'alert') {
            _alertController.add(DetectionAlert.fromJson(json));
          } else if (type == 'done') {
            _statusController.add(StreamStatus.done);
          } else if (type == 'error') {
            _statusController.add(StreamStatus.error);
          }
        } catch (_) {}
      },
      onError: (e) {
        _connected = false;
        _statusController.add(StreamStatus.error);
      },
      onDone: () {
        _connected = false;
        _statusController.add(StreamStatus.disconnected);
      },
    );
  }

  /// Send a raw PCM chunk to the server
  void sendChunk(Uint8List pcmBytes) {
    if (_connected && _channel != null) {
      _channel!.sink.add(pcmBytes);
    }
  }

  /// Signal that recording is complete — server will save the file
  Future<void> endStream() async {
    if (_connected && _channel != null) {
      _channel!.sink.add('END:$_currentFileName');
      await Future.delayed(const Duration(milliseconds: 500));
    }
  }

  Future<void> disconnect() async {
    _connected = false;
    await _wsSubscription?.cancel();
    await _channel?.sink.close();
    _channel = null;
  }

  Future<void> dispose() async {
    await disconnect();
    await _alertController.close();
    await _statusController.close();
  }
}

// ─────────────────────────────────────────────────────────────────
// DATA MODELS
// ─────────────────────────────────────────────────────────────────

class DetectionAlert {
  final String source;
  final String label;
  final double? confidence;
  final String? transcript;
  final DateTime time;

  DetectionAlert({
    required this.source,
    required this.label,
    this.confidence,
    this.transcript,
    DateTime? time,
  }) : time = time ?? DateTime.now();

  factory DetectionAlert.fromJson(Map<String, dynamic> json) {
    return DetectionAlert(
      source:     json['source']     as String? ?? 'Unknown',
      label:      json['label']      as String? ?? 'Unknown',
      confidence: (json['confidence'] as num?)?.toDouble(),
      transcript: json['transcript'] as String?,
    );
  }

  String get confidenceLabel =>
      confidence != null ? '${(confidence! * 100).toStringAsFixed(0)}%' : '';

  bool get isKeyword => source.contains('STT');
  bool get isSound   => source.contains('YAMNet');
}

enum StreamStatus { idle, connected, done, disconnected, error }