import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import '../services/audio_service.dart';
import '../services/supabase_service.dart';

class AudioRecorderScreen extends StatefulWidget {
  const AudioRecorderScreen({super.key});

  @override
  State<AudioRecorderScreen> createState() => _AudioRecorderScreenState();
}

class _AudioRecorderScreenState extends State<AudioRecorderScreen>
    with TickerProviderStateMixin {
  final AudioService _audioService = AudioService();
  final SupabaseService _supabaseService = SupabaseService();
  final AudioPlayer _audioPlayer = AudioPlayer();

  RecordingStatus _status = RecordingStatus.stopped;
  String? _currentRecordingPath;
  List<Map<String, dynamic>> _recordings = [];
  double _uploadProgress = 0.0;
  bool _isInitialized = false;
  String? _initError;
  int? _playingIndex;

  // Correct duration: track recording start time
  DateTime? _recordingStartTime;

  // Playback progress (0.0 – 1.0) and position for the active tile
  double _playbackProgress = 0.0;
  Duration _playbackPosition = Duration.zero;
  Duration _playbackTotal = Duration.zero;
  StreamSubscription? _positionSub;
  StreamSubscription? _durationSub;
  StreamSubscription? _playerStateSub;

  // Sound reactivity
  double _amplitude = 0.0;
  Timer? _amplitudeTimer;
  final List<double> _waveBarHeights = List.filled(28, 0.0);
  final _rand = Random();

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  // Theme
  static const _bg = Color(0xFF0A0A0F);
  static const _surface = Color(0xFF13131A);
  static const _card = Color(0xFF1C1C27);
  static const _accent = Color(0xFFE8375A);
  static const _accentGlow = Color(0x44E8375A);
  static const _gold = Color(0xFFF5C842);
  static const _textPrimary = Color(0xFFF0F0F5);
  static const _textSecondary = Color(0xFF6B6B80);
  static const _border = Color(0xFF2A2A38);

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.12).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _initializeServices();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _stopAmplitudeTimer();
    _cancelPlaybackStreams();
    _audioPlayer.dispose();
    _audioService.dispose();
    super.dispose();
  }

  Future<void> _initializeServices() async {
    try {
      await _audioService.initialize();
      await _supabaseService.initialize();
      if (mounted) setState(() => _isInitialized = true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _initError = e.toString();
          _isInitialized = true;
        });
      }
    }
  }

  // ── Amplitude ──────────────────────────────────────────────────────────────

  void _startAmplitudeTimer() {
    _amplitudeTimer?.cancel();
    _amplitudeTimer =
        Timer.periodic(const Duration(milliseconds: 80), (_) async {
      if (!mounted || !_isRecording) return;
      try {
        final amp = await _audioService.recorder.getAmplitude();
        final db = amp.current.clamp(-60.0, 0.0);
        final normalised = ((db + 60) / 60).clamp(0.0, 1.0);
        if (mounted) {
          setState(() {
            _amplitude = normalised;
            for (int i = 0; i < _waveBarHeights.length - 1; i++) {
              _waveBarHeights[i] = _waveBarHeights[i + 1];
            }
            final jitter = _rand.nextDouble() * 0.06;
            _waveBarHeights[_waveBarHeights.length - 1] =
                (normalised + jitter).clamp(0.04, 1.0);
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

  // ── Playback streams ───────────────────────────────────────────────────────

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
          _playingIndex = null;
          _playbackProgress = 0.0;
          _playbackPosition = Duration.zero;
          _playbackTotal = Duration.zero;
        });
      }
    });
  }

  void _cancelPlaybackStreams() {
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playerStateSub?.cancel();
    _positionSub = null;
    _durationSub = null;
    _playerStateSub = null;
  }

  // ── Recording controls ─────────────────────────────────────────────────────

  void _startRecording() async {
    if (!_isInitialized) return;
    try {
      setState(() {
        _status = RecordingStatus.recording;
        _recordingStartTime = DateTime.now(); // ← start the clock
      });
      _currentRecordingPath = await _audioService.startRecording();
      _startAmplitudeTimer();
    } catch (e) {
      setState(() {
        _status = RecordingStatus.stopped;
        _recordingStartTime = null;
      });
      _showError('Failed to start: $e');
    }
  }

  void _stopRecording() async {
    if (!_isInitialized) return;
    try {
      _stopAmplitudeTimer();

      // Compute accurate duration BEFORE stopping (file not yet closed)
      final duration = _recordingStartTime != null
          ? DateTime.now().difference(_recordingStartTime!)
          : Duration.zero;

      setState(() {
        _status = RecordingStatus.stopped;
        _recordingStartTime = null;
      });
      await _audioService.stopRecording();
      if (_currentRecordingPath != null) {
        await _uploadRecording(duration);
      }
    } catch (e) {
      _showError('Failed to stop: $e');
    }
  }

  Future<void> _uploadRecording(Duration duration) async {
    if (_currentRecordingPath == null) return;
    try {
      setState(() => _status = RecordingStatus.uploading);
      final url = await _supabaseService.uploadAudioFile(
        _currentRecordingPath!,
        onProgress: (p) => setState(() => _uploadProgress = p),
      );
      final now = DateTime.now();
      final dateLabel =
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}  ·  ${now.day}/${now.month}/${now.year}';
      setState(() {
        _status = RecordingStatus.uploaded;
        _recordings.insert(0, {
          'url': url,
          'label': dateLabel,
          'duration': duration, // Duration object — always accurate
        });
        _uploadProgress = 0.0;
      });
    } catch (e) {
      setState(() => _status = RecordingStatus.stopped);
      _showError('Upload failed: $e');
    }
  }

  void _playRecording(String url, int index) async {
    try {
      setState(() {
        _playingIndex = index;
        _playbackProgress = 0.0;
        _playbackPosition = Duration.zero;
        _playbackTotal = Duration.zero;
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
      _playbackTotal = Duration.zero;
    });
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: _textPrimary)),
        backgroundColor: _card,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: _accent, width: 1),
        ),
      ),
    );
  }

  bool get _isRecording => _status == RecordingStatus.recording;
  bool get _isUploading => _status == RecordingStatus.uploading;

  // ── Helpers ────────────────────────────────────────────────────────────────

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return const Scaffold(
        backgroundColor: _bg,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: _accent),
              SizedBox(height: 20),
              Text('Initializing...',
                  style: TextStyle(
                      color: _textSecondary, fontSize: 13, letterSpacing: 2)),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    children: [
                      if (_initError != null) _buildErrorBanner(),
                      const SizedBox(height: 32),
                      _buildRecordButton(),
                      const SizedBox(height: 16),
                      _buildWaveformStrip(),
                      const SizedBox(height: 20),
                      _buildStatusChip(),
                      const SizedBox(height: 24),
                      if (_isUploading) _buildUploadProgress(),
                      if (_recordings.isNotEmpty) _buildRecordingsList(),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: _accentGlow,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: _accent.withOpacity(0.4), width: 1),
            ),
            child: const Icon(Icons.graphic_eq_rounded, color: _accent, size: 20),
          ),
          const SizedBox(width: 12),
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('VŌICE',
                  style: TextStyle(
                      color: _textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 5)),
              Text('recorder',
                  style: TextStyle(
                      color: _textSecondary, fontSize: 9, letterSpacing: 3.5)),
            ],
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: _border),
            ),
            child: Text('${_recordings.length} clips',
                style: const TextStyle(
                    color: _textSecondary, fontSize: 12, letterSpacing: 0.5)),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordButton() {
    return Center(
      child: SizedBox(
        width: 240,
        height: 240,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (_isRecording)
              AnimatedBuilder(
                animation: _pulseController,
                builder: (_, __) {
                  final scale = 1.0 + (_amplitude * 0.25);
                  return Transform.scale(
                    scale: scale,
                    child: Container(
                      width: 210,
                      height: 210,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _accent.withOpacity(0.15 + _amplitude * 0.4),
                          width: 1.5,
                        ),
                      ),
                    ),
                  );
                },
              ),
            if (_isRecording)
              AnimatedBuilder(
                animation: _pulseAnimation,
                builder: (_, __) => Transform.scale(
                  scale: _pulseAnimation.value,
                  child: Container(
                    width: 190,
                    height: 190,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: _accent.withOpacity(0.1), width: 1),
                    ),
                  ),
                ),
              ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 80),
              width: 180,
              height: 180,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _surface,
                border: Border.all(
                  color: _isRecording
                      ? _accent.withOpacity(0.3 + _amplitude * 0.5)
                      : _border,
                  width: 1.5,
                ),
                boxShadow: _isRecording
                    ? [
                        BoxShadow(
                          color: _accent.withOpacity(0.1 + _amplitude * 0.35),
                          blurRadius: 20 + _amplitude * 40,
                          spreadRadius: _amplitude * 8,
                        ),
                      ]
                    : [],
              ),
            ),
            GestureDetector(
              onTap: _isUploading
                  ? null
                  : (_isRecording ? _stopRecording : _startRecording),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 80),
                width: _isRecording ? (108 + _amplitude * 12) : 118,
                height: _isRecording ? (108 + _amplitude * 12) : 118,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _isRecording ? _accent : _card,
                  border: Border.all(
                    color: _isRecording ? _accent.withOpacity(0.7) : _border,
                    width: 2,
                  ),
                  boxShadow: _isRecording
                      ? [
                          BoxShadow(
                            color: _accent.withOpacity(0.3 + _amplitude * 0.4),
                            blurRadius: 20 + _amplitude * 30,
                            spreadRadius: 2 + _amplitude * 6,
                          ),
                        ]
                      : [
                          BoxShadow(
                              color: Colors.black.withOpacity(0.5),
                              blurRadius: 20),
                        ],
                ),
                child: _isUploading
                    ? const SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(
                            color: _gold, strokeWidth: 2),
                      )
                    : Icon(
                        _isRecording ? Icons.stop_rounded : Icons.mic_rounded,
                        color: _isRecording ? Colors.white : _textSecondary,
                        size: 50,
                      ),
              ),
            ),
          ],
        ),
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
              width: 5,
              height: 6 + h * 46,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(
                color: _accent.withOpacity(brightness),
                borderRadius: BorderRadius.circular(3),
              ),
            );
          }),
        ),
      ),
    );
  }

  Widget _buildStatusChip() {
    final (label, color) = switch (_status) {
      RecordingStatus.recording => ('● RECORDING', _accent),
      RecordingStatus.uploading => ('↑  UPLOADING', _gold),
      RecordingStatus.uploaded =>
        ('✓  SAVED TO CLOUD', const Color(0xFF4ADE80)),
      _ => ('○  READY', _textSecondary),
    };
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      transitionBuilder: (child, anim) =>
          FadeTransition(opacity: anim, child: child),
      child: Container(
        key: ValueKey(_status),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 11),
        decoration: BoxDecoration(
          color: color.withOpacity(0.07),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: color.withOpacity(0.22), width: 1),
        ),
        child: Text(label,
            style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 2.5)),
      ),
    );
  }

  Widget _buildUploadProgress() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Uploading to cloud',
                  style: TextStyle(color: _textSecondary, fontSize: 12)),
              Text('${(_uploadProgress * 100).toInt()}%',
                  style: const TextStyle(
                      color: _gold,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _uploadProgress,
              backgroundColor: _border,
              valueColor: const AlwaysStoppedAnimation<Color>(_gold),
              minHeight: 3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordingsList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Text('RECORDINGS',
                style: TextStyle(
                    color: _textSecondary,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 3)),
            SizedBox(width: 14),
            Expanded(child: Divider(color: _border, height: 1)),
          ],
        ),
        const SizedBox(height: 14),
        ...List.generate(_recordings.length, (i) {
          final rec = _recordings[i];
          final isPlaying = _playingIndex == i;
          return _buildRecordingTile(rec, i, isPlaying);
        }),
      ],
    );
  }

  Widget _buildRecordingTile(
      Map<String, dynamic> rec, int index, bool isPlaying) {
    final Duration totalDuration = rec['duration'] as Duration? ?? Duration.zero;

    // When this tile is playing, show live position/total from streams
    // When not playing, show the stored duration
    final displayTotal = isPlaying && _playbackTotal > Duration.zero
        ? _playbackTotal
        : totalDuration;
    final displayPosition = isPlaying ? _playbackPosition : Duration.zero;
    final progress = isPlaying ? _playbackProgress : 0.0;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: isPlaying ? _accent.withOpacity(0.07) : _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isPlaying ? _accent.withOpacity(0.35) : _border,
          width: 1,
        ),
      ),
      child: Column(
        children: [
          ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            leading: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: isPlaying ? _accentGlow : _surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: isPlaying ? _accent.withOpacity(0.4) : _border,
                    width: 1),
              ),
              child: Icon(Icons.audiotrack_rounded,
                  color: isPlaying ? _accent : _textSecondary, size: 19),
            ),
            title: Text(
              'Recording ${_recordings.length - index}',
              style: const TextStyle(
                  color: _textPrimary,
                  fontWeight: FontWeight.w600,
                  fontSize: 14),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                children: [
                  Text(
                    rec['label'] ?? '',
                    style: const TextStyle(
                        color: _textSecondary,
                        fontSize: 11,
                        letterSpacing: 0.3),
                  ),
                  const SizedBox(width: 6),
                  // Duration display: "pos / total" when playing, just "total" when idle
                  Text(
                    isPlaying
                        ? '${_formatDuration(displayPosition)} / ${_formatDuration(displayTotal)}'
                        : _formatDuration(displayTotal),
                    style: TextStyle(
                      color: isPlaying ? _accent : _textSecondary,
                      fontSize: 11,
                      fontWeight: isPlaying
                          ? FontWeight.w600
                          : FontWeight.normal,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
            ),
            trailing: GestureDetector(
              onTap: () => isPlaying
                  ? _stopPlayback()
                  : _playRecording(rec['url']!, index),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: isPlaying ? _accent : _surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: isPlaying ? _accent : _border, width: 1),
                ),
                child: Icon(
                  isPlaying ? Icons.stop_rounded : Icons.play_arrow_rounded,
                  color: isPlaying ? Colors.white : _textSecondary,
                  size: 20,
                ),
              ),
            ),
          ),

          // ── Playback progress bar (only visible when playing) ──────────────
          AnimatedSize(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
            child: isPlaying
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Column(
                      children: [
                        // Scrubable-looking progress track
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: progress,
                            backgroundColor: _border,
                            valueColor:
                                const AlwaysStoppedAnimation<Color>(_accent),
                            minHeight: 3,
                          ),
                        ),
                        const SizedBox(height: 6),
                        // Start / end time labels
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _formatDuration(displayPosition),
                              style: const TextStyle(
                                  color: _accent,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600),
                            ),
                            Text(
                              _formatDuration(displayTotal),
                              style: const TextStyle(
                                  color: _textSecondary, fontSize: 10),
                            ),
                          ],
                        ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
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
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: _accent, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(_initError!,
                style: const TextStyle(color: _textSecondary, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

enum RecordingStatus { stopped, recording, uploading, uploaded }