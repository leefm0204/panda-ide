/// WirelessPairingService — Dart bridge ↔ Kotlin for wireless pairing
/// automatic debugging, Shizuku style.
///
/// Flux :
/// 1. Verify that the NotificationListenerService is active
/// 2. Open Developer Options → Wireless Debugging
/// 3. The user presses "Associate with a code"
/// 4. The Kotlin listener detects the notification → stores port + code
/// 5. Dart poll or callback retrieves the data → automatic adb pair
///
/// Required permissions (managed by the panel):
/// - POST_NOTIFICATIONS (Android 13+) — for guide notification
/// - Notification Listener — to read system notifications
/// - Ignore battery optimization — so that the service survives
library;
import 'dart:async';
import 'package:flutter/services.dart';




class WirelessPairingService {
  WirelessPairingService._();
  static final WirelessPairingService instance = WirelessPairingService._();

  static const _channel = MethodChannel('panda.ide/pairing');

  PairingData? _latest;
  PairingData? get latest => _latest;

  Stream<PairingData> get onDetected => _detectedController.stream;
  final _detectedController = StreamController<PairingData>.broadcast();

  Timer? _pollTimer;

  /// Checks if the NotificationListenerService is enabled in the settings.
  Future<bool> isNotificationListenerEnabled() async {
    try {
      final result = await _channel.invokeMethod<bool>('isNotificationListenerEnabled');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the NotificationListener settings page.
  Future<void> openNotificationListenerSettings() async {
    try {
      await _channel.invokeMethod('openNotificationListenerSettings');
    } catch (_) {}
  }

  /// Opens Developer options (USB/wireless debugging).
  Future<void> openDeveloperSettings() async {
    try {
      await _channel.invokeMethod('openDeveloperSettings');
    } catch (_) {}
  }

  /// Attempts to directly open the Wireless Debugging page (Android 11+).
  Future<void> openWirelessDebugging() async {
    try {
      await _channel.invokeMethod('openWirelessDebugging');
    } catch (_) {
      // Fallback: developer options
      await openDeveloperSettings();
    }
  }

  /// Requests battery optimization exemption for Panda IDE.
  Future<bool> requestIgnoreBatteryOptimization() async {
    try {
      final result = await _channel.invokeMethod<bool>('requestIgnoreBatteryOptimization');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Checks if battery optimization is already disabled.
  Future<bool> isIgnoringBatteryOptimization() async {
    try {
      final result = await _channel.invokeMethod<bool>('isIgnoringBatteryOptimization');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Retrieves the latest pairing data captured by the Kotlin listener.
  Future<PairingData?> getLatestPairingData() async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('getLatestPairingData');
      if (result == null) return null;
      final data = PairingData(
        ip: result['ip'] as String? ?? '127.0.0.1',
        port: result['port'] as String? ?? '',
        code: result['code'] as String? ?? '',
        timestamp: result['timestamp'] as int? ?? 0,
      );
      _latest = data;
      _detectedController.add(data);
      return data;
    } catch (_) {
      return null;
    }
  }

  /// Starts polling to automatically detect pairing.
  /// Calls [onDetected] when the Kotlin listener captures new data.
  void startPolling({Duration interval = const Duration(milliseconds: 800)}) {
    stopPolling();
    _pollTimer = Timer.periodic(interval, (_) async {
      final data = await getLatestPairingData();
      if (data != null && _isNewer(data)) {
        _latest = data;
        _detectedController.add(data);
      }
    });
  }

  /// Stop polling.
  void stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  bool _isNewer(PairingData data) {
    final prev = _latest;
    if (prev == null) return true;
    return data.timestamp > prev.timestamp;
  }

  void dispose() {
    stopPolling();
    _detectedController.close();
  }
}

class PairingData {
  final String ip;
  final String port;
  final String code;
  final int timestamp;

  const PairingData({
    required this.ip,
    required this.port,
    required this.code,
    required this.timestamp,
  });

  bool get isComplete => port.isNotEmpty && code.length == 6;
}
