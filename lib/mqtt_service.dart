import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

typedef MqttMessageCallback = void Function(String message);

class MqttService {
  late MqttServerClient _client;
  // Updated from client.py
  final String _broker = "139.59.7.72";
  final int _port = 1883; // Default MQTT port
  final String _clientId;
  bool _isConnected = false;

  final StreamController<Map<String, dynamic>> _messageStreamController =
      StreamController.broadcast();
  Stream<Map<String, dynamic>> get messages => _messageStreamController.stream;

  MqttService({required String clientId}) : _clientId = clientId {
    _client = MqttServerClient.withPort(_broker, _clientId, _port);
    _client.logging(on: false);
    _client.onConnected = _onConnected;
    _client.onDisconnected = _onDisconnected;
    _client.onSubscribed = _onSubscribed;
    _client.pongCallback = _pong;
  }

  Future<bool> connect() async {
    if (_isConnected) {
      log('MQTT Service: Already connected.');
      return true;
    }
    log('MQTT Service: Connecting...');
    try {
      // In a real app, you would get these from your OTA config like in the python script.
      // await _client.connect('user', 'password');
      await _client.connect();
      _isConnected =
          _client.connectionStatus!.state == MqttConnectionState.connected;

      if (_isConnected) {
        final p2pTopic = "devices/p2p/$_clientId";
        _client.subscribe(p2pTopic, MqttQos.atLeastOnce);

        _client.updates?.listen((List<MqttReceivedMessage<MqttMessage>> c) {
          final MqttPublishMessage recMess = c[0].payload as MqttPublishMessage;
          final String payload = MqttPublishPayload.bytesToStringAsString(
            recMess.payload.message,
          );

          // log(
          //   'MQTT Service: Received message: $payload from topic: ${c[0].topic}',
          // );
          try {
            _messageStreamController.add(json.decode(payload));
          } catch (e) {
            log('MQTT Service: Error decoding JSON: $e');
          }
        });
      }
      return _isConnected;
    } catch (e) {
      log('MQTT Service: Exception during connect: $e');
      _client.disconnect();
      _isConnected = false;
      return false;
    }
  }

  void disconnect() {
    log('MQTT Service: Disconnecting...');
    _client.disconnect();
    _isConnected = false;
  }

  void publish(String topic, String message, {bool retain = false}) {
    if (_isConnected) {
      final builder = MqttClientPayloadBuilder();
      builder.addString(message);
      _client.publishMessage(
        topic,
        MqttQos.atLeastOnce,
        builder.payload!,
        retain: retain,
      );
    } else {
      log('MQTT Service: Cannot publish, client not connected.');
    }
  }

  void _onConnected() {
    log('MQTT Service: Connected');
    _isConnected = true;
  }

  void _onDisconnected() {
    log('MQTT Service: Disconnected');
    _isConnected = false;
  }

  void _onSubscribed(String topic) {
    log('MQTT Service: Subscribed to topic: $topic');
  }

  void _pong() {
    log('MQTT Service: Ping response received');
  }

  void dispose() {
    _messageStreamController.close();
    disconnect();
  }
}
