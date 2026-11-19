/// Panda IDE extension permissions system.
///
/// Deux familles :
///   1. IDE SANDBOX permissions (terminal, network, storage…) — granted
/// after consent to the installation, persisted locally.
///   2. PHONE permissions (clipboard, camera, microphone, location…) —
/// trigger the true Android runtime permission via platform channel,
/// with a rationale dialog before it (Google Play pattern).
///
/// All requests go through [ExtensionPermissionManager]:
/// Extensions NEVER get direct access to sensitive APIs.
library;
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';




// ═══════════════════════════════════════════════════════════════
// MODEL
// ═══════════════════════════════════════════════════════════════

enum PermissionScope { ideSandbox, phone }

enum PandaPermission {
  // Sandbox IDE
  terminal(PermissionScope.ideSandbox, 'Terminal',
      'Execute commands in the built-in terminal'),
  network(PermissionScope.ideSandbox, 'Network',
      'Perform network requests'),
  storage(PermissionScope.ideSandbox, 'Stockage IDE',
      'Read/write in the working folder'),
  notifications(PermissionScope.ideSandbox, 'Notifications',
      'Display notifications in the IDE'),

  // Phone (Android runtime)
  clipboard(PermissionScope.phone, 'Presse-papiers',
      'Read and write to the phone\'s clipboard',
      androidPermission: 'android.permission.READ_CLIPBOARD'),
  camera(PermissionScope.phone, 'Camera',
      'Use the phone\'s camera',
      androidPermission: 'android.permission.CAMERA'),
  microphone(PermissionScope.phone, 'Microphone',
      'Record microphone audio',
      androidPermission: 'android.permission.RECORD_AUDIO'),
  location(PermissionScope.phone, 'Localisation',
      'Access the device\'s location',
      androidPermission: 'android.permission.ACCESS_FINE_LOCATION'),
  contacts(PermissionScope.phone, 'Contacts',
      'Read phone contacts',
      androidPermission: 'android.permission.READ_CONTACTS'),
  bluetooth(PermissionScope.phone, 'Bluetooth',
      'Connect to Bluetooth devices',
      androidPermission: 'android.permission.BLUETOOTH_CONNECT'),
  phoneState(PermissionScope.phone, 'Phone State',
      'Read device information',
      androidPermission: 'android.permission.READ_PHONE_STATE');

  const PandaPermission(this.scope, this.label, this.rationale,
      {this.androidPermission});

  final PermissionScope scope;
  final String label;
  final String rationale;
  final String? androidPermission;

  static PandaPermission? tryParse(String name) => PandaPermission.values
      .where((p) => p.name == name.trim())
      .firstOrNull;
}

/// Result of a permission request.
enum PermissionResult { granted, denied, permanentlyDenied, unknown }

// ═══════════════════════════════════════════════════════════════
// MANAGER
// ═══════════════════════════════════════════════════════════════

/// Central extension permissions manager.
///
/// Extension-side usage (via panda_sdk):
/// ```dart
/// final ok = await context.permissions.request('clipboard');
/// if (ok) { final text = await context.clipboard.read(); }
/// ```
class ExtensionPermissionManager {
  ExtensionPermissionManager._();
  static final ExtensionPermissionManager instance =
      ExtensionPermissionManager._();

  static const _channel = MethodChannel('panda.ide.permissions');

  /// Agreement persistence file (injected by the app).
  String grantsFilePath = '.panda/extension_grants.json';

  final Map<String, Set<String>> _grants = {};
  bool _loaded = false;

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = File(grantsFilePath);
      if (await f.exists()) {
        final doc = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        doc.forEach((ext, perms) {
          _grants[ext] = (perms as List).map((e) => e.toString()).toSet();
        });
      }
    } catch (_) {
      // corrupted file → starts empty
    }
  }

  Future<void> _persist() async {
    try {
      final f = File(grantsFilePath);
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(
          _grants.map((k, v) => MapEntry(k, v.toList()))));
    } catch (_) {}
  }

  // ── Consultation ─────────────────────────────────────────────────

  Future<bool> isGranted(String extensionId, PandaPermission perm) async {
    await _ensureLoaded();
    return _grants[extensionId]?.contains(perm.name) ?? false;
  }

  /// All permissions granted to an extension.
  Future<List<PandaPermission>> grantedFor(String extensionId) async {
    await _ensureLoaded();
    final names = _grants[extensionId] ?? const {};
    return PandaPermission.values.where((p) => names.contains(p.name)).toList();
  }

  // ── Demandes ─────────────────────────────────────────────────────

  /// Grants a sandbox permission (install consent).
  Future<void> grantIde(String extensionId, PandaPermission perm) async {
    assert(perm.scope == PermissionScope.ideSandbox);
    await _ensureLoaded();
    (_grants[extensionId] ??= {}).add(perm.name);
    await _persist();
  }

  /// Revokes everything (uninstalls the extension).
  Future<void> revokeAll(String extensionId) async {
    await _ensureLoaded();
    _grants.remove(extensionId);
    await _persist();
  }

  /// Requests phone permission (Android runtime).
  ///
  /// [showRationale] must display the explanation dialog and return
  /// true if the user agrees to continue. Returns true if granted.
  Future<PermissionResult> request(
    String extensionId,
    PandaPermission perm, {
    required Future<bool> Function(PandaPermission perm) showRationale,
  }) async {
    await _ensureLoaded();

    // Already granted on the IDE side?
    if (await isGranted(extensionId, perm)) return PermissionResult.granted;

    if (perm.scope == PermissionScope.ideSandbox) {
      // Sandbox permissions only require user consent
      final ok = await showRationale(perm);
      if (!ok) return PermissionResult.denied;
      await grantIde(extensionId, perm);
      return PermissionResult.granted;
    }

    // Phone permission → rationale then native channel
    if (perm.androidPermission == null) return PermissionResult.unknown;

    final wantsIt = await showRationale(perm);
    if (!wantsIt) return PermissionResult.denied;

    bool nativeGranted;
    try {
      nativeGranted = await _channel.invokeMethod<bool>('requestPermission', {
            'permission': perm.androidPermission,
            'extensionId': extensionId,
          }) ??
          false;
    } on MissingPluginException {
      // Native side not yet built → safe refusal
      nativeGranted = false;
    } on PlatformException {
      nativeGranted = false;
    }

    if (nativeGranted) {
      (_grants[extensionId] ??= {}).add(perm.name);
      await _persist();
      return PermissionResult.granted;
    }
    return PermissionResult.denied;
  }
}

// ═══════════════════════════════════════════════════════════════
// GUARDED APIs (accessible only after permission)
// ═══════════════════════════════════════════════════════════════

/// Clipboard for extensions — requires `clipboard` permission.
class ExtensionClipboard {
  ExtensionClipboard._();

  static Future<bool> _check(String extensionId) async =>
      ExtensionPermissionManager.instance
          .isGranted(extensionId, PandaPermission.clipboard);

  static Future<String?> read(String extensionId) async {
    if (!await _check(extensionId)) return null; // silent: not granted
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return data?.text;
  }

  static Future<bool> write(String extensionId, String text) async {
    if (!await _check(extensionId)) return false;
    await Clipboard.setData(ClipboardData(text: text));
    return true;
  }
}

/// Redirects / intents for extensions — requires `network` or nothing
/// (opening URLs is safe; opening system settings
/// requests consent via rationale).
class ExtensionIntents {
  ExtensionIntents._();

  /// Opens an external URL (browser).
  static Future<bool> openUrl(String url) async {
    try {
      await _intentsChannel
          .invokeMethod('openUrl', {'url': url});
      return true;
    } on Exception {
      return false;
    }
  }

  /// Opens an Android settings screen (e.g., developer options).
  /// [action] : nom d'action Android complet.
  static Future<bool> openAndroidSettings(String action) async {
    try {
      await _intentsChannel
          .invokeMethod('openSettings', {'action': action});
      return true;
    } on Exception {
      return false;
    }
  }

  static const _intentsChannel = MethodChannel('panda.ide.intents');
}
