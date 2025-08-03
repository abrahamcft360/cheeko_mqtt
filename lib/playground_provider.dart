import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:typed_data';

import 'package:cheeko_mqtt/audio_recorder_service.dart';
import 'package:cheeko_mqtt/mqtt_service.dart';
import 'package:cheeko_mqtt/udp_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:logger/logger.dart';

// Enum for the new interaction process
enum PlaygroundState {
  initial,
  connecting,
  waitingForWelcome,
  playingWelcome,
  listening,
  processing,
  responding,
  error,
}

class PlaygroundProvider extends ChangeNotifier {
  // Services
  late MqttService _mqttService;
  final UdpService _udpService = UdpService();
  final AudioRecorderService _audioRecorderService = AudioRecorderService();

  final FlutterSoundPlayer _player = FlutterSoundPlayer(logLevel: Level.off);

  // State
  PlaygroundState _state = PlaygroundState.initial;
  String _statusMessage = "Initializing...";
  StreamSubscription? _mqttSubscription;
  StreamSubscription? _audioRecordingSubscription;
  StreamSubscription? _udpAudioSubscription;

  // *** NEW: State for displaying the live text ***
  String _liveResponseText = "";

  // Dynamic values from the server
  String? _clientId;
  String? _sessionId;
  Map<String, dynamic>? _audioParams;

  // Audio buffer for accumulating PCM data before encoding
  final List<int> _audioBuffer = [];

  // Audio playback buffer for jitter control
  final List<Uint8List> _playbackBuffer = [];
  bool _isPlayerReady = false;

  // Getters
  PlaygroundState get state => _state;
  String get statusMessage => _statusMessage;
  String get liveResponseText => _liveResponseText;

  PlaygroundProvider() {
    log('Initializing PlaygroundProvider...');
    _init();
  }

  Future<void> _init() async {
    _state = PlaygroundState.connecting;
    notifyListeners();

    _clientId = "00_16_3e_fa_3d_de";

    await _player.openPlayer();

    _mqttService = MqttService(clientId: _clientId!);
    final bool connected = await _mqttService.connect();

    if (connected) {
      await _udpService.connect();
      _mqttSubscription = _mqttService.messages.listen(_handleMqttMessage);
      _udpAudioSubscription = _udpService.audioDataStream.listen(
        _onAudioDataReceived,
      );

      _sendMqttEvent('device-server', 'hello', {"client_id": _clientId});
      _statusMessage = "Connecting to Cheeko...";
      _state = PlaygroundState.waitingForWelcome;
      notifyListeners();
    } else {
      _state = PlaygroundState.error;
      _statusMessage = "Could not connect to the server.";
      log('Failed to connect to MQTT broker.');
      notifyListeners();
    }
  }

  void _handleMqttMessage(Map<String, dynamic> data) {
    final type = data['type'];

    if (type == 'hello' && data['udp'] != null) {
      _sessionId = data['session_id'];
      final udpConfig = data['udp'];
      _audioParams = data['audio_params'];

      _udpService.updateUdpConfig(
        host: udpConfig['server'],
        port: udpConfig['port'],
        key: udpConfig['key'],
        audioParams: _audioParams!,
      );
      _udpService.sendPing(_sessionId!);

      _sendMqttEvent('device-server', 'listen', {
        "session_id": _sessionId,
        "state": "detect",
        "text": "hello baby",
      });
      _statusMessage = "Waiting for Cheeko's welcome...";
      notifyListeners();
    } else if (type == 'tts' && data['state'] == 'start') {
      _statusMessage = "Cheeko is speaking...";
      // Set state based on current state
      if (_state == PlaygroundState.waitingForWelcome) {
        _state = PlaygroundState.playingWelcome;
      } else {
        _state = PlaygroundState.responding;
      }
      _startPlayback();
      notifyListeners();
    } else if (type == 'tts' && data['state'] == 'sentence_start') {
      // *** NEW: Update the live text when a new sentence starts ***
      _liveResponseText = data['text'] ?? "";
      notifyListeners();
    } else if (type == 'tts' && data['state'] == 'stop') {
      if (_state == PlaygroundState.playingWelcome ||
          _state == PlaygroundState.responding) {
        _stopPlayback();
        _startListening();
      }
    } else if (type == 'record_stop') {
      stopSpeakingAndProcess();
    } else if (type == 'stt') {
      final transcription = data['text'] ?? '';
      log('🎯 SPEECH RECOGNIZED: "$transcription"');
      _statusMessage = 'You said: "$transcription"';
      notifyListeners();
    }
  }

  void _onAudioDataReceived(Uint8List data) {
    // This now receives decoded PCM audio data
    if (_isPlayerReady && _player.isPlaying && _player.uint8ListSink != null) {
      _player.uint8ListSink!.add(data);
    } else {
      // Buffer the audio data if player is not ready
      _playbackBuffer.add(data);

      // Limit buffer size to prevent memory issues
      if (_playbackBuffer.length > 100) {
        _playbackBuffer.removeAt(0);
      }
    }
  }

  // *** FIXED METHOD ***
  Future<void> _startPlayback() async {
    if (_audioParams == null) {
      log("Cannot start playback: audio params not set.");
      return;
    }

    try {
      // Now we're playing raw PCM data, not Opus
      await _player.startPlayerFromStream(
        codec: Codec.pcm16, // Raw PCM 16-bit
        numChannels: _audioParams!['channels'],
        sampleRate: _audioParams!['sample_rate'],
        interleaved: true, // Required parameter for interleaved audio
        bufferSize: 8192, // Buffer size for streaming
      );
      // Mark player as ready
      _isPlayerReady = true;

      // Flush any buffered audio data
      if (_playbackBuffer.isNotEmpty) {
        for (final chunk in _playbackBuffer) {
          if (_player.uint8ListSink != null) {
            _player.uint8ListSink!.add(chunk);
          }
        }
        _playbackBuffer.clear();
      }
    } on Exception catch (e) {
      log("Failed to start audio playback: $e");
      _state = PlaygroundState.error;
      _statusMessage = "Audio playback error";
      notifyListeners();
    }
  }

  Future<void> _stopPlayback() async {
    if (_player.isPlaying) {
      await _player.stopPlayer();
      _isPlayerReady = false; // Reset player ready state
      _playbackBuffer.clear(); // Clear any buffered audio
      _liveResponseText = ""; // Clear the text after speaking
      notifyListeners();
    }
  }

  void _sendMqttEvent(String topic, String type, Map<String, dynamic> params) {
    final payload = {"type": type, ...params};
    final payloadStr = json.encode(payload);
    _mqttService.publish(topic, payloadStr);
  }

  Future<void> _startListening() async {
    // Ensure clean state before starting new recording session
    await _ensureRecordingCleanup();

    _state = PlaygroundState.listening;
    _statusMessage = "Listening... Speak now!";
    notifyListeners();

    _audioBuffer.clear(); // Ensure buffer is clean

    log('PlaygroundProvider: Starting recording session');

    final bool recordingStarted = await _audioRecorderService.startRecording();
    if (recordingStarted) {
      _audioRecordingSubscription = _audioRecorderService.audioStream.listen(
        _handleRecordedAudio,
        onError: (error) {
          log('PlaygroundProvider: Error in audio stream: $error');
          _handleRecordingError(error);
        },
      );
    } else {
      _state = PlaygroundState.error;
      _statusMessage = "Failed to start recording.";
      log('PlaygroundProvider: Failed to start audio recording');
      notifyListeners();
    }
  }

  // Ensure recording is properly cleaned up between sessions
  Future<void> _ensureRecordingCleanup() async {
    try {
      if (_audioRecordingSubscription != null) {
        await _audioRecordingSubscription?.cancel();
        _audioRecordingSubscription = null;
      }

      // Stop any ongoing recording
      await _audioRecorderService.stopRecording();
    } on Exception catch (e) {
      log('PlaygroundProvider: Error during recording cleanup: $e');
    }
  }

  // Handle recording errors gracefully
  void _handleRecordingError(dynamic error) {
    log('PlaygroundProvider: Recording error: $error');
    _state = PlaygroundState.error;
    _statusMessage = "Recording error occurred";
    notifyListeners();

    // Attempt to cleanup and reset
    _ensureRecordingCleanup();
  }

  void _handleRecordedAudio(Uint8List data) {
    // Accumulate audio data
    _audioBuffer.addAll(data);

    if (_audioParams == null) return;

    // Calculate expected frame size
    final frameDuration = _audioParams!['frame_duration'] ?? 20;
    final frameSizeSamples =
        (_audioParams!['sample_rate'] * frameDuration / 1000).toInt();
    final expectedInputSize =
        frameSizeSamples * 2 * _audioParams!['channels']; // 2 bytes per sample

    // Check for buffer overflow (prevent memory issues)
    if (_audioBuffer.length > expectedInputSize * 10) {
      final overflow = (_audioBuffer.length - (expectedInputSize * 5)).toInt();
      _audioBuffer.removeRange(0, overflow);
      log('PlaygroundProvider: Buffer overflow, dropped $overflow bytes');
    }

    // Send complete frames
    while (_audioBuffer.length >= expectedInputSize) {
      try {
        if (expectedInputSize <= 0) break;

        final frameData =
            Uint8List.fromList(_audioBuffer.take(expectedInputSize).toList());

        if (frameData.length != expectedInputSize) break;

        if (_audioBuffer.length >= expectedInputSize) {
          _audioBuffer.removeRange(0, expectedInputSize);
          _udpService.sendAudio(frameData);
        } else {
          break;
        }
      } on Exception catch (e) {
        log('PlaygroundProvider: Error processing frame: $e');
        _audioBuffer.clear();
        break;
      }
    }
  }

  Future<void> stopSpeakingAndProcess() async {
    if (_state != PlaygroundState.listening) return;

    _state = PlaygroundState.processing;
    _statusMessage = "Cheeko is thinking...";
    notifyListeners();

    await _audioRecorderService.stopRecording();
    await _audioRecordingSubscription?.cancel();
    _audioRecordingSubscription = null;
    _audioBuffer.clear(); // Clear any remaining audio data
  }

  @override
  void dispose() {
    log('PlaygroundProvider: Disposing');
    _cleanupAsync();
    super.dispose();
  }

  // Async cleanup to properly await dispose methods
  Future<void> _cleanupAsync() async {
    try {
      await _player.closePlayer();

      // Send goodbye message if session exists
      if (_sessionId != null) {
        _sendMqttEvent('device-server', 'goodbye', {"session_id": _sessionId});
      }

      // Cancel subscriptions
      await _mqttSubscription?.cancel();
      await _audioRecordingSubscription?.cancel();
      await _udpAudioSubscription?.cancel();

      // Dispose services
      _mqttService.dispose();
      _udpService.disconnect();
      await _audioRecorderService.dispose();

      // Clear buffers
      _audioBuffer.clear();
      _playbackBuffer.clear();
    } on Exception catch (e) {
      log('PlaygroundProvider: Error during cleanup: $e');
    }
  }
}
