import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as enc;
import 'package:opus_dart/opus_dart.dart';

class UdpService {
  String _host = '139.59.7.72';
  int _port = 9000;
  RawDatagramSocket? _socket;
  StreamSubscription? _socketSubscription;

  // Encryption details
  late enc.Key _aesKey;
  int _localSequence = 0;

  // Opus decoder/encoder
  SimpleOpusDecoder? _opusDecoder;
  SimpleOpusEncoder? _opusEncoder;
  Map<String, dynamic>? _audioParams;

  // *** NEW: StreamController to broadcast incoming decrypted audio data ***
  final StreamController<Uint8List> _audioDataController =
      StreamController.broadcast();
  Stream<Uint8List> get audioDataStream => _audioDataController.stream;

  Future<void> connect() async {
    try {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      log('UDP Service: Socket bound to ${_socket!.address.host}:${_socket!.port}');

      // *** NEW: Start listening for incoming data immediately ***
      _socketSubscription = _socket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          Datagram? datagram = _socket!.receive();
          if (datagram != null) {
            _handleIncomingData(datagram.data);
          }
        }
      });
    } on Exception catch (e) {
      log('UDP Service: Error binding socket: $e');
    }
  }

  void updateUdpConfig({
    required String host,
    required int port,
    required String key,
    required Map<String, dynamic> audioParams,
  }) {
    log('UDP Service: Updating config. Host: $host, Port: $port');
    _host = host;
    _port = port;
    _aesKey = enc.Key.fromBase16(key);
    _audioParams = audioParams;
    
    // Initialize Opus decoder/encoder with audio params
    try {
      log('UDP Service: Initializing Opus codec with sampleRate=${audioParams['sample_rate']}, channels=${audioParams['channels']}');
      
      _opusDecoder = SimpleOpusDecoder(
        sampleRate: audioParams['sample_rate'],
        channels: audioParams['channels'],
      );
      log('UDP Service: Opus decoder initialized successfully');
      
      _opusEncoder = SimpleOpusEncoder(
        sampleRate: audioParams['sample_rate'],
        channels: audioParams['channels'],
        application: Application.voip,
      );
      log('UDP Service: Opus encoder initialized successfully');
    } on Exception catch (e, stackTrace) {
      log('UDP Service: Failed to initialize Opus codec: $e');
      log('UDP Service: Stack trace: $stackTrace');
    }
  }

  // *** NEW: Method to handle and decrypt incoming packets ***
  void _handleIncomingData(Uint8List data) {
    if (data.length > 16) {
      try {
        final header = data.sublist(0, 16);
        final encryptedPayload = data.sublist(16);
        
        // Parse header to get packet info
        // final packetType = header[0];
        // final payloadLen = (header[2] << 8) | header[3];
        // final timestamp = (header[8] << 24) | (header[9] << 16) | (header[10] << 8) | header[11];
        // final sequence = (header[12] << 24) | (header[13] << 16) | (header[14] << 8) | header[15];

        // Use CTR mode with no padding (like Python's cryptography library)
        final encrypter = enc.Encrypter(
          enc.AES(_aesKey, mode: enc.AESMode.ctr, padding: null)
        );
        
        // Use header directly as IV (16 bytes)
        final iv = enc.IV(header);
        
        final decryptedBytes = encrypter.decryptBytes(
          enc.Encrypted(encryptedPayload),
          iv: iv,
        );
        
        // Log packet info periodically (commented out for now)
        // if (sequence % 16 == 0) {
        //   log('UDP Service: Received packet seq=$sequence, payload=$payloadLen bytes, decrypted=${decryptedBytes.length} bytes');
        // }

        // Decode Opus to PCM before adding to stream
        if (_opusDecoder != null && _audioParams != null) {
          try {
            // Decode returns Int16List which we need to convert to Uint8List
            final pcmData = _opusDecoder!.decode(
              input: Uint8List.fromList(decryptedBytes),
            );
            
            // Convert Int16List to Uint8List (little endian)
            final bytes = BytesBuilder();
            for (final sample in pcmData) {
              bytes.addByte(sample & 0xFF);
              bytes.addByte((sample >> 8) & 0xFF);
            }
            
            final outputBytes = bytes.toBytes();
            
            // Add the decoded PCM audio data to our stream
            _audioDataController.add(outputBytes);
          } on Exception catch (e) {
            log('UDP Service: Opus decoding error: $e');
          }
        } else {
          log('UDP Service: Opus decoder not initialized');
        }
      } on Exception catch (e) {
        log('UDP Service: Decryption error: $e');
      }
    }
  }

  void _sendEncryptedPacket(Uint8List payload) {
    if (_socket == null) {
      log('UDP Service: Cannot send packet - socket is null');
      return;
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final headerBuilder = BytesBuilder();
    headerBuilder.addByte(0x01); // packet_type
    headerBuilder.addByte(0x00); // flags
    headerBuilder.add(Uint8List(2)
      ..buffer.asByteData().setUint16(0, payload.length, Endian.big));
    headerBuilder
        .add(Uint8List(4)..buffer.asByteData().setUint32(0, 0, Endian.big));
    headerBuilder.add(
        Uint8List(4)..buffer.asByteData().setUint32(0, timestamp, Endian.big));
    headerBuilder.add(Uint8List(4)
      ..buffer.asByteData().setUint32(0, _localSequence, Endian.big));

    final header = headerBuilder.toBytes();
    
    // Use CTR mode with no padding to match Python implementation
    final encrypter = enc.Encrypter(
      enc.AES(_aesKey, mode: enc.AESMode.ctr, padding: null)
    );
    
    // Use header directly as IV
    final iv = enc.IV(header);
    final encryptedPayload = encrypter.encryptBytes(payload, iv: iv);

    final packetBuilder = BytesBuilder();
    packetBuilder.add(header);
    packetBuilder.add(encryptedPayload.bytes);

    final packet = packetBuilder.toBytes();
    _socket!.send(packet, InternetAddress(_host), _port);
    _localSequence++;
  }

  void sendPing(String sessionId) {
    log('UDP Service: Sending PING with session ID $sessionId');
    final pingPayload = Uint8List.fromList(utf8.encode('ping:$sessionId'));
    _sendEncryptedPacket(pingPayload);
  }

  void sendAudio(Uint8List pcmAudioData) {
    if (_opusEncoder == null || _audioParams == null) {
      log('UDP Service: Cannot send audio - encoder not initialized');
      return;
    }
    
    try {
      // Calculate frame size based on audio params
      final frameDuration = _audioParams!['frame_duration'] ?? 20;
      final frameSizeSamples = (_audioParams!['sample_rate'] * frameDuration / 1000).toInt();
      final expectedInputSize = frameSizeSamples * 2 * _audioParams!['channels']; // 2 bytes per sample
      
      // Only encode if we have a full frame
      if (pcmAudioData.length >= expectedInputSize) {
        // Convert Uint8List to Int16List (little endian PCM16)
        // FIXED: Proper little-endian conversion and sign handling
        final int16Data = Int16List(frameSizeSamples * _audioParams!['channels']);
        
        for (int i = 0; i < int16Data.length; i++) {
          final low = pcmAudioData[i * 2];
          final high = pcmAudioData[i * 2 + 1];
          
          // FIXED: Correct little endian conversion - low byte first, then high byte
          final unsigned = low | (high << 8);
          
          // FIXED: Proper signed 16-bit conversion
          int16Data[i] = unsigned <= 32767 ? unsigned : unsigned - 65536;
          
          // FIXED: Apply gain boost to improve audio levels (testing with 2x)
          int16Data[i] = (int16Data[i] * 2.0).clamp(-32768, 32767).toInt();
        }
        
        final opusData = _opusEncoder!.encode(
          input: int16Data,
        );
        
        _sendEncryptedPacket(opusData);
      }
    } on Exception catch (e) {
      log('UDP Service: ❌ Opus encoding error: $e');
    }
  }

  void disconnect() {
    _socketSubscription?.cancel();
    _socket?.close();
    _socket = null;
    _audioDataController.close();
    _opusDecoder?.destroy();
    _opusDecoder = null;
    _opusEncoder?.destroy();
    _opusEncoder = null;
    log('UDP Service: Socket closed.');
  }
}
