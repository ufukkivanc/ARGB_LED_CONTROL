import 'package:argb_controller/models/effect.dart';
import 'package:argb_controller/models/led_color.dart';

/// Connection status of a device.
enum ConnectionStatus {
  disconnected,
  connecting,
  connected,
  error,
}

/// Hardware configuration of an LED controller device.
class DeviceConfig {
  final int ledCount;
  final String ledType;
  final int gpioPin;
  final String colorOrder;
  final int maxBrightness;
  final String deviceName;
  final String firmwareVersion;

  const DeviceConfig({
    this.ledCount = 60,
    this.ledType = 'WS2812B',
    this.gpioPin = 2,
    this.colorOrder = 'GRB',
    this.maxBrightness = 255,
    this.deviceName = 'ESP32 LED Controller',
    this.firmwareVersion = '1.0.0',
  });

  DeviceConfig copyWith({
    int? ledCount,
    String? ledType,
    int? gpioPin,
    String? colorOrder,
    int? maxBrightness,
    String? deviceName,
    String? firmwareVersion,
  }) {
    return DeviceConfig(
      ledCount: ledCount ?? this.ledCount,
      ledType: ledType ?? this.ledType,
      gpioPin: gpioPin ?? this.gpioPin,
      colorOrder: colorOrder ?? this.colorOrder,
      maxBrightness: maxBrightness ?? this.maxBrightness,
      deviceName: deviceName ?? this.deviceName,
      firmwareVersion: firmwareVersion ?? this.firmwareVersion,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'ledCount': ledCount,
      'ledType': ledType,
      'gpioPin': gpioPin,
      'colorOrder': colorOrder,
      'maxBrightness': maxBrightness,
      'deviceName': deviceName,
      'firmwareVersion': firmwareVersion,
    };
  }

  factory DeviceConfig.fromJson(Map<String, dynamic> json) {
    return DeviceConfig(
      ledCount: (json['ledCount'] as num?)?.toInt() ?? 60,
      ledType: json['ledType'] as String? ?? 'WS2812B',
      gpioPin: (json['gpioPin'] as num?)?.toInt() ?? 2,
      colorOrder: json['colorOrder'] as String? ?? 'GRB',
      maxBrightness: (json['maxBrightness'] as num?)?.toInt() ?? 255,
      deviceName: json['deviceName'] as String? ?? 'ESP32 LED Controller',
      firmwareVersion: json['firmwareVersion'] as String? ?? '1.0.0',
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DeviceConfig &&
        other.ledCount == ledCount &&
        other.ledType == ledType &&
        other.gpioPin == gpioPin &&
        other.colorOrder == colorOrder &&
        other.maxBrightness == maxBrightness &&
        other.deviceName == deviceName &&
        other.firmwareVersion == firmwareVersion;
  }

  @override
  int get hashCode => Object.hash(
        ledCount,
        ledType,
        gpioPin,
        colorOrder,
        maxBrightness,
        deviceName,
        firmwareVersion,
      );

  @override
  String toString() =>
      'DeviceConfig($deviceName, $ledCount×$ledType, pin $gpioPin, fw $firmwareVersion)';
}

/// Represents a physical ESP32 LED controller device.
class Device {
  final String id;
  final String name;
  final String ipAddress;
  final ConnectionStatus connectionStatus;
  final bool isOn;
  final LedColor currentColor;
  final EffectType currentEffect;
  final int brightness;
  final int speed;
  final DeviceConfig config;

  const Device({
    required this.id,
    required this.name,
    this.ipAddress = '192.168.1.100',
    this.connectionStatus = ConnectionStatus.disconnected,
    this.isOn = false,
    this.currentColor = const LedColor(r: 255, g: 180, b: 107),
    this.currentEffect = EffectType.staticColor,
    this.brightness = 255,
    this.speed = 50,
    this.config = const DeviceConfig(),
  });

  Device copyWith({
    String? id,
    String? name,
    String? ipAddress,
    ConnectionStatus? connectionStatus,
    bool? isOn,
    LedColor? currentColor,
    EffectType? currentEffect,
    int? brightness,
    int? speed,
    DeviceConfig? config,
  }) {
    return Device(
      id: id ?? this.id,
      name: name ?? this.name,
      ipAddress: ipAddress ?? this.ipAddress,
      connectionStatus: connectionStatus ?? this.connectionStatus,
      isOn: isOn ?? this.isOn,
      currentColor: currentColor ?? this.currentColor,
      currentEffect: currentEffect ?? this.currentEffect,
      brightness: brightness ?? this.brightness,
      speed: speed ?? this.speed,
      config: config ?? this.config,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'ipAddress': ipAddress,
      'connectionStatus': connectionStatus.index,
      'isOn': isOn,
      'currentColor': currentColor.toJson(),
      'currentEffect': currentEffect.index,
      'brightness': brightness,
      'speed': speed,
      'config': config.toJson(),
    };
  }

  factory Device.fromJson(Map<String, dynamic> json) {
    return Device(
      id: json['id'] as String,
      name: json['name'] as String,
      ipAddress: json['ipAddress'] as String? ?? '192.168.1.100',
      connectionStatus: ConnectionStatus
          .values[(json['connectionStatus'] as num?)?.toInt() ?? 0],
      isOn: json['isOn'] as bool? ?? false,
      currentColor: json['currentColor'] != null
          ? LedColor.fromJson(json['currentColor'] as Map<String, dynamic>)
          : const LedColor(r: 255, g: 180, b: 107),
      currentEffect: EffectType
          .values[(json['currentEffect'] as num?)?.toInt() ?? 0],
      brightness: (json['brightness'] as num?)?.toInt() ?? 255,
      speed: (json['speed'] as num?)?.toInt() ?? 50,
      config: json['config'] != null
          ? DeviceConfig.fromJson(json['config'] as Map<String, dynamic>)
          : const DeviceConfig(),
    );
  }

  /// Whether the device is currently reachable.
  bool get isConnected => connectionStatus == ConnectionStatus.connected;

  /// Human-readable status string (Turkish).
  String get statusText {
    switch (connectionStatus) {
      case ConnectionStatus.disconnected:
        return 'Bağlı Değil';
      case ConnectionStatus.connecting:
        return 'Bağlanıyor…';
      case ConnectionStatus.connected:
        return 'Bağlı';
      case ConnectionStatus.error:
        return 'Bağlantı Hatası';
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Device && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'Device($name, $ipAddress, status: $connectionStatus, on: $isOn)';
}
