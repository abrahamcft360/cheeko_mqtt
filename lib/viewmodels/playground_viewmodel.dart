import 'dart:async';

import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/audio_service.dart';
import '../services/communication_service.dart';

class PlaygroundViewModel extends ChangeNotifier {
  final CommunicationService _commService = CommunicationService();
  final AudioService _audioService = AudioService();
  final Logger _logger = Logger();

  String _statusMessage = 'Initializing...';
  String get statusMessage => _statusMessage;

  bool _isLoading = true;
  bool get isLoading => _isLoading;

  bool _areButtonsEnabled = false;
  bool get areButtonsEnabled => _areButtonsEnabled;

  bool _isTtsPlaying = false;
  bool get isTtsPlaying => _isTtsPlaying;

  bool _isRecording = false;
  bool get isRecording => _isRecording;

  double get volume => _audioService.volume;

  StreamSubscription? _audioRecordingSubscription;

  PlaygroundViewModel() {
    _commService.onTtsStateChanged = (isPlaying) {
      _isTtsPlaying = isPlaying;
      if (!isPlaying && !_isLoading) {
        // When TTS stops, we are ready to listen
        _statusMessage = 'Ready to listen. Tap the mic to speak.';
      }
      notifyListeners();
    };

    _commService.onRecordStop = () {
      if (_isRecording) {
        _stopRecording();
        _statusMessage = 'Processing your speech...';
        notifyListeners();
      }
    };
  }

  Future<void> initializeAndConnect() async {
    try {
      _updateStatus('Requesting permissions...');
      final micPermission = await Permission.microphone.request();
      if (micPermission.isDenied) {
        _updateStatus('Microphone permission denied. Cannot proceed.');
        _isLoading = false;
        notifyListeners();
        return;
      }

      _updateStatus('Getting server config...');
      bool otaSuccess = await _commService.getOtaConfig();
      if (!otaSuccess) throw Exception('Failed to get server config.');

      _updateStatus('Connecting to MQTT...');
      bool mqttSuccess = await _commService.connectMqtt();
      if (!mqttSuccess) throw Exception('Failed to connect to MQTT.');

      await Future.delayed(
        const Duration(seconds: 1),
      ); // Give MQTT time to subscribe

      _updateStatus('Establishing secure session...');
      bool sessionSuccess = await _commService.sendHelloAndGetSession();
      if (!sessionSuccess) throw Exception('Failed to establish session.');

      _commService.startUdpListener(_audioService.playAudioChunk);

      _updateStatus('Starting conversation...');
      await _commService.triggerConversation();

      _isLoading = false;
      _areButtonsEnabled = true;
      _statusMessage = 'Connected! Waiting for welcome message...';
      notifyListeners();
    } catch (e) {
      _logger.e('Initialization failed: $e');
      _updateStatus('Connection Failed: ${e.toString()}');
      _isLoading = false;
      notifyListeners();
    }
  }

  void handleRightButtonTap() {
    if (_isTtsPlaying) {
      // Abort TTS
      _commService.sendAbort();
      _audioService.stopPlayback();
      _statusMessage = 'Aborted. Tap the mic to speak.';
      _isTtsPlaying = false;
      notifyListeners();
    } else {
      // Toggle recording
      if (_isRecording) {
        _stopRecording();
      } else {
        _startRecording();
      }
    }
  }

  void _startRecording() {
    if (!_areButtonsEnabled) return;
    _isRecording = true;
    _statusMessage = 'Listening...';
    notifyListeners();

    _audioService.startRecording();
    _audioRecordingSubscription = _audioService.recordingStream.listen(
      (data) {
        _commService.sendAudioPacket(data);
      },
      onError: (err) {
        _logger.e("Audio recording error: $err");
        _stopRecording();
      },
    );
  }

  void _stopRecording() {
    _isRecording = false;
    _statusMessage = 'Recording stopped. Waiting for response...';
    _audioService.stopRecording();
    _audioRecordingSubscription?.cancel();
    _audioRecordingSubscription = null;
    notifyListeners();
  }

  void adjustVolume({required bool increase}) {
    _audioService.setVolume(increase: increase);
    notifyListeners();
  }

  void _updateStatus(String message) {
    _statusMessage = message;
    notifyListeners();
  }

  @override
  void dispose() {
    _logger.i("ViewModel disposing. Cleaning up resources.");
    _audioRecordingSubscription?.cancel();
    _commService.cleanup();
    _audioService.dispose();
    super.dispose();
  }
}
