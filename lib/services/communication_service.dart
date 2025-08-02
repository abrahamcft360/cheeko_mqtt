// lib/services/communication_service.dart
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

  Function(bool isPlaying)? onTtsStateChanged;
  Function()? onRecordStop;
  Function(Uint8List)? _onAudioChunk;

  AudioParams getAudioParams() =>
      _udpSessionDetails?.audioParams ??
      AudioParams(channels: 1, frameDuration: 60, sampleRate: 16000);

  CommunicationService() {
    _deviceMac = "00_16_3e_fa_3d_de";
    _logger.i("Using pre-registered device MAC: $_deviceMac");
  }

  Future<bool> getOtaConfig() async {
    try {
      final url = Uri.http('$_serverIp:$_otaPort', '');
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
      }
      _logger.e(
        "Failed to get OTA config: ${response.statusCode} ${response.body}",
      );
      return false;
    } catch (e) {
      _logger.e("Error getting OTA config: $e");
      return false;
    }
  }

  Future<bool> connectMqtt() async {
    if (_otaConfig == null) return false;
    final mqttCfg = _otaConfig!.mqtt;
    _mqttClient = MqttServerClient.withPort(
        mqttCfg.endpoint.split(":")[0], mqttCfg.clientId, 1883);
    _mqttClient!.logging(on: false);
    _mqttClient!.keepAlivePeriod = 20;
    _mqttClient!.onConnected = _onMqttConnected;
    _mqttClient!.onDisconnected = () => _logger.w('MQTT Disconnected');

    final connMess = MqttConnectMessage()
        .withClientIdentifier(mqttCfg.clientId)
        .startClean()
        .authenticateAs(mqttCfg.username, mqttCfg.password);
    _mqttClient!.connectionMessage = connMess;

    try {
      await _mqttClient!.connect();
      _mqttClient!.updates!.listen(_onMqttMessage);
      return true;
    } catch (e) {
      _logger.e('MQTT connection exception: $e');
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
    final payloadStr =
        MqttPublishPayload.bytesToStringAsString(recMess.payload.message);
    final payload = json.decode(payloadStr);

    final type = payload['type'];
    final state = payload['state'];

    if (type == 'hello' && payload.containsKey('udp')) {
      if (_udpSessionDetails == null) {
        _udpSessionDetails = UdpSessionDetails.fromJson(payload);
        _logger.i("UDP Session details received.");
      }
    } else if (type == 'tts') {
      onTtsStateChanged?.call(state == 'start' || state == 'sentence_start');
    } else if (type == 'record_stop') {
      onRecordStop?.call();
    }
  }

  Future<bool> sendHelloAndGetSession() async {
    if (_mqttClient == null || _otaConfig == null) return false;

    final helloPayload = {
      "type": "hello",
      "client_id": _otaConfig!.mqtt.clientId
    };
    _publishMqttMessage('device-server', helloPayload);

    try {
      final event = await _mqttClient!.updates!
          .firstWhere((c) {
            final MqttPublishMessage m = c[0].payload as MqttPublishMessage;
            final p =
                MqttPublishPayload.bytesToStringAsString(m.payload.message);
            try {
              final payload = json.decode(p);
              return payload['type'] == 'hello' && payload.containsKey('udp');
            } catch (e) {
              return false;
            }
          })
          .timeout(const Duration(seconds: 10));

      final MqttPublishMessage m = event[0].payload as MqttPublishMessage;
      final p = MqttPublishPayload.bytesToStringAsString(m.payload.message);
      _udpSessionDetails = UdpSessionDetails.fromJson(json.decode(p));
      _logger.i("UDP Session details received and processed.");
      await _pingUdp();
      return true;
    } catch (e) {
      _logger.e("Did not receive 'hello' response. Error: $e");
      return false;
    }
  }

  Future<void> _pingUdp() async {
    if (_udpSessionDetails == null) return;
    _udpSocket?.close();
    _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _startUdpListenerInternal();

    final pingPayload = utf8.encode('ping:${_udpSessionDetails!.sessionId}');
    final encryptedPing = _encryptPacket(Uint8List.fromList(pingPayload));
    _udpSocket!.send(encryptedPing, InternetAddress(_serverIp),
        _udpSessionDetails!.udp.port);
    _logger.i(
        "UDP Ping sent to $_serverIp:${_udpSessionDetails!.udp.port}");
  }

  void startUdpListener(Function(Uint8List) onAudioChunk) {
    _onAudioChunk = onAudioChunk;
  }

  void _startUdpListenerInternal() {
    if (_udpSocket == null) return;
    _logger.i(
        "UDP Listener started on ${_udpSocket!.address.host}:${_udpSocket!.port}");

    final aesKey = enc.Key.fromBase16(_udpSessionDetails!.udp.key);
    _udpSocket!.listen((RawSocketEvent event) {
      if (event == RawSocketEvent.read) {
        Datagram? d = _udpSocket!.receive();
        if (d == null || d.data.length <= 16) return;

        final header = d.data.sublist(0, 16);
        final encryptedPayload = d.data.sublist(16);

        final iv = enc.IV(header);
        final encrypter =
            enc.Encrypter(enc.AES(aesKey, mode: enc.AESMode.ctr, padding: null));

        try {
          final decrypted =
              encrypter.decryptBytes(enc.Encrypted(encryptedPayload), iv: iv);
          final headerData = ByteData.sublistView(header);
          final packetType = headerData.getUint8(0);
          final sequence = headerData.getUint32(12, Endian.big);

          if (packetType == 0x01) { // Audio Packet
            _logger.i(
                "🎵 RX Audio | Seq: $sequence | Size: ${decrypted.length} bytes");
            _onAudioChunk?.call(Uint8List.fromList(decrypted));
          }
        } catch (e) {
          _logger.e("Decryption/Processing failed: $e");
        }
      }
    });
  }

  void sendAudioPacket(Uint8List opusData) {
    if (_udpSocket == null) return;
    final encryptedPacket = _encryptPacket(opusData);
    _udpSocket!.send(encryptedPacket, InternetAddress(_serverIp),
        _udpSessionDetails!.udp.port);
  }

  Uint8List _encryptPacket(Uint8List payload) {
    if (_udpSessionDetails == null) return Uint8List(0);
    final aesKey = enc.Key.fromBase16(_udpSessionDetails!.udp.key);
    final headerData = ByteData(16);

    headerData.setUint8(0, 0x01);
    headerData.setUint16(2, payload.length, Endian.big);
    headerData.setUint32(
        8, DateTime.now().millisecondsSinceEpoch ~/ 1000, Endian.big);
    headerData.setUint32(12, _udpLocalSequence++, Endian.big);

    final header = headerData.buffer.asUint8List();
    final iv = enc.IV(header);
    final encrypter =
        enc.Encrypter(enc.AES(aesKey, mode: enc.AESMode.ctr, padding: null));
    final encrypted = encrypter.encryptBytes(payload, iv: iv);

    return Uint8List.fromList(header + encrypted.bytes);
  }

  void _publishMqttMessage(String topic, Map<String, dynamic> payload) {
    final builder = MqttClientPayloadBuilder();
    builder.addString(json.encode(payload));
    _mqttClient?.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
  }

  void cleanup() {
    _logger.i("Cleaning up communication service.");
    _mqttClient?.disconnect();
    _udpSocket?.close();
  }
}