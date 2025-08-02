class OtaConfig {
  final MqttConfig mqtt;
  // Add other fields from OTA response if needed

  OtaConfig({required this.mqtt});

  factory OtaConfig.fromJson(Map<String, dynamic> json) {
    return OtaConfig(mqtt: MqttConfig.fromJson(json['mqtt']));
  }
}

class MqttConfig {
  final String clientId;
  final String endpoint;
  final String password;
  final String username;

  MqttConfig({
    required this.clientId,
    required this.endpoint,
    required this.password,
    required this.username,
  });

  factory MqttConfig.fromJson(Map<String, dynamic> json) {
    return MqttConfig(
      clientId: json['client_id'],
      endpoint: json['endpoint'],
      password: json['password'],
      username: json['username'],
    );
  }
}

class UdpSessionDetails {
  final String sessionId;
  final UdpConfig udp;
  final AudioParams audioParams;

  UdpSessionDetails({
    required this.sessionId,
    required this.udp,
    required this.audioParams,
  });

  factory UdpSessionDetails.fromJson(Map<String, dynamic> json) {
    return UdpSessionDetails(
      sessionId: json['session_id'],
      udp: UdpConfig.fromJson(json['udp']),
      audioParams: AudioParams.fromJson(json['audio_params']),
    );
  }
}

class UdpConfig {
  final String key;
  final int port;

  UdpConfig({required this.key, required this.port});

  factory UdpConfig.fromJson(Map<String, dynamic> json) {
    return UdpConfig(key: json['key'], port: json['port']);
  }
}

class AudioParams {
  final int channels;
  final int frameDuration;
  final int sampleRate;

  AudioParams({
    required this.channels,
    required this.frameDuration,
    required this.sampleRate,
  });

  // --- ADD THIS copyWith METHOD ---
  AudioParams copyWith({int? channels, int? frameDuration, int? sampleRate}) {
    return AudioParams(
      channels: channels ?? this.channels,
      frameDuration: frameDuration ?? this.frameDuration,
      sampleRate: sampleRate ?? this.sampleRate,
    );
  }

  factory AudioParams.fromJson(Map<String, dynamic> json) {
    return AudioParams(
      channels: json['channels'],
      frameDuration: json['frame_duration'],
      sampleRate: json['sample_rate'],
    );
  }
}
