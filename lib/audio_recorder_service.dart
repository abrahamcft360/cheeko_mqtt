import 'dart:async';
import 'dart:developer';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

class AudioRecorderService {
  final _audioRecorder = AudioRecorder();
  StreamSubscription? _audioStreamSubscription;
  bool _isRecording = false;

  final StreamController<Uint8List> _audioStreamController =
      StreamController.broadcast();
  Stream<Uint8List> get audioStream => _audioStreamController.stream;

  Future<bool> _requestPermission() async {
    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  // Simplified: No silence detection, just continuous recording
  Future<bool> startRecording() async {
    final hasPermission = await _requestPermission();
    if (!hasPermission) {
      log('AudioRecorderService: Microphone permission denied.');
      return false;
    }

    if (_isRecording) {
      log('AudioRecorderService: Already recording.');
      return true;
    }

    try {
      log('AudioRecorderService: Starting recording...');
      
      // Configure for 16kHz PCM16 mono audio
      const config = RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      );
      
      final stream = await _audioRecorder.startStream(config);
      _isRecording = true;
      
      int totalBytesReceived = 0;
      int chunksReceived = 0;

      _audioStreamSubscription = stream.listen(
        (data) {
          chunksReceived++;
          totalBytesReceived += data.length;
          
          // Add data to stream
          _audioStreamController.add(data);
        },
        onError: (error) {
          log('AudioRecorderService: Stream error: $error');
          _isRecording = false;
        },
        onDone: () {
          log('AudioRecorderService: Stream done. Total chunks: $chunksReceived, bytes: $totalBytesReceived');
          _isRecording = false;
        },
      );
      
      log('AudioRecorderService: Recording started successfully');
      return true;
    } catch (e) {
      log('AudioRecorderService: Error starting recording: $e');
      _isRecording = false;
      return false;
    }
  }

  Future<void> stopRecording() async {
    try {
      log('AudioRecorderService: Stopping recording...');
      await _audioStreamSubscription?.cancel();
      _audioStreamSubscription = null;
      
      if (_isRecording) {
        await _audioRecorder.stop();
        _isRecording = false;
        log('AudioRecorderService: Recording stopped.');
      }
    } catch (e) {
      log('AudioRecorderService: Error stopping recording: $e');
      _isRecording = false;
    }
  }

  void dispose() {
    _audioStreamSubscription?.cancel();
    _audioRecorder.dispose();
    _audioStreamController.close();
  }
}
