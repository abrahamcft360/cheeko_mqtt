// lib/services/audio_service.dart
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:cheeko_mqtt/models/ota_config.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:logger/logger.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'package:record/record.dart';

class AudioService {
  final _logger = Logger(
    printer: PrettyPrinter(methodCount: 1, printTime: true),
  );
  final AudioRecorder _recorder = AudioRecorder();
  final FlutterSoundPlayer _player = FlutterSoundPlayer();
  Timer? _stopPlayerTimer;

  AudioParams _audioParams =
      AudioParams(channels: 1, frameDuration: 60, sampleRate: 16000);

  StreamController<Uint8List>? _recordingStreamController;
  StreamSubscription? _recorderSubscription;
  Timer? _silenceTimer;

  SimpleOpusDecoder? _opusDecoder;
  SimpleOpusEncoder? _opusEncoder;
  bool _opusInitialized = false;

  Function()? onSilenceDetected;
  static const double _silenceThreshold = 0.01;
  static const Duration _silenceDuration = Duration(seconds: 2);

  AudioService() {
    _initialize();
  }

  Future<void> _initialize() async {
    await _player.openPlayer();
    await _initializeOpus();
    _logger.i("Audio service initialized.");
  }

  void updateAudioParameters(AudioParams params) {
    _audioParams = params;
    _logger.i("Audio params updated: Sample Rate ${_audioParams.sampleRate}Hz");
    _initializeOpus();
  }

  Future<void> _initializeOpus() async {
    try {
      if (!_opusInitialized) {
        initOpus(await opus_flutter.load());
        _opusInitialized = true;
      }
      _opusDecoder?.destroy();
      _opusDecoder = SimpleOpusDecoder(
        sampleRate: _audioParams.sampleRate,
        channels: _audioParams.channels,
      );
      _opusEncoder?.destroy();
      _opusEncoder = SimpleOpusEncoder(
        sampleRate: _audioParams.sampleRate,
        channels: _audioParams.channels,
        application: Application.voip,
      );
      _logger.i("Opus initialized for ${_audioParams.sampleRate}Hz.");
    } catch (e) {
      _logger.e("Opus initialization failed: $e");
    }
  }

  Stream<Uint8List> startRecording() {
    // --- FIX: Always create a new stream controller for a new recording session ---
    _recordingStreamController?.close();
    _recordingStreamController = StreamController<Uint8List>();

    _startRecorderInternal();
    return _recordingStreamController!.stream;
  }

  Future<void> _startRecorderInternal() async {
    if (await _recorder.hasPermission()) {
      final frameSize =
          (_audioParams.sampleRate * _audioParams.frameDuration / 1000)
                  .toInt() *
              2;
      List<int> pcmBuffer = [];

      final stream = await _recorder.startStream(
        RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: _audioParams.sampleRate,
          numChannels: _audioParams.channels,
        ),
      );
      _logger.i("🎤 Microphone recording started.");

      _recorderSubscription = stream.listen((data) {
        if (_isSilent(data)) {
          _startSilenceTimer();
        } else {
          _resetSilenceTimer();
        }
        pcmBuffer.addAll(data);
        while (pcmBuffer.length >= frameSize) {
          final frame = pcmBuffer.sublist(0, frameSize);
          pcmBuffer.removeRange(0, frameSize);
          _recordingStreamController?.add(Uint8List.fromList(frame));
        }
      });
    }
  }

  Future<void> stopRecording() async {
    _resetSilenceTimer();
    if (await _recorder.isRecording()) {
      await _recorder.stop();
    }
    await _recorderSubscription?.cancel();
    _recorderSubscription = null;
    await _recordingStreamController?.close();
    _logger.i("🎙️ Microphone recording stopped.");
  }

  void playAudioChunk(Uint8List opusData) {
    _stopPlayerTimer?.cancel();

    if (_opusDecoder == null) return;
    try {
      final pcmSamples = _opusDecoder!.decode(input: opusData);
      final pcmData = ByteData(pcmSamples.length * 2);
      for (var i = 0; i < pcmSamples.length; i++) {
        pcmData.setInt16(i * 2, pcmSamples[i], Endian.little);
      }

      if (_player.isStopped) {
        _startPlayback(pcmData.buffer.asUint8List());
      } else if (_player.isPlaying) {
        _player.feedFromStream(pcmData.buffer.asUint8List());
      }
    } catch (e) {
      _logger.e("Error playing audio chunk: $e");
    }
  }

  Future<void> _startPlayback(Uint8List initialChunk) async {
    _logger.i("▶️ PLAYER: Starting playback stream...");
    await _player.startPlayerFromStream(
      interleaved: true,
      codec: Codec.pcm16,
      numChannels: _audioParams.channels,
      sampleRate: _audioParams.sampleRate,
      bufferSize: 4096,
    );
    await _player.feedFromStream(initialChunk);
    _logger.i("STREAMING: Player started and first chunk fed.");
  }

  void stopPlayback({bool immediate = false}) {
    _stopPlayerTimer?.cancel();
    if (immediate) {
      _performStop();
    } else {
      _stopPlayerTimer = Timer(const Duration(milliseconds: 500), _performStop);
    }
  }

  Future<void> _performStop() async {
    if (_player.isPlaying) {
      _logger.i("⏹️ PLAYER: Stopping playback.");
      await _player.stopPlayer();
    }
  }

  Uint8List? encodePcmToOpus(Uint8List pcmData) =>
      _opusEncoder?.encode(input: pcmData.buffer.asInt16List());

  bool _isSilent(Uint8List pcmChunk) {
    double sum = 0;
    for (var i = 0; i < pcmChunk.length; i += 2) {
      int sample = pcmChunk[i] + (pcmChunk[i + 1] << 8);
      if (sample > 32767) sample -= 65536;
      sum += (sample * sample);
    }
    double rms = sqrt(sum / (pcmChunk.length / 2));
    return (rms / 32768.0) < _silenceThreshold;
  }

  void _startSilenceTimer() {
    _silenceTimer ??= Timer(_silenceDuration, () {
      _logger.i("🤫 Silence detected. Notifying listener.");
      onSilenceDetected?.call();
    });
  }

  void _resetSilenceTimer() {
    _silenceTimer?.cancel();
    _silenceTimer = null;
  }

  void dispose() {
    _logger.i("Disposing Audio Service.");
    _recorder.dispose();
    _recorderSubscription?.cancel();
    _recordingStreamController?.close();
    _player.closePlayer();
    _opusDecoder?.destroy();
    _opusEncoder?.destroy();
    _stopPlayerTimer?.cancel();
  }
}