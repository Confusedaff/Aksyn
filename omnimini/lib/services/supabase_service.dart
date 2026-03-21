import 'dart:io';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

class SupabaseService {
  late SupabaseClient _client;

  Future<void> initialize() async {
    _client = Supabase.instance.client;
  }

  Future<String> uploadAudioFile(String filePath, {Function(double)? onProgress}) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw Exception('File does not exist');
    }

    final fileName = 'recording_${const Uuid().v4()}.wav';
    final bucket = _client.storage.from('audio-recordings');

    try {
      final response = await bucket.upload(
        fileName,
        file,
        fileOptions: const FileOptions(
          cacheControl: '3600',
          upsert: false,
        ),
      );

      if (response.isNotEmpty) {
        // Get public URL
        final publicUrl = bucket.getPublicUrl(fileName);
        return publicUrl;
      } else {
        throw Exception('Upload failed');
      }
    } catch (e) {
      throw Exception('Upload error: $e');
    }
  }

  Future<void> signInAnonymously() async {
    // For anonymous auth, you can skip if using anon key
    // If you need auth, implement email/password or other methods
  }
}