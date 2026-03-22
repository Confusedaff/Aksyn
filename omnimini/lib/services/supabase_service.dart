import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

// ── Change to your server's LAN IP ───────────────────────────────
const String _backendBase = 'http://100.95.213.57:8000';
// ─────────────────────────────────────────────────────────────────

class SupabaseService {
  late SupabaseClient _client;

  Future<void> initialize() async {
    _client = Supabase.instance.client;
  }

  // ── Fetch all recordings from backend (loads on app start) ─────

  Future<List<RecordingMeta>> fetchRecordings() async {
    try {
      final resp = await http.get(Uri.parse('$_backendBase/recordings'));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final list = data['recordings'] as List<dynamic>;
        return list.map((e) => RecordingMeta.fromJson(e as Map<String, dynamic>)).toList();
      }
    } catch (e) {
      print('fetchRecordings error: $e');
    }
    return [];
  }

  // ── Fetch alerts for a specific recording ──────────────────────

  Future<List<AlertMeta>> fetchAlerts(String fileName) async {
    try {
      final encoded = Uri.encodeComponent(fileName);
      final resp = await http.get(
          Uri.parse('$_backendBase/recordings/$encoded/alerts'));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final list = data['alerts'] as List<dynamic>;
        return list.map((e) => AlertMeta.fromJson(e as Map<String, dynamic>)).toList();
      }
    } catch (e) {
      print('fetchAlerts error: $e');
    }
    return [];
  }

  // ── Legacy direct upload (kept for fallback) ───────────────────

  Future<String> uploadAudioFile(String filePath,
      {Function(double)? onProgress}) async {
    final file = File(filePath);
    if (!file.existsSync()) throw Exception('File does not exist');

    final fileName = 'recording_${const Uuid().v4()}.wav';
    final bucket = _client.storage.from('audio-recordings');

    final response = await bucket.upload(
      fileName, file,
      fileOptions: const FileOptions(cacheControl: '3600', upsert: false),
    );
    if (response.isNotEmpty) {
      return bucket.getPublicUrl(fileName);
    }
    throw Exception('Upload failed');
  }
}

// ─────────────────────────────────────────────────────────────────
// DATA MODELS
// ─────────────────────────────────────────────────────────────────

class RecordingMeta {
  final String  fileName;
  final String  publicUrl;
  final double  durationSeconds;
  final int     alertCount;
  final DateTime createdAt;

  RecordingMeta({
    required this.fileName,
    required this.publicUrl,
    required this.durationSeconds,
    required this.alertCount,
    required this.createdAt,
  });

  factory RecordingMeta.fromJson(Map<String, dynamic> j) => RecordingMeta(
        fileName:        j['file_name']        as String? ?? '',
        publicUrl:       j['public_url']       as String? ?? '',
        durationSeconds: (j['duration_seconds'] as num?)?.toDouble() ?? 0,
        alertCount:      j['alert_count']      as int?    ?? 0,
        createdAt:       DateTime.tryParse(j['created_at'] as String? ?? '') ??
                         DateTime.now(),
      );

  Duration get duration =>
      Duration(milliseconds: (durationSeconds * 1000).round());

  String get dateLabel {
    final d = createdAt.toLocal();
    return '${d.hour.toString().padLeft(2, '0')}:'
           '${d.minute.toString().padLeft(2, '0')}  ·  '
           '${d.day}/${d.month}/${d.year}';
  }
}

class AlertMeta {
  final String  source;
  final String  label;
  final double? confidence;
  final String? transcript;
  final DateTime triggeredAt;

  AlertMeta({
    required this.source,
    required this.label,
    this.confidence,
    this.transcript,
    required this.triggeredAt,
  });

  factory AlertMeta.fromJson(Map<String, dynamic> j) => AlertMeta(
        source:      j['source']     as String? ?? '',
        label:       j['label']      as String? ?? '',
        confidence:  (j['confidence'] as num?)?.toDouble(),
        transcript:  j['transcript'] as String?,
        triggeredAt: DateTime.tryParse(j['triggered_at'] as String? ?? '') ??
                     DateTime.now(),
      );

  bool get isKeyword => source.contains('STT');
  String get confidenceLabel =>
      confidence != null ? '${(confidence! * 100).toStringAsFixed(0)}%' : '';
}