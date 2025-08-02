// lib/viewmodels/playground_viewmodel.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/audio_service.dart';
import '../services/communication_service.dart';

class PlaygroundViewModel extends ChangeNotifier {
  final CommunicationService _commService = CommunicationService();
  final AudioService _audioService = AudioService();
  final Logger _logger = Logger(
    printer: PrettyPrinter(methodCount: 1, printTime: true),
  );

  String _statusMessage = 'Initializing...';
  String get statusMessage => _statusMessage;

  bool _isLoading = true;
  bool get isLoading => _isLoading;

  bool _isTtsPlaying = false;
  bool get isTtsPlaying => _isTtsPlaying;

  bool _isRecording = false;
  bool get isRecording => _isRecording;

  StreamSubscription? _audioRecordingSubscription;

  PlaygroundViewModel() {
    _commService.onTtsStateChanged = (isPlaying) {
      _isTtsPlaying = isPlaying;
      if (!isPlaying && !_isLoading) {
        _logger.i("TTS phrase finished. Scheduling delayed player stop.");
        _audioService.stopPlayback();
        _startRecording();
      }
      notifyListeners();
    };

    _commService.onRecordStop = () {
      if (_isRecording) {
        _stopRecording();
      }
    };

    _audioService.onSilenceDetected = () {
      if (_isRecording) {
        _logger.i("Silence detected in ViewModel, stopping recording.");
        _stopRecording();
      }
    };
  }

  Future<void> initializeAndConnect() async {
    try {
      _updateStatus('Requesting permissions...');
      if (!await Permission.microphone.request().isGranted) {
        _updateStatus('Microphone permission denied.');
        return;
      }

      _updateStatus('Getting server config...');
      if (!await _commService.getOtaConfig()) throw Exception('OTA failed.');

      _updateStatus('Connecting...');
      if (!await _commService.connectMqtt()) throw Exception('MQTT failed.');

      _updateStatus('Establishing secure session...');
      _commService.startUdpListener(_audioService.playAudioChunk);
      if (!await _commService.sendHelloAndGetSession())
        throw Exception('Session failed.');

      _audioService.updateAudioParameters(_commService.getAudioParams());

      _updateStatus('Starting conversation...');
      await _sendInitialAudioPacket();

      _isLoading = false;
      _updateStatus('Connected! Waiting for welcome message...');
    } catch (e) {
      _logger.e('Initialization failed: $e');
      _updateStatus('Connection Failed: ${e.toString()}');
    }
  }

  Future<void> _sendInitialAudioPacket() async {
    _logger.i("Sending a single audio packet to trigger conversation...");
    // Start a temporary recording, get one packet, then stop.
    StreamSubscription? tempSubscription;
    final recordingStream = _audioService.startRecording();

    tempSubscription = recordingStream.listen((pcmData) {
      final opusData = _audioService.encodePcmToOpus(pcmData);
      if (opusData != null) {
        _commService.sendAudioPacket(opusData);
        _logger.i("Initial audio packet sent, stopping temporary recording.");
        // Once one packet is sent, stop this temporary process.
        tempSubscription?.cancel();
        _audioService.stopRecording();
      }
    });
  }

  void _startRecording() {
    if (_isRecording) return;
    _isRecording = true;
    _updateStatus('Listening...');

    final recordingStream = _audioService.startRecording();
    _audioRecordingSubscription = recordingStream.listen((pcmData) {
      final opusData = _audioService.encodePcmToOpus(pcmData);
      if (opusData != null) {
        _commService.sendAudioPacket(opusData);
      }
    }, onError: (err) => _logger.e("Audio recording error: $err"));
    notifyListeners();
  }

  void _stopRecording() {
    if (!_isRecording) return;
    _isRecording = false;
    _updateStatus('Got it! Thinking...');
    _audioService.stopRecording();
    _audioRecordingSubscription?.cancel();
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
    _audioService.stopPlayback(immediate: true);
    _audioService.dispose();
    super.dispose();
  }
}
