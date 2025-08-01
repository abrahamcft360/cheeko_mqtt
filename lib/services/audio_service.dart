// File: services/audio_service.dart
// ---
import 'dart:async';
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';
import 'package:logger/logger.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'package:record/record.dart';

// --- FIX: Add this class to handle streaming raw audio data ---
class MyCustomSource extends StreamAudioSource {
  final StreamController<Uint8List> _controller;

  MyCustomSource(this._controller) : super(tag: 'my-custom-source');

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    return StreamAudioResponse(
      sourceLength: null, // We don't know the total length
      contentLength: null,
      offset: 0,
      stream: _controller.stream,
      contentType: 'audio/pcm', // Placeholder, ideally 'audio/opus' if decoded
    );
  }
}

class AudioService {
  final _logger = Logger();
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();

  StreamController<Uint8List>? _recordingStreamController;
  StreamSubscription? _recorderSubscription;

  // --- FIX: Add a stream controller for playback ---
  StreamController<Uint8List>? _playbackStreamController;

  // Opus decoder for incoming audio
  SimpleOpusDecoder? _opusDecoder;
  bool _opusInitialized = false;

  // Audio parameters from server
  static const int _sampleRate = 16000; // From server config
  static const int _channels = 1;

  // Jitter buffer
  final List<Uint8List> _audioBuffer = [];
  static const int _minBufferFrames =
      3; // Min frames before continuing playback
  static const int _startBufferFrames = 16; // Frames to buffer before starting
  bool _isBuffering = true;
  int _totalFramesReceived = 0;

  double _volume = 0.8;
  double get volume => _volume;

  AudioService() {
    _player.setVolume(_volume);

    // Initialize Opus - deferred until first use
    _initializeOpus();

    // --- FIX: Initialize the playback controller and set the audio source ---
    _playbackStreamController = StreamController<Uint8List>.broadcast();
    // NOTE: This assumes raw LPCM data. Audio format details must match the server's output.
    // For 16-bit PCM, 1 channel at 16000Hz (from server config)
    final audioSource = MyCustomSource(_playbackStreamController!);
    _player.setAudioSource(
      audioSource,
      // Specify the audio format details here if known
      // For example, for raw PCM you might need to use a different plugin
      // or process the stream. For now, this will pipe the bytes.
    );
    _logger.i("Audio service created and player source set.");
  }

  Stream<Uint8List> get recordingStream => _recordingStreamController!.stream;

  Future<void> _initializeOpus() async {
    if (!_opusInitialized) {
      try {
        // Initialize opus library
        initOpus(await opus_flutter.load());
        _logger.i("Opus library loaded, version: ${getOpusVersion()}");

        // Create decoder
        _opusDecoder = SimpleOpusDecoder(
          sampleRate: _sampleRate,
          channels: _channels,
        );
        _opusInitialized = true;
        _logger.i(
          "Opus decoder initialized: ${_sampleRate}Hz, $_channels channel(s)",
        );
      } catch (e) {
        _logger.e("Failed to initialize Opus: $e");
      }
    }
  }

  Future<void> startRecording() async {
    if (_recordingStreamController?.isClosed == false) {
      await _recordingStreamController?.close();
    }
    _recordingStreamController = StreamController<Uint8List>.broadcast();

    if (await _recorder.hasPermission()) {
      // Use audio parameters from the server if available, otherwise default
      const config = RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 24000, // Match the sample rate from the python script
        numChannels: 1,
      );
      final stream = await _recorder.startStream(config);

      _logger.i("Microphone recording started.");

      _recorderSubscription = stream.listen((data) {
        _recordingStreamController?.add(data);
      });
    } else {
      _logger.e("Microphone permission not granted");
    }
  }

  Future<void> stopRecording() async {
    if (await _recorder.isRecording()) {
      await _recorder.stop();
    }
    await _recorderSubscription?.cancel();
    if (_recordingStreamController?.isClosed == false) {
      await _recordingStreamController?.close();
    }
    _logger.i("Microphone recording stopped.");
  }

  void playAudioChunk(Uint8List opusData) {
    // --- FIX: Decode Opus to PCM before playback ---
    try {
      if (_playbackStreamController?.isClosed == false &&
          _opusDecoder != null) {
        try {
          // Decode Opus data to PCM
          // SimpleOpusDecoder returns List<int> as PCM samples
          final pcmSamples = _opusDecoder!.decode(input: opusData);

          // Convert List<int> to Uint8List for audio playback
          // The decoder returns 16-bit PCM samples as List<int>
          final pcmData = Uint8List.fromList(pcmSamples);

          _totalFramesReceived++;
          _logger.d(
            "Decoded Opus frame #$_totalFramesReceived: ${opusData.length} bytes -> ${pcmData.length} bytes PCM",
          );

          // Add to buffer
          _audioBuffer.add(pcmData);

          // Check if we should start playback
          if (_isBuffering) {
            if (_audioBuffer.length >= _startBufferFrames) {
              _logger.i(
                "✅ Buffer ready with ${_audioBuffer.length} frames. Starting playback.",
              );
              _isBuffering = false;
              _startPlayback();
            } else {
              _logger.i(
                "🎧 Buffering audio... ${_audioBuffer.length}/$_startBufferFrames frames",
              );
            }
          } else {
            // Already playing, check if buffer is too low
            if (_audioBuffer.length < _minBufferFrames && _player.playing) {
              _logger.w(
                "‼️ Playback buffer low (${_audioBuffer.length} frames). Re-buffering...",
              );
              _player.pause();
              _isBuffering = true;
            } else {
              // Keep feeding the stream
              _feedAudioStream();
            }
          }
        } catch (e) {
          _logger.e("Opus decoding error: $e");
          _logger.e("Opus data size: ${opusData.length} bytes");
          // Skip this frame
        }
      } else if (_opusDecoder == null) {
        _logger.e("Opus decoder not initialized!");
      }
    } catch (e) {
      _logger.e("Error in playAudioChunk: $e");
    }
  }

  void _startPlayback() {
    if (!_player.playing && _audioBuffer.isNotEmpty) {
      _logger.i("Starting audio playback");
      _feedAudioStream();
      _player.play();
    }
  }

  void _feedAudioStream() {
    // Feed buffered audio to the stream
    while (_audioBuffer.isNotEmpty &&
        _playbackStreamController?.isClosed == false) {
      final pcmData = _audioBuffer.removeAt(0);
      _playbackStreamController!.add(pcmData);
    }
  }

  void stopPlayback() {
    try {
      _player.stop();
      // Clear the audio buffer
      _audioBuffer.clear();
      _isBuffering = true;
      _totalFramesReceived = 0;

      // Re-create the stream controller to clear any buffered data
      _playbackStreamController?.close();
      _playbackStreamController = StreamController<Uint8List>.broadcast();
      _player.setAudioSource(MyCustomSource(_playbackStreamController!));
      _logger.i("Playback stopped and buffer cleared.");
    } catch (e) {
      _logger.e("Error in stopPlayback: $e");
    }
  }

  void setVolume({required bool increase}) {
    if (increase) {
      _volume = (_volume + 0.1).clamp(0.0, 1.0);
    } else {
      _volume = (_volume - 0.1).clamp(0.0, 1.0);
    }
    _player.setVolume(_volume);
    _logger.i("Volume set to $_volume");
  }

  void dispose() {
    _logger.i("Disposing Audio Service.");
    _recorder.dispose();
    _recorderSubscription?.cancel();
    _recordingStreamController?.close();
    _player.dispose();
    _playbackStreamController?.close(); // Clean up the playback controller
    _opusDecoder?.destroy(); // Clean up Opus decoder
    _opusDecoder = null;
  }
}
