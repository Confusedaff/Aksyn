import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import '../services/audio_service.dart';
import '../services/supabase_service.dart';
import '../services/live_detection_service.dart';

class AudioRecorderScreen extends StatefulWidget {
  const AudioRecorderScreen({super.key});

  @override
  State<AudioRecorderScreen> createState() => _AudioRecorderScreenState();
}

class _AudioRecorderScreenState extends State<AudioRecorderScreen>
    with TickerProviderStateMixin {
  final AudioService         _audioService     = AudioService();
  final SupabaseService      _supabaseService  = SupabaseService();
  final LiveDetectionService _detectionService = LiveDetectionService();
  final AudioPlayer          _audioPlayer      = AudioPlayer();

  RecordingStatus _status = RecordingStatus.stopped;

  // Each entry: RecordingMeta (from Supabase) or a pending map for
  // recordings whose upload hasn't completed yet.
  // We keep them as dynamic so we can mix both until the upload finishes.
  List<dynamic> _recordings = [];   // List<RecordingMeta | _PendingRecording>
  List<DetectionAlert> _liveAlerts = [];

  bool   _isInitialized = false;
  String? _initError;
  int?   _playingIndex;
  DateTime? _recordingStartTime;

  // Playback state
  double   _playbackProgress = 0.0;
  Duration _playbackPosition = Duration.zero;
  Duration _playbackTotal    = Duration.zero;
  StreamSubscription? _positionSub, _durationSub, _playerStateSub;

  // Waveform
  double _amplitude = 0.0;
  Timer? _amplitudeTimer;
  final List<double> _waveBarHeights = List.filled(28, 0.0);
  final _rand = Random();

  StreamSubscription? _alertSub, _statusSub, _doneSub;

  late AnimationController _pulseController;
  late Animation<double>   _pulseAnimation;

  // ── Theme ──────────────────────────────────────────────────────
  static const _bg            = Color(0xFF0A0A0F);
  static const _surface       = Color(0xFF13131A);
  static const _card          = Color(0xFF1C1C27);
  static const _accent        = Color(0xFFE8375A);
  static const _accentGlow    = Color(0x44E8375A);
  static const _gold          = Color(0xFFF5C842);
  static const _green         = Color(0xFF4ADE80);
  static const _textPrimary   = Color(0xFFF0F0F5);
  static const _textSecondary = Color(0xFF6B6B80);
  static const _border        = Color(0xFF2A2A38);

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
      // Load past recordings from Supabase
      final saved = await _supabaseService.fetchRecordings();
      if (mounted) {
        setState(() {
          _recordings   = List<dynamic>.from(saved);
          _isInitialized = true;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _initError = e.toString(); _isInitialized = true; });
    }
  }

  // ── Amplitude ──────────────────────────────────────────────────

  void _startAmplitudeTimer() {
    _amplitudeTimer?.cancel();
    _amplitudeTimer = Timer.periodic(const Duration(milliseconds: 80), (_) async {
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
    if (mounted) setState(() {
      _amplitude = 0.0;
      for (int i = 0; i < _waveBarHeights.length; i++) _waveBarHeights[i] = 0.0;
    });
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
        _playbackProgress = total > 0 ? (pos.inMilliseconds / total).clamp(0.0, 1.0) : 0.0;
      });
    });
    _playerStateSub = _audioPlayer.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed && mounted) {
        setState(() {
          _playingIndex = null;
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

  Future<void> _playRecording(String url, int index) async {
    try {
      if (_playingIndex == index) { _stopPlayback(); return; }
      setState(() {
        _playingIndex = index;
        _playbackProgress = 0.0;
        _playbackPosition = Duration.zero;
        _playbackTotal    = Duration.zero;
      });
      _attachPlaybackStreams();
      await _audioPlayer.setUrl(url);
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
      _playingIndex = null;
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
        _recordings.removeWhere((r) => r is _PendingRecording);
        _recordings.insert(0, meta);
        _status = RecordingStatus.uploaded;
      });
      // Clean up WS now that we have the final result
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
        _status             = RecordingStatus.recording;
        _recordingStartTime = DateTime.now();
        _liveAlerts.clear();
        // Insert a placeholder so the list shows "uploading…" immediately
        _recordings.insert(0, _PendingRecording());
      });

      await _detectionService.connect();
      _subscribeToDetection();

      final pcmStream = await _audioService.startStreamingRecording();
      pcmStream.listen((Uint8List chunk) => _detectionService.sendChunk(chunk));

      _startAmplitudeTimer();
    } catch (e) {
      setState(() {
        _status = RecordingStatus.stopped;
        _recordingStartTime = null;
        _recordings.removeWhere((r) => r is _PendingRecording);
      });
      _showError('Failed to start: $e');
    }
  }

  void _stopRecording() async {
    if (!_isInitialized) return;
    try {
      _stopAmplitudeTimer();
      setState(() { _status = RecordingStatus.uploading; _recordingStartTime = null; });

      await _audioService.stopRecording();

      // Send END signal — server uploads to Supabase then sends "done" with URL.
      // Keep WS + subscriptions alive so _doneSub can fire and update the UI.
      await _detectionService.endStream();

      // Safety timeout: if "done" never arrives within 60s, recover gracefully.
      Future.delayed(const Duration(seconds: 60), () {
        if (!mounted) return;
        if (_status == RecordingStatus.uploading) {
          setState(() {
            _recordings.removeWhere((r) => r is _PendingRecording);
            _status = RecordingStatus.stopped;
          });
          _showError('Server timed out — check backend connection.');
          _unsubscribeFromDetection();
          _detectionService.disconnect();
        }
      });
    } catch (e) {
      setState(() {
        _recordings.removeWhere((r) => r is _PendingRecording);
        _status = RecordingStatus.stopped;
      });
      _showError('Failed to stop: $e');
    }
  }

  // ── Alerts bottom sheet ────────────────────────────────────────

  void _showAlertsSheet(BuildContext context, dynamic rec) async {
    // For a real RecordingMeta, fetch alerts from server
    // For a pending placeholder, show the live alerts we collected
    List<AlertMeta> alerts = [];
    if (rec is RecordingMeta) {
      showModalBottomSheet(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (_) => _AlertsSheet(
          recording: rec,
          alertsFuture: _supabaseService.fetchAlerts(rec.fileName),
        ),
      );
      return;
    }
  }

  // ── Helpers ────────────────────────────────────────────────────

  void _showAlertBanner(DetectionAlert alert) {
    final color = alert.isKeyword ? _accent : _gold;
    final icon  = alert.isKeyword ? '🗣' : '🔊';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        Text('$icon  ', style: const TextStyle(fontSize: 16)),
        Expanded(child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(alert.label.toUpperCase(), style: TextStyle(color: color,
                fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
            if (alert.transcript != null)
              Text('"${alert.transcript}"',
                  style: const TextStyle(color: _textSecondary, fontSize: 11),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        )),
        if (alert.confidence != null)
          Text(alert.confidenceLabel,
              style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
      ]),
      backgroundColor: _card,
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
      content: Text(message, style: const TextStyle(color: _textPrimary)),
      backgroundColor: _card,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: _accent, width: 1),
      ),
    ));
  }

  bool get _isRecording => _status == RecordingStatus.recording;
  bool get _isUploading => _status == RecordingStatus.uploading;

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // ── Build ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return const Scaffold(
        backgroundColor: _bg,
        body: Center(child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: _accent),
            SizedBox(height: 20),
            Text('Loading…', style: TextStyle(color: _textSecondary,
                fontSize: 13, letterSpacing: 2)),
          ],
        )),
      );
    }

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(child: Column(children: [
        _buildHeader(),
        Expanded(child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(children: [
              if (_initError != null) _buildErrorBanner(),
              const SizedBox(height: 32),
              _buildRecordButton(),
              const SizedBox(height: 16),
              _buildWaveformStrip(),
              const SizedBox(height: 20),
              _buildStatusChip(),
              const SizedBox(height: 24),
              if (_isRecording && _liveAlerts.isNotEmpty) _buildLiveAlertFeed(),
              if (_recordings.isNotEmpty) _buildRecordingsList(),
              const SizedBox(height: 24),
            ]),
          ),
        )),
      ])),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      child: Row(children: [
        Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
            color: _accentGlow,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: _accent.withOpacity(0.4), width: 1),
          ),
          child: const Icon(Icons.graphic_eq_rounded, color: _accent, size: 20),
        ),
        const SizedBox(width: 12),
        const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('VŌICE', style: TextStyle(color: _textPrimary, fontSize: 17,
              fontWeight: FontWeight.w800, letterSpacing: 5)),
          Text('live detector', style: TextStyle(color: _textSecondary,
              fontSize: 9, letterSpacing: 3.5)),
        ]),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: _surface,
              borderRadius: BorderRadius.circular(20), border: Border.all(color: _border)),
          child: Text('${_recordings.whereType<RecordingMeta>().length} clips',
              style: const TextStyle(color: _textSecondary, fontSize: 12, letterSpacing: 0.5)),
        ),
      ]),
    );
  }

  Widget _buildRecordButton() {
    return Center(
      child: SizedBox(
        width: 240, height: 240,
        child: Stack(alignment: Alignment.center, children: [
          if (_isRecording) ...[
            AnimatedBuilder(
              animation: _pulseController,
              builder: (_, __) => Transform.scale(
                scale: 1.0 + (_amplitude * 0.25),
                child: Container(width: 210, height: 210,
                    decoration: BoxDecoration(shape: BoxShape.circle,
                        border: Border.all(
                            color: _accent.withOpacity(0.15 + _amplitude * 0.4),
                            width: 1.5))),
              ),
            ),
            AnimatedBuilder(
              animation: _pulseAnimation,
              builder: (_, __) => Transform.scale(
                scale: _pulseAnimation.value,
                child: Container(width: 190, height: 190,
                    decoration: BoxDecoration(shape: BoxShape.circle,
                        border: Border.all(color: _accent.withOpacity(0.1), width: 1))),
              ),
            ),
          ],
          AnimatedContainer(
            duration: const Duration(milliseconds: 80),
            width: 180, height: 180,
            decoration: BoxDecoration(
              shape: BoxShape.circle, color: _surface,
              border: Border.all(
                  color: _isRecording ? _accent.withOpacity(0.3 + _amplitude * 0.5) : _border,
                  width: 1.5),
              boxShadow: _isRecording ? [BoxShadow(
                color: _accent.withOpacity(0.1 + _amplitude * 0.35),
                blurRadius: 20 + _amplitude * 40,
                spreadRadius: _amplitude * 8,
              )] : [],
            ),
          ),
          GestureDetector(
            onTap: _isUploading ? null : (_isRecording ? _stopRecording : _startRecording),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 80),
              width:  _isRecording ? (108 + _amplitude * 12) : 118,
              height: _isRecording ? (108 + _amplitude * 12) : 118,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _isRecording ? _accent : _card,
                border: Border.all(
                    color: _isRecording ? _accent.withOpacity(0.7) : _border, width: 2),
                boxShadow: _isRecording ? [BoxShadow(
                    color: _accent.withOpacity(0.3 + _amplitude * 0.4),
                    blurRadius: 20 + _amplitude * 30,
                    spreadRadius: 2 + _amplitude * 6)]
                    : [BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 20)],
              ),
              child: _isUploading
                  ? const SizedBox(width: 28, height: 28,
                      child: CircularProgressIndicator(color: _gold, strokeWidth: 2))
                  : Icon(_isRecording ? Icons.stop_rounded : Icons.mic_rounded,
                      color: _isRecording ? Colors.white : _textSecondary, size: 50),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildWaveformStrip() {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 400),
      opacity: _isRecording ? 1.0 : 0.0,
      child: SizedBox(
        height: 52,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: List.generate(_waveBarHeights.length, (i) {
            final h = _waveBarHeights[i];
            final brightness = 0.3 + (i / _waveBarHeights.length) * 0.7;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 80),
              curve: Curves.easeOut,
              width: 5, height: 6 + h * 46,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(
                  color: _accent.withOpacity(brightness),
                  borderRadius: BorderRadius.circular(3)),
            );
          }),
        ),
      ),
    );
  }

  Widget _buildStatusChip() {
    final (label, color) = switch (_status) {
      RecordingStatus.recording => ('● LIVE  ·  ANALYSING', _accent),
      RecordingStatus.uploading => ('↑  SAVING…', _gold),
      RecordingStatus.uploaded  => ('✓  SAVED', _green),
      _                         => ('○  READY', _textSecondary),
    };
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
      child: Container(
        key: ValueKey(_status),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 11),
        decoration: BoxDecoration(
          color: color.withOpacity(0.07),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: color.withOpacity(0.22), width: 1),
        ),
        child: Text(label, style: TextStyle(color: color, fontSize: 11,
            fontWeight: FontWeight.w700, letterSpacing: 2.5)),
      ),
    );
  }

  Widget _buildLiveAlertFeed() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Row(children: [
        Text('LIVE DETECTIONS', style: TextStyle(color: _accent, fontSize: 10,
            fontWeight: FontWeight.w700, letterSpacing: 3)),
        SizedBox(width: 14),
        Expanded(child: Divider(color: _border)),
      ]),
      const SizedBox(height: 10),
      ...(_liveAlerts.take(5).map(_buildAlertTileSmall)),
      const SizedBox(height: 16),
    ]);
  }

  Widget _buildAlertTileSmall(DetectionAlert alert) {
    final color = alert.isKeyword ? _accent : _gold;
    final icon  = alert.isKeyword ? Icons.record_voice_over_rounded : Icons.volume_up_rounded;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.25), width: 1),
      ),
      child: Row(children: [
        Icon(icon, color: color, size: 16),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(alert.label.toUpperCase(), style: TextStyle(color: color,
              fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
          if (alert.transcript != null)
            Text('"${alert.transcript}"',
                style: const TextStyle(color: _textSecondary, fontSize: 11),
                maxLines: 1, overflow: TextOverflow.ellipsis),
        ])),
        if (alert.confidence != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: color.withOpacity(0.12),
                borderRadius: BorderRadius.circular(20)),
            child: Text(alert.confidenceLabel,
                style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600)),
          ),
      ]),
    );
  }

  Widget _buildRecordingsList() {
    final realCount = _recordings.whereType<RecordingMeta>().length;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Row(children: [
        Text('RECORDINGS', style: TextStyle(color: _textSecondary, fontSize: 10,
            fontWeight: FontWeight.w700, letterSpacing: 3)),
        SizedBox(width: 14),
        Expanded(child: Divider(color: _border, height: 1)),
      ]),
      const SizedBox(height: 14),
      ...List.generate(_recordings.length,
          (i) => _buildRecordingTile(_recordings[i], i, _playingIndex == i, realCount)),
    ]);
  }

  Widget _buildRecordingTile(dynamic rec, int index, bool isPlaying, int realCount) {
    // ── Pending placeholder ──────────────────────────────────────
    if (rec is _PendingRecording) {
      return Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _gold.withOpacity(0.3), width: 1),
        ),
        child: Row(children: [
          const SizedBox(width: 20, height: 20,
              child: CircularProgressIndicator(color: _gold, strokeWidth: 2)),
          const SizedBox(width: 14),
          const Text('Processing & uploading…',
              style: TextStyle(color: _textSecondary, fontSize: 13)),
        ]),
      );
    }

    // ── Real RecordingMeta ───────────────────────────────────────
    final meta       = rec as RecordingMeta;
    final displayTotal    = isPlaying && _playbackTotal > Duration.zero
        ? _playbackTotal : meta.duration;
    final displayPosition = isPlaying ? _playbackPosition : Duration.zero;
    final progress        = isPlaying ? _playbackProgress : 0.0;
    final recNumber       = realCount - _recordings
        .whereType<RecordingMeta>()
        .toList()
        .indexOf(meta);

    return GestureDetector(
      // Tap the tile body → show alerts sheet
      onTap: () => _showAlertsSheet(context, meta),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: isPlaying ? _accent.withOpacity(0.07) : _card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: isPlaying ? _accent.withOpacity(0.35) : _border, width: 1),
        ),
        child: Column(children: [
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            leading: Container(
              width: 42, height: 42,
              decoration: BoxDecoration(
                color: isPlaying ? _accentGlow : _surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: isPlaying ? _accent.withOpacity(0.4) : _border, width: 1),
              ),
              child: Icon(Icons.audiotrack_rounded,
                  color: isPlaying ? _accent : _textSecondary, size: 19),
            ),
            title: Row(children: [
              Text('Recording $recNumber',
                  style: const TextStyle(color: _textPrimary,
                      fontWeight: FontWeight.w600, fontSize: 14)),
              if (meta.alertCount > 0) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(color: _accent.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10)),
                  child: Text('${meta.alertCount} alert${meta.alertCount > 1 ? 's' : ''}',
                      style: const TextStyle(color: _accent, fontSize: 10,
                          fontWeight: FontWeight.w600)),
                ),
              ],
            ]),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(children: [
                Text(meta.dateLabel,
                    style: const TextStyle(color: _textSecondary, fontSize: 11)),
                const SizedBox(width: 6),
                Text(
                  isPlaying
                      ? '${_formatDuration(displayPosition)} / ${_formatDuration(displayTotal)}'
                      : _formatDuration(displayTotal),
                  style: TextStyle(
                    color: isPlaying ? _accent : _textSecondary, fontSize: 11,
                    fontWeight: isPlaying ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
                const Spacer(),
                const Icon(Icons.chevron_right_rounded, color: _textSecondary, size: 16),
              ]),
            ),
            // Play/stop button — stops tap propagation to avoid opening sheet
            trailing: GestureDetector(
              onTap: () {
                if (meta.publicUrl.isEmpty) {
                  _showError('Audio URL not available yet');
                  return;
                }
                _playRecording(meta.publicUrl, index);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 38, height: 38,
                decoration: BoxDecoration(
                  color: isPlaying ? _accent : _surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: isPlaying ? _accent : _border, width: 1),
                ),
                child: Icon(
                  isPlaying ? Icons.stop_rounded : Icons.play_arrow_rounded,
                  color: isPlaying ? Colors.white : _textSecondary, size: 20,
                ),
              ),
            ),
          ),
          // Playback progress bar
          AnimatedSize(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
            child: isPlaying
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Column(children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: progress,
                          backgroundColor: _border,
                          valueColor: const AlwaysStoppedAnimation<Color>(_accent),
                          minHeight: 3,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        Text(_formatDuration(displayPosition),
                            style: const TextStyle(color: _accent, fontSize: 10,
                                fontWeight: FontWeight.w600)),
                        Text(_formatDuration(displayTotal),
                            style: const TextStyle(color: _textSecondary, fontSize: 10)),
                      ]),
                    ]),
                  )
                : const SizedBox.shrink(),
          ),
        ]),
      ),
    );
  }

  Widget _buildErrorBanner() {
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _accent.withOpacity(0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _accent.withOpacity(0.25)),
      ),
      child: Row(children: [
        const Icon(Icons.warning_amber_rounded, color: _accent, size: 18),
        const SizedBox(width: 10),
        Expanded(child: Text(_initError!,
            style: const TextStyle(color: _textSecondary, fontSize: 12))),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// ALERTS BOTTOM SHEET
// ─────────────────────────────────────────────────────────────────

class _AlertsSheet extends StatelessWidget {
  final RecordingMeta           recording;
  final Future<List<AlertMeta>> alertsFuture;

  const _AlertsSheet({required this.recording, required this.alertsFuture});

  static const _bg      = Color(0xFF13131A);
  static const _card    = Color(0xFF1C1C27);
  static const _accent  = Color(0xFFE8375A);
  static const _gold    = Color(0xFFF5C842);
  static const _green   = Color(0xFF4ADE80);
  static const _border  = Color(0xFF2A2A38);
  static const _textPri = Color(0xFFF0F0F5);
  static const _textSec = Color(0xFF6B6B80);

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      builder: (_, controller) => Container(
        decoration: const BoxDecoration(
          color: _bg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(children: [
          // Handle
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40, height: 4,
            decoration: BoxDecoration(color: _border,
                borderRadius: BorderRadius.circular(2)),
          ),
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
            child: Row(children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  color: _accent.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _accent.withOpacity(0.3)),
                ),
                child: const Icon(Icons.warning_amber_rounded, color: _accent, size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Alerts · ${recording.fileName.split('_').last.replaceAll('.wav', '')}',
                    style: const TextStyle(color: _textPri, fontSize: 15,
                        fontWeight: FontWeight.w600),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(recording.dateLabel,
                    style: const TextStyle(color: _textSec, fontSize: 11)),
              ])),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: recording.alertCount > 0
                      ? _accent.withOpacity(0.1) : _card,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: recording.alertCount > 0
                          ? _accent.withOpacity(0.3) : _border),
                ),
                child: Text(
                  '${recording.alertCount} alert${recording.alertCount != 1 ? 's' : ''}',
                  style: TextStyle(
                    color: recording.alertCount > 0 ? _accent : _textSec,
                    fontSize: 11, fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 16),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Divider(color: _border),
          ),
          // Alert list
          Expanded(
            child: FutureBuilder<List<AlertMeta>>(
              future: alertsFuture,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(
                      child: CircularProgressIndicator(color: _accent));
                }
                final alerts = snap.data ?? [];
                if (alerts.isEmpty) {
                  return Center(child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.check_circle_outline_rounded,
                          color: _green.withOpacity(0.5), size: 48),
                      const SizedBox(height: 12),
                      const Text('No alerts detected',
                          style: TextStyle(color: _textSec, fontSize: 14)),
                    ],
                  ));
                }
                return ListView.builder(
                  controller: controller,
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                  itemCount: alerts.length,
                  itemBuilder: (_, i) => _buildAlertRow(alerts[i]),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildAlertRow(AlertMeta alert) {
    final color = alert.isKeyword ? _accent : _gold;
    final icon  = alert.isKeyword
        ? Icons.record_voice_over_rounded
        : Icons.volume_up_rounded;
    final t = alert.triggeredAt.toLocal();
    final timeStr = '${t.hour.toString().padLeft(2, '0')}:'
                    '${t.minute.toString().padLeft(2, '0')}:'
                    '${t.second.toString().padLeft(2, '0')}';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withOpacity(0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.2), width: 1),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 36, height: 36,
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: color, size: 18),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(alert.label.toUpperCase(),
                  style: TextStyle(color: color, fontSize: 12,
                      fontWeight: FontWeight.w700, letterSpacing: 1.5)),
            ),
            Text(timeStr,
                style: const TextStyle(color: _textSec, fontSize: 10)),
          ]),
          const SizedBox(height: 2),
          Text(alert.source, style: const TextStyle(color: _textSec, fontSize: 11)),
          if (alert.transcript != null) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: _card,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _border),
              ),
              child: Text('"${alert.transcript}"',
                  style: const TextStyle(color: _textPri, fontSize: 12,
                      fontStyle: FontStyle.italic)),
            ),
          ],
        ])),
        if (alert.confidence != null) ...[
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(alert.confidenceLabel,
                style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700)),
          ),
        ],
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// HELPERS
// ─────────────────────────────────────────────────────────────────

/// Placeholder shown in the list while a recording is being processed/uploaded
class _PendingRecording {}

enum RecordingStatus { stopped, recording, uploading, uploaded }