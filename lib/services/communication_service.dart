// File: services/communication_service.dart
// ---
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as enc;
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../models/ota_config.dart';

class CommunicationService {
  final _logger = Logger();
  static const String _serverIp = "64.227.170.31";
  static const int _otaPort = 8003;

  OtaConfig? _otaConfig;
  MqttServerClient? _mqttClient;
  RawDatagramSocket? _udpSocket;
  UdpSessionDetails? _udpSessionDetails;
  String? _deviceMac;
  int _udpLocalSequence = 0;

  // Callbacks to notify the ViewModel
  Function(bool isPlaying)? onTtsStateChanged;
  Function()? onRecordStop;

  CommunicationService() {
    // Use the hardcoded MAC address from the Python script
    _deviceMac = "00_16_3e_fa_3d_de";
    _logger.i("Using pre-registered device MAC: $_deviceMac");
  }

  Future<bool> getOtaConfig() async {
    try {
      final url = Uri.http('$_serverIp:$_otaPort', '');
      _logger.i("Requesting OTA with MAC: $_deviceMac");
      final response = await http
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: json.encode({'mac_address': _deviceMac}),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        _otaConfig = OtaConfig.fromJson(json.decode(response.body));
        _logger.i("OTA Config received successfully.");
        return true;
      } else {
        _logger.e(
          "Failed to get OTA config: ${response.statusCode} ${response.body}",
        );
        return false;
      }
    } catch (e) {
      _logger.e("Error getting OTA config: $e");
      return false;
    }
  }

  Future<bool> connectMqtt() async {
    if (_otaConfig == null) return false;
    final mqttCfg = _otaConfig!.mqtt;
    _mqttClient = MqttServerClient.withPort(
      mqttCfg.endpoint.split(":")[0],
      mqttCfg.clientId,
      int.parse(mqttCfg.endpoint.split(":")[1]),
    );
    _mqttClient!.logging(on: false);
    _mqttClient!.keepAlivePeriod = 20;
    _mqttClient!.onConnected = _onMqttConnected;
    _mqttClient!.onDisconnected = () => _logger.w('MQTT Disconnected');
    _mqttClient!.onSubscribed = (topic) => _logger.i('Subscribed to: $topic');

    final connMess = MqttConnectMessage()
        .withClientIdentifier(mqttCfg.clientId)
        .withWillTopic('willtopic')
        .withWillMessage('My Will message')
        .startClean()
        .withWillQos(MqttQos.atLeastOnce)
        .authenticateAs(mqttCfg.username, mqttCfg.password);
    _mqttClient!.connectionMessage = connMess;

    try {
      await _mqttClient!.connect();
      _mqttClient!.updates!.listen(_onMqttMessage);
      return true;
    } catch (e) {
      _logger.e('Exception: $e');
      _mqttClient!.disconnect();
      return false;
    }
  }

  void _onMqttConnected() {
    _logger.i('MQTT Client Connected');
    final p2pTopic = 'devices/p2p/$_deviceMac';
    _mqttClient!.subscribe(p2pTopic, MqttQos.atLeastOnce);
  }

  void _onMqttMessage(List<MqttReceivedMessage<MqttMessage>> event) {
    final MqttPublishMessage recMess = event[0].payload as MqttPublishMessage;
    final String payloadStr = MqttPublishPayload.bytesToStringAsString(
      recMess.payload.message,
    );
    final Map<String, dynamic> payload = json.decode(payloadStr);
    _logger.d('MQTT Message received: $payload');

    final type = payload['type'];
    final state = payload['state'];

    if (type == 'hello' && payload.containsKey('udp')) {
      // This is handled by sendHelloAndGetSession now, but kept as a fallback
      if (_udpSessionDetails == null) {
        _udpSessionDetails = UdpSessionDetails.fromJson(payload);
        _logger.i("UDP Session details received via general listener.");
      }
    } else if (type == 'tts') {
      onTtsStateChanged?.call(state == 'start');
    } else if (type == 'record_stop') {
      onRecordStop?.call();
    }
  }

  Future<bool> sendHelloAndGetSession() async {
    if (_mqttClient == null || _otaConfig == null) return false;

    final helloPayload = {
      "type": "hello",
      "client_id": _otaConfig!.mqtt.clientId,
    };
    
    // Send to device-server topic
    _publishMqttMessage('device-server', helloPayload);
    
    // Also send to internal/server-ingest with wrapped format (keeping typo for compatibility)
    final wrappedHello = {
      "orginal_payload": helloPayload,  // Note: keeping original typo
      "sender_client_id": _deviceMac,
    };
    _publishMqttMessage('internal/server-ingest', wrappedHello);
    _logger.i("Sent 'hello' message to both topics.");

    try {
      // --- FIX START ---
      // `firstWhere` returns the element from the stream, which is a List.
      final List<MqttReceivedMessage<MqttMessage>> event = await _mqttClient!
          .updates!
          .firstWhere((List<MqttReceivedMessage<MqttMessage>> c) {
            // The condition checks the first message in the list `c[0]`
            final MqttPublishMessage m = c[0].payload as MqttPublishMessage;
            final String p = MqttPublishPayload.bytesToStringAsString(
              m.payload.message,
            );
            try {
              final Map<String, dynamic> payload = json.decode(p);
              return payload['type'] == 'hello' && payload.containsKey('udp');
            } catch (e) {
              return false;
            }
          })
          .timeout(const Duration(seconds: 10)); // Add a timeout

      // Now extract the actual message from the list
      final MqttPublishMessage m = event[0].payload as MqttPublishMessage;
      final String p = MqttPublishPayload.bytesToStringAsString(
        m.payload.message,
      );
      final Map<String, dynamic> payload = json.decode(p);
      // --- FIX END ---

      _udpSessionDetails = UdpSessionDetails.fromJson(payload);
      _logger.i("UDP Session details received.");
      await _pingUdp();
      return true;
    } catch (e) {
      _logger.e(
        "Did not receive 'hello' response with UDP details in time. Error: $e",
      );
      return false;
    }
  }

  Future<void> _pingUdp() async {
    if (_udpSessionDetails == null) return;
    
    // Close any existing socket
    _udpSocket?.close();
    
    // Create new socket (like Python does)
    _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    
    _logger.i("UDP socket created on ${_udpSocket!.address.address}:${_udpSocket!.port}");
    _logger.i("Local socket: ${_udpSocket!.address.host}:${_udpSocket!.port}");
    
    // Start listening for UDP packets IMMEDIATELY after creating socket (like Python)
    _startUdpListenerInternal();
    
    final serverUdpAddr = InternetAddress(_serverIp);
    
    // Send ping after listener is set up
    final pingPayload = utf8.encode('ping:${_udpSessionDetails!.sessionId}');
    _logger.d("Ping payload: ${utf8.decode(pingPayload)}");
    
    final encryptedPing = _encryptPacket(Uint8List.fromList(pingPayload));
    
    // Log encrypted ping for debugging
    _logger.d("Encrypted ping size: ${encryptedPing.length} bytes");
    _logger.d("First 16 bytes (header): ${encryptedPing.sublist(0, 16).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}");
    
    final bytesSent = _udpSocket!.send(
      encryptedPing,
      serverUdpAddr,
      _udpSessionDetails!.udp.port,
    );
    
    _logger.i("UDP Ping sent to $_serverIp:${_udpSessionDetails!.udp.port} ($bytesSent bytes)");
    _logger.d("Session ID: ${_udpSessionDetails!.sessionId}");
    _logger.d("Encryption key: ${_udpSessionDetails!.udp.key}");
  }

  // Store the audio chunk callback for later use
  Function(Uint8List)? _onAudioChunk;
  
  void startUdpListener(Function(Uint8List) onAudioChunk) {
    _onAudioChunk = onAudioChunk;
    // Don't start listening here - it will be started after ping
  }
  
  void _startUdpListenerInternal() {
    if (_udpSocket == null || _udpSessionDetails == null) {
      _logger.w("Cannot start UDP listener: socket=$_udpSocket, sessionDetails=$_udpSessionDetails");
      return;
    }
    
    final aesKey = enc.Key.fromBase16(_udpSessionDetails!.udp.key);
    
    // Log UDP socket details
    _logger.i("UDP socket bound to: ${_udpSocket!.address.address}:${_udpSocket!.port}");
    _logger.i("Expecting UDP packets from: $_serverIp:${_udpSessionDetails!.udp.port}");
    
    int packetCount = 0;
    int totalBytesReceived = 0;
    int audioPacketCount = 0;

    _udpSocket!.listen((RawSocketEvent event) {
      if (event == RawSocketEvent.read) {
        Datagram? d = _udpSocket!.receive();
        if (d == null) {
          return;
        }

        final data = d.data;
        packetCount++;
        totalBytesReceived += data.length;
        
        // Log first few packets for debugging
        if (packetCount <= 3) {
          _logger.i("📦 UDP packet #$packetCount: ${data.length} bytes from ${d.address}:${d.port}");
          _logger.d("Raw data (first 32 bytes): ${data.take(32).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}${data.length > 32 ? '...' : ''}");
        }
        
        if (data.length > 16) {
          final header = data.sublist(0, 16);
          final encryptedPayload = data.sublist(16);

          final iv = enc.IV(header);
          final encrypter = enc.Encrypter(
            enc.AES(aesKey, mode: enc.AESMode.ctr, padding: null),
          );

          try {
            final decrypted = encrypter.decryptBytes(
              enc.Encrypted(encryptedPayload),
              iv: iv,
            );
            
            // Parse packet header to get sequence info
            if (header.length >= 16) {
              final headerData = ByteData.sublistView(header);
              final packetType = headerData.getUint8(0);
              final flags = headerData.getUint8(1);
              final payloadLen = headerData.getUint16(2, Endian.big);
              final sequence = headerData.getUint32(12, Endian.big);
              
              if (packetType == 0x01) { // Audio packet
                audioPacketCount++;
                if (audioPacketCount <= 5 || audioPacketCount % 10 == 0) {
                  _logger.i("🎵 Audio packet #$audioPacketCount (seq: $sequence): ${decrypted.length} bytes Opus audio");
                }
                
                // Pass to audio callback if available
                if (_onAudioChunk != null) {
                  _onAudioChunk!(Uint8List.fromList(decrypted));
                } else {
                  _logger.w("Audio callback not set - packet dropped");
                }
              } else {
                _logger.d("Non-audio packet type: $packetType, len: $payloadLen");
              }
            }
          } catch (e) {
            _logger.e("Decryption failed for packet #$packetCount: $e");
          }
        } else {
          _logger.d("Small packet received: ${data.length} bytes (possibly control packet)");
        }
      }
    });
    _logger.i("✅ UDP Listener started and waiting for packets.");
  }

  Future<void> triggerConversation() async {
    final listenPayload = {
      "type": "listen",
      "session_id": _udpSessionDetails!.sessionId,
      "state": "detect",
      "text": "hello baby",
    };
    
    // Send to device-server topic
    _publishMqttMessage('device-server', listenPayload);
    
    // Also send to internal/server-ingest with wrapped format
    final wrappedListen = {
      "orginal_payload": listenPayload,  // Note: keeping original typo
      "sender_client_id": _deviceMac,
    };
    _publishMqttMessage('internal/server-ingest', wrappedListen);
    _logger.i("Sent 'listen' message to both topics to trigger conversation.");
  }

  void sendAudioPacket(Uint8List pcmData) {
    if (_udpSocket == null || _udpSessionDetails == null) return;
    // In a real implementation, you would encode PCM to Opus here.
    final encryptedPacket = _encryptPacket(pcmData);
    final serverUdpAddr = InternetAddress(_serverIp);
    _udpSocket!.send(
      encryptedPacket,
      serverUdpAddr,
      _udpSessionDetails!.udp.port,
    );
  }

  void sendAbort() {
    final abortPayload = {
      "type": "abort",
      "session_id": _udpSessionDetails!.sessionId,
    };
    
    // Send to device-server topic
    _publishMqttMessage('device-server', abortPayload);
    
    // Also send to internal/server-ingest with wrapped format
    final wrappedAbort = {
      "orginal_payload": abortPayload,  // Note: keeping original typo
      "sender_client_id": _deviceMac,
    };
    _publishMqttMessage('internal/server-ingest', wrappedAbort);
    _logger.i("Sent 'abort' message to both topics.");
  }

  Uint8List _encryptPacket(Uint8List payload) {
    if (_udpSessionDetails == null) return Uint8List(0);
    final aesKey = enc.Key.fromBase16(_udpSessionDetails!.udp.key);
    final ByteData headerData = ByteData(16);

    // --- FIX: Explicitly use Big Endian to match Python's '>' format specifier ---
    headerData.setUint8(0, 0x01); // packet_type
    headerData.setUint8(1, 0x00); // flags
    headerData.setUint16(2, payload.length, Endian.big); // payload_len
    headerData.setUint32(4, 0, Endian.big); // ssrc
    headerData.setUint32(
      8,
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      Endian.big,
    ); // timestamp
    headerData.setUint32(12, _udpLocalSequence++, Endian.big); // sequence

    final header = headerData.buffer.asUint8List();
    final iv = enc.IV(header);
    final encrypter = enc.Encrypter(
      enc.AES(aesKey, mode: enc.AESMode.ctr, padding: null),
    );
    final encrypted = encrypter.encryptBytes(payload, iv: iv);

    return Uint8List.fromList(header + encrypted.bytes);
  }

  void _publishMqttMessage(String topic, Map<String, dynamic> payload) {
    final builder = MqttClientPayloadBuilder();
    builder.addString(json.encode(payload));
    _mqttClient?.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
  }

  void cleanup() {
    _logger.i("Cleaning up communication service...");
    if (_mqttClient != null && _udpSessionDetails != null) {
      final goodbyePayload = {
        "type": "goodbye",
        "session_id": _udpSessionDetails!.sessionId,
      };
      
      // Send to device-server topic
      _publishMqttMessage('device-server', goodbyePayload);
      
      // Also send to internal/server-ingest with wrapped format
      final wrappedGoodbye = {
        "orginal_payload": goodbyePayload,  // Note: keeping original typo
        "sender_client_id": _deviceMac,
      };
      _publishMqttMessage('internal/server-ingest', wrappedGoodbye);
      _logger.i("Sent 'goodbye' message to both topics.");
    }
    _mqttClient?.disconnect();
    _udpSocket?.close();
  }
}
