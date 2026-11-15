import 'package:app_settings/app_settings.dart';
import 'package:flutter/foundation.dart';

/// Sistem Wi-Fi ayarlarını açma desteği var mı? (Web'de yok.)
bool get canOpenWifiSettings => !kIsWeb;

/// Android/iOS'ta sistem Wi-Fi ayarlarına yönlendirir.
///
/// Not: Kurulum ağına OTOMATİK bağlanma (Android WifiNetworkSpecifier / iOS
/// NEHotspotConfiguration) bu sürümde YOK; kullanıcı ağı sistem ayarlarından seçer.
Future<void> openWifiSettings() async {
  if (!canOpenWifiSettings) return;
  try {
    await AppSettings.openAppSettings(type: AppSettingsType.wifi);
  } catch (_) {}
}
