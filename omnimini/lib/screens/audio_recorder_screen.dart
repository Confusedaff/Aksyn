import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import '../services/audio_service.dart';
import '../services/supabase_service.dart';
import '../services/live_detection_service.dart';
import '../widgets/app_theme.dart';
import '../widgets/recorder_header.dart';
import '../widgets/record_button.dart';
import '../widgets/waveform_strip.dart';
import '../widgets/status_chip.dart';
import '../widgets/live_alert_feed.dart';
import '../widgets/recordings_list.dart';
import '../widgets/alerts_widgets.dart';

enum RecordingStatus { stopped, recording, uploading, uploaded }

class AudioRecorderScreen extends StatefulWidget {
  const AudioRecorderScreen({super.key});

  @override
  State<AudioRecorderScreen> createState() => _AudioRecorderScreenState();
}

class _AudioRecorderScreenState extends State<AudioRecorderScreen>
    with TickerProviderStateMixin {

  // ── Services ───────────────────────────────────────────────────
  final AudioService         _audioService     = AudioService();
  final SupabaseService      _supabaseService  = SupabaseService();
  final LiveDetectionService _detectionService = LiveDetectionService();
  final AudioPlayer          _audioPlayer      = AudioPlayer();

  // ── State ──────────────────────────────────────────────────────
  RecordingStatus _status = RecordingStatus.stopped;

  /// Mixed list of [RecordingMeta] and [PendingRecording] entries.
  List<dynamic> _recordings = [];
  List<DetectionAlert> _liveAlerts = [];

  bool    _isInitialized = false;
  String? _initError;
  int?    _playingIndex;

  // ── Playback ───────────────────────────────────────────────────
  double   _playbackProgress = 0.0;
  Duration _playbackPosition = Duration.zero;
  Duration _playbackTotal    = Duration.zero;
  StreamSubscription? _positionSub, _durationSub, _playerStateSub;

  // ── Waveform ───────────────────────────────────────────────────
  double _amplitude = 0.0;
  Timer? _amplitudeTimer;
  final List<double> _waveBarHeights = List.filled(28, 0.0);
  final _rand = Random();

  // ── Detection streams ──────────────────────────────────────────
  StreamSubscription? _alertSub, _statusSub, _doneSub;

  // ── Animation ─────────────────────────────────────────────────
  late AnimationController _pulseController;
  late Animation<double>   _pulseAnimation;

  // ── Lifecycle ─────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.12).animate(
        CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut));
    _initializeServices();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _stopAmplitudeTimer();
    _cancelPlaybackStreams();
    _audioPlayer.dispose();
    _audioService.dispose();
    _alertSub?.cancel();
    _statusSub?.cancel();
    _doneSub?.cancel();
    _detectionService.dispose();
    super.dispose();
  }

  Future<void> _initializeServices() async {
    try {
      await _audioService.initialize();
      await _supabaseService.initialize();
      final saved = await _supabaseService.fetchRecordings();
      if (mounted) {
        setState(() {
          _recordings    = List<dynamic>.from(saved);
          _isInitialized = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() { _initError = e.toString(); _isInitialized = true; });
      }
    }
  }

  // ── Amplitude helpers ──────────────────────────────────────────

  void _startAmplitudeTimer() {
    _amplitudeTimer?.cancel();
    _amplitudeTimer =
        Timer.periodic(const Duration(milliseconds: 80), (_) async {
      if (!mounted || !_isRecording) return;
      try {
        final amp        = await _audioService.recorder.getAmplitude();
        final db         = amp.current.clamp(-60.0, 0.0);
        final normalised = ((db + 60) / 60).clamp(0.0, 1.0);
        if (mounted) {
          setState(() {
            _amplitude = normalised;
            for (int i = 0; i < _waveBarHeights.length - 1; i++) {
              _waveBarHeights[i] = _waveBarHeights[i + 1];
            }
            _waveBarHeights[_waveBarHeights.length - 1] =
                (normalised + _rand.nextDouble() * 0.06).clamp(0.04, 1.0);
          });
        }
      } catch (_) {}
    });
  }

  void _stopAmplitudeTimer() {
    _amplitudeTimer?.cancel();
    _amplitudeTimer = null;
    if (mounted) {
      setState(() {
        _amplitude = 0.0;
        for (int i = 0; i < _waveBarHeights.length; i++) {
          _waveBarHeights[i] = 0.0;
        }
      });
    }
  }

  // ── Playback ───────────────────────────────────────────────────

  void _attachPlaybackStreams() {
    _cancelPlaybackStreams();
    _durationSub = _audioPlayer.durationStream.listen((d) {
      if (mounted) setState(() => _playbackTotal = d ?? Duration.zero);
    });
    _positionSub = _audioPlayer.positionStream.listen((pos) {
      if (!mounted) return;
      final total = _playbackTotal.inMilliseconds;
      setState(() {
        _playbackPosition = pos;
        _playbackProgress =
            total > 0 ? (pos.inMilliseconds / total).clamp(0.0, 1.0) : 0.0;
      });
    });
    _playerStateSub = _audioPlayer.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed && mounted) {
        setState(() {
          _playingIndex     = null;
          _playbackProgress = 0.0;
          _playbackPosition = Duration.zero;
          _playbackTotal    = Duration.zero;
        });
      }
    });
  }

  void _cancelPlaybackStreams() {
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playerStateSub?.cancel();
    _positionSub = _durationSub = _playerStateSub = null;
  }

  Future<void> _playRecording(RecordingMeta meta, int index) async {
    try {
      if (_playingIndex == index) { _stopPlayback(); return; }
      if (meta.publicUrl.isEmpty) {
        _showError('Audio URL not available yet');
        return;
      }
      setState(() {
        _playingIndex     = index;
        _playbackProgress = 0.0;
        _playbackPosition = Duration.zero;
        _playbackTotal    = Duration.zero;
      });
      _attachPlaybackStreams();
      await _audioPlayer.setUrl(meta.publicUrl);
      await _audioPlayer.play();
    } catch (e) {
      setState(() => _playingIndex = null);
      _showError('Playback failed: $e');
    }
  }

  void _stopPlayback() async {
    await _audioPlayer.stop();
    _cancelPlaybackStreams();
    setState(() {
      _playingIndex     = null;
      _playbackProgress = 0.0;
      _playbackPosition = Duration.zero;
      _playbackTotal    = Duration.zero;
    });
  }

  // ── Detection subscriptions ────────────────────────────────────

  void _subscribeToDetection() {
    _alertSub = _detectionService.alerts.listen((alert) {
      if (!mounted) return;
      setState(() => _liveAlerts.insert(0, alert));
      _showAlertBanner(alert);
    });

    _doneSub = _detectionService.onDone.listen((done) {
      if (!mounted) return;
      final meta = RecordingMeta(
        fileName:        done.fileName,
        publicUrl:       done.publicUrl,
        durationSeconds: done.durationSeconds,
        alertCount:      done.alertCount,
        createdAt:       DateTime.now(),
      );
      setState(() {
        _recordings.removeWhere((r) => r is PendingRecording);
        _recordings.insert(0, meta);
        _status = RecordingStatus.uploaded;
      });
      _unsubscribeFromDetection();
      _detectionService.disconnect();
    });

    _statusSub = _detectionService.status.listen((s) {
      if (!mounted) return;
      if (s == StreamStatus.error) _showError('Detection server error');
    });
  }

  void _unsubscribeFromDetection() {
    _alertSub?.cancel();
    _statusSub?.cancel();
    _doneSub?.cancel();
    _alertSub = _statusSub = _doneSub = null;
  }

  // ── Recording controls ─────────────────────────────────────────

  void _startRecording() async {
    if (!_isInitialized) return;
    try {
      setState(() {
        _status = RecordingStatus.recording;
        _liveAlerts.clear();
        _recordings.insert(0, PendingRecording());
      });
      await _detectionService.connect();
      _subscribeToDetection();
      final pcmStream = await _audioService.startStreamingRecording();
      pcmStream.listen((Uint8List chunk) => _detectionService.sendChunk(chunk));
      _startAmplitudeTimer();
    } catch (e) {
      setState(() {
        _status = RecordingStatus.stopped;
        _recordings.removeWhere((r) => r is PendingRecording);
      });
      _showError('Failed to start: $e');
    }
  }

  void _stopRecording() async {
    if (!_isInitialized) return;
    try {
      _stopAmplitudeTimer();
      setState(() { _status = RecordingStatus.uploading; });
      await _audioService.stopRecording();
      // ignore: unawaited_futures
      _detectionService.endStream();

      // Safety timeout: recover if "done" never arrives within 60s
      Future.delayed(const Duration(seconds: 60), () {
        if (!mounted || _status != RecordingStatus.uploading) return;
        setState(() {
          _recordings.removeWhere((r) => r is PendingRecording);
          _status = RecordingStatus.stopped;
        });
        _showError('Server timed out — check backend connection.');
        _unsubscribeFromDetection();
        _detectionService.disconnect();
      });
    } catch (e) {
      setState(() {
        _recordings.removeWhere((r) => r is PendingRecording);
        _status = RecordingStatus.stopped;
      });
      _showError('Failed to stop: $e');
    }
  }

  // ── UI helpers ─────────────────────────────────────────────────

  void _showAlertsSheet(RecordingMeta meta) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => AlertsSheet(
        recording: meta,
        alertsFuture: _supabaseService.fetchAlerts(meta.fileName),
      ),
    );
  }

  void _showAlertBanner(DetectionAlert alert) {
    final color = alert.isKeyword ? AppTheme.accent : AppTheme.gold;
    final icon  = alert.isKeyword ? '🗣' : '🔊';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        Text('$icon  ', style: const TextStyle(fontSize: 16)),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(alert.label.toUpperCase(),
                  style: TextStyle(color: color, fontSize: 12,
                      fontWeight: FontWeight.w700, letterSpacing: 1.5)),
              if (alert.transcript != null)
                Text('"${alert.transcript}"',
                    style: const TextStyle(
                        color: AppTheme.textSecondary, fontSize: 11),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
        if (alert.confidence != null)
          Text(alert.confidenceLabel,
              style: TextStyle(color: color, fontSize: 12,
                  fontWeight: FontWeight.w600)),
      ]),
      backgroundColor: AppTheme.card,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color.withOpacity(0.4), width: 1),
      ),
    ));
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message,
          style: const TextStyle(color: AppTheme.textPrimary)),
      backgroundColor: AppTheme.card,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppTheme.accent, width: 1),
      ),
    ));
  }

  // ── Convenience getters ────────────────────────────────────────

  bool get _isRecording => _status == RecordingStatus.recording;
  bool get _isUploading => _status == RecordingStatus.uploading;

  // ── Build ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) return _buildLoadingScreen();

    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Column(children: [
          RecorderHeader(
            clipCount: _recordings.whereType<RecordingMeta>().length,
          ),
          Expanded(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(children: [
                  if (_initError != null) ErrorBanner(message: _initError!),
                  const SizedBox(height: 32),
                  RecordButton(
                    isRecording: _isRecording,
                    isUploading: _isUploading,
                    amplitude:   _amplitude,
                    pulseAnim:   _pulseAnimation,
                    onTap: _isRecording ? _stopRecording : _startRecording,
                  ),
                  const SizedBox(height: 16),
                  WaveformStrip(
                    visible:    _isRecording,
                    barHeights: _waveBarHeights,
                  ),
                  const SizedBox(height: 20),
                  StatusChip(status: _status),
                  const SizedBox(height: 24),
                  if (_isRecording && _liveAlerts.isNotEmpty)
                    LiveAlertFeed(alerts: _liveAlerts),
                  if (_recordings.isNotEmpty)
                    RecordingsList(
                      recordings:       _recordings,
                      playingIndex:     _playingIndex,
                      playbackProgress: _playbackProgress,
                      playbackPosition: _playbackPosition,
                      playbackTotal:    _playbackTotal,
                      onPlay:           _playRecording,
                      onTap:            _showAlertsSheet,
                    ),
                  const SizedBox(height: 24),
                ]),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildLoadingScreen() {
    return const Scaffold(
      backgroundColor: AppTheme.bg,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: AppTheme.accent),
            SizedBox(height: 20),
            Text('Loading…',
                style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 13,
                    letterSpacing: 2)),
          ],
        ),
      ),
    );
  }
}