// lib/services/audio_service.dart
// --- FINAL CORRECTED VERSION USING FLUTTER_SOUND ---

import 'dart:async';
import 'dart:typed_data';

import 'package:cheeko_mqtt/models/ota_config.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:logger/logger.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'package:record/record.dart';

class AudioService {
  final _logger = Logger();
  final AudioRecorder _recorder = AudioRecorder();
  final FlutterSoundPlayer _player = FlutterSoundPlayer();

  AudioParams _audioParams = AudioParams(
    channels: 1,
    frameDuration: 60,
    sampleRate: 16000,
  );

  StreamController<Uint8List>? _recordingStreamController;
  StreamSubscription? _recorderSubscription;

  SimpleOpusDecoder? _opusDecoder;
  bool _opusInitialized = false;

  final List<Uint8List> _audioBuffer = [];
  static const int _startBufferFrames = 10;
  bool _isBuffering = true;
  int _totalFramesReceived = 0;

  AudioService() {
    _initialize();
  }

  Future<void> _initialize() async {
    await _player.openPlayer();
    await _initializeOpus();
    _logger.i("Audio service initialized with flutter_sound.");
  }

  Stream<Uint8List> get recordingStream => _recordingStreamController!.stream;

  void updateAudioParameters(AudioParams params) {
    _audioParams = params;
    _logger.i(
      "Audio parameters updated: Sample Rate ${_audioParams.sampleRate}Hz",
    );
    // Re-initialize Opus decoder if parameters change after initial setup
    _initializeOpus();
  }

  Future<void> _initializeOpus() async {
    // We can re-initialize if the sample rate changes.
    try {
      if (!_opusInitialized) {
        initOpus(await opus_flutter.load());
        _opusInitialized = true;
        _logger.i("Opus library loaded, version: ${getOpusVersion()}");
      }

      // Destroy the old decoder if it exists before creating a new one
      _opusDecoder?.destroy();
      _opusDecoder = SimpleOpusDecoder(
        sampleRate: _audioParams.sampleRate,
        channels: _audioParams.channels,
      );
      _logger.i(
        "Opus decoder initialized: ${_audioParams.sampleRate}Hz, ${_audioParams.channels} channel(s)",
      );
    } catch (e) {
      _logger.e("Failed to initialize Opus: $e");
    }
  }

  Future<void> startRecording() async {
    _recordingStreamController?.close();
    _recordingStreamController = StreamController<Uint8List>();

    if (await _recorder.hasPermission()) {
      final config = RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _audioParams.sampleRate,
        numChannels: _audioParams.channels,
      );
      final stream = await _recorder.startStream(config);
      _logger.i("Microphone recording started.");
      _recorderSubscription = stream.listen(
        (data) => _recordingStreamController?.add(data),
      );
    } else {
      _logger.e("Microphone permission not granted");
    }
  }

  Future<void> stopRecording() async {
    if (await _recorder.isRecording()) {
      await _recorder.stop();
    }
    await _recorderSubscription?.cancel();
    _recordingStreamController?.close();
    _logger.i("Microphone recording stopped.");
  }

  void playAudioChunk(Uint8List opusData) {
    if (_opusDecoder == null) return;
    try {
      final pcmSamples = _opusDecoder!.decode(input: opusData);
      final pcmBytes = ByteData(pcmSamples.length * 2);
      for (var i = 0; i < pcmSamples.length; i++) {
        pcmBytes.setInt16(i * 2, pcmSamples[i], Endian.little);
      }
      final pcmData = pcmBytes.buffer.asUint8List();

      _totalFramesReceived++;
      _logger.d(
        "Decoded Opus frame #$_totalFramesReceived: ${opusData.length} bytes -> ${pcmData.length} bytes PCM",
      );

      _audioBuffer.add(pcmData);

      if (_isBuffering) {
        if (_audioBuffer.length >= _startBufferFrames) {
          _isBuffering = false;
          _startPlayback();
        } else {
          _logger.i(
            "🎧 Buffering audio... ${_audioBuffer.length}/$_startBufferFrames frames",
          );
        }
      } else {
        // --- FIX #2: Use the new `feedFromStream` method name ---
        _player.feedFromStream(pcmData);
      }
    } catch (e) {
      _logger.e("Error in playAudioChunk: $e");
    }
  }

  // lib/services/audio_service.dart

  Future<void> _startPlayback() async {
    if (_player.isStopped) {
      _logger.i("✅ Buffer ready. Starting playback from stream.");
      await _player.startPlayerFromStream(
        codec: Codec.pcm16,
        numChannels: _audioParams.channels,
        sampleRate: _audioParams.sampleRate,
        bufferSize: 4096,
        interleaved: true, // ADD THIS LINE
      );

      // Feed the already buffered audio
      for (final chunk in _audioBuffer) {
        await _player.feedFromStream(chunk);
      }
      _audioBuffer.clear();
    }
  }

  Future<void> stopPlayback() async {
    try {
      if (_player.isPlaying) {
        await _player.stopPlayer();
      }
      _audioBuffer.clear();
      _isBuffering = true;
      _totalFramesReceived = 0;
      _logger.i("Playback stopped and buffer cleared.");
    } catch (e) {
      _logger.e("Error in stopPlayback: $e");
    }
  }

  void dispose() {
    _logger.i("Disposing Audio Service.");
    _recorder.dispose();
    _recorderSubscription?.cancel();
    _recordingStreamController?.close();
    _player.closePlayer();
    _opusDecoder?.destroy();
    _opusDecoder = null;
  }

  double get volume => 1.0;
  void setVolume({required bool increase}) {
    _logger.w("Volume control is not available for PCM stream feeding.");
  }
}
