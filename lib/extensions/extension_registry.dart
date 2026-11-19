/// Registry of installed extensions.
/// Persists via SharedPreferences, manages the enable/disable state.
library;
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'models/extension_manifest.dart';





enum ExtensionState { enabled, disabled, installing, error }

class InstalledExtension {
  final ExtensionManifest manifest;
  final String installPath; // absolute path to the folder extracted from the .vsix
  ExtensionState state;
  String? errorMessage;

  InstalledExtension({
    required this.manifest,
    required this.installPath,
    this.state = ExtensionState.enabled,
    this.errorMessage,
  });

  bool get isEnabled => state == ExtensionState.enabled;
  bool get isRunnable =>
      isEnabled && manifest.hasRunnableEntryPoint && !manifest.requiresNativeBinaries;

  Map<String, dynamic> toJson() => {
    'manifest': manifest.toJson(),
    'installPath': installPath,
    'state': state.name,
    if (errorMessage != null) 'errorMessage': errorMessage,
  };

  factory InstalledExtension.fromJson(Map<String, dynamic> json) {
    final stateStr = json['state'] as String? ?? 'enabled';
    return InstalledExtension(
      manifest: ExtensionManifest.fromJson(
          json['manifest'] as Map<String, dynamic>),
      installPath: json['installPath'] as String,
      state: ExtensionState.values.firstWhere(
        (e) => e.name == stateStr,
        orElse: () => ExtensionState.enabled,
      ),
      errorMessage: json['errorMessage'] as String?,
    );
  }
}

/// Singleton which manages the catalog of installed extensions.
class ExtensionRegistry {
  static const _prefsKey = 'panda_extensions_registry';
  static final ExtensionRegistry instance = ExtensionRegistry._();
  ExtensionRegistry._();

  final Map<String, InstalledExtension> _extensions = {};
  bool _loaded = false;

  // ── Lecture ──────────────────────────────────────────────────────────────

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null) {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      for (final item in list) {
        try {
          final ext = InstalledExtension.fromJson(item);
          // Check that the installation folder still exists
          if (Directory(ext.installPath).existsSync()) {
            _extensions[ext.manifest.id] = ext;
          }
        } catch (e) {
          // Extension corrompue → on ignore silencieusement
        }
      }
    }
    _loaded = true;
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _extensions.values.map((e) => e.toJson()).toList();
    await prefs.setString(_prefsKey, jsonEncode(list));
  }

  // ── Access ───────────────────────────────────────────────────────────────

  List<InstalledExtension> get all {
    _assertLoaded();
    return _extensions.values.toList();
  }

  List<InstalledExtension> get enabled {
    _assertLoaded();
    return _extensions.values.where((e) => e.isEnabled).toList();
  }

  List<InstalledExtension> get runnable {
    _assertLoaded();
    return _extensions.values.where((e) => e.isRunnable).toList();
  }

  InstalledExtension? get(String id) => _extensions[id];

  bool isInstalled(String id) => _extensions.containsKey(id);

  /// Returns the ids of all installed extensions.
  List<String> allInstalled() => _extensions.keys.toList();

  // ── Mutations ────────────────────────────────────────────────────────────

  Future<void> register(InstalledExtension ext) async {
    _extensions[ext.manifest.id] = ext;
    await _save();
  }

  Future<void> setEnabled(String id, {required bool enabled}) async {
    final ext = _extensions[id];
    if (ext == null) return;
    ext.state = enabled ? ExtensionState.enabled : ExtensionState.disabled;
    await _save();
  }

  Future<void> setError(String id, String message) async {
    final ext = _extensions[id];
    if (ext == null) return;
    ext.state = ExtensionState.error;
    ext.errorMessage = message;
    await _save();
  }

  Future<void> unregister(String id) async {
    _extensions.remove(id);
    await _save();
  }

  // ── Utility Queries ─────────────────────────────────────────────────────

  /// Extensions to activate for a given language.
  List<InstalledExtension> forLanguage(String languageId) {
    return runnable
        .where((e) =>
            e.manifest.activationEvents.activatesForLanguage(languageId))
        .toList();
  }

  /// Extensions to activate for a given command.
  List<InstalledExtension> forCommand(String commandId) {
    return runnable
        .where((e) =>
            e.manifest.activationEvents.activatesForCommand(commandId))
        .toList();
  }

  /// Extensions that activate at startup.
  List<InstalledExtension> get startupExtensions =>
      runnable.where((e) => e.manifest.activationEvents.activatesOnStartup).toList();

  // ── Helpers ──────────────────────────────────────────────────────────────

  void _assertLoaded() {
    assert(_loaded, 'ExtensionRegistry.load() must be called before accessing extensions.');
  }

  /// Root path for all installed extensions.
  static Future<String> extensionsRoot() async {
    // We use the Android app's data folder
    // getApplicationDocumentsDirectory() is not imported here to stay
    // without path_provider dependency — the path has been passed from main.dart.
    throw UnimplementedError(
        'Call ExtensionRegistry.setRoot() from main.dart with getApplicationDocumentsDirectory()');
  }

  static String? _root;
  static void setRoot(String path) => _root = path;

  /// Installation path for a given extension.
  /// Falls back to the system temp directory if setRoot() was never called
  /// (avoids a null-check crash on first install).
  static String installPathFor(String extensionId, String version) {
    final root = _root ?? Directory.systemTemp.path;
    return p.join(root, 'panda_extensions', '$extensionId-$version');
  }
}
