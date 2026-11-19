/// Node.js Extension Host Process Manager.
///
/// A Node.js process is spawned per active extension.
/// Each process loads host.js with the extension path as an argument.
/// Communication goes through IpcBridge (stdin/stdout JSON-RPC).
library;
import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'extension_registry.dart';
import 'ipc_bridge.dart';
import 'command_registry.dart';
import 'models/extension_manifest.dart';
import 'models/extension_message.dart';
import 'terminal_node.dart';





/// An active Extension Host (1 Node.js process = 1 extension).
class ActiveExtensionHost {
  final InstalledExtension extension;
  final IpcBridge bridge;
  bool _activated = false;

  ActiveExtensionHost({required this.extension, required this.bridge});

  bool get isActivated => _activated;

  ExtensionManifest get manifest => extension.manifest;
  String get id => manifest.id;

  Future<void> markActivated() async => _activated = true;

  Future<void> dispose() async {
    await bridge.dispose();
  }
}

/// Manages the lifecycle of all Extension Hosts.
class ExtensionHostManager {
  static final ExtensionHostManager instance = ExtensionHostManager._();
  ExtensionHostManager._();

  final Map<String, ActiveExtensionHost> _hosts = {};

  /// Path to host.js (extracted from assets/ on first launch).
  String? _hostJsPath;

  /// Handler for all vscode.* calls coming from extensions.
  /// Must be defined by the UI before enabling extensions.
  Future<dynamic> Function(String extensionId, IpcMessage msg)? apiCallHandler;

  /// Loader installed by ExtensionHostSetup. Android initialization is
  /// intentionally deferred, but a user action may occur before
  /// the end of this initialization.
  Future<void> Function()? _configurationLoader;
  String? _configurationError;

  // ── Initialisation ───────────────────────────────────────────────────────

  /// To be called from main.dart after validating the terminal node.
  void configure({required String hostJsPath}) {
    _hostJsPath = hostJsPath;
    _configurationError = null;
  }

  bool get isConfigured => _hostJsPath != null;

  void setConfigurationLoader(Future<void> Function() loader) {
    _configurationLoader = loader;
  }

  Future<void> _ensureConfigured() async {
    if (isConfigured) return;
    final loader = _configurationLoader;
    if (loader != null) {
      await loader();
    }
    if (!isConfigured) {
      throw StateError(
        'Host extension unavailable: Node.js or host.js is missing.'
        '${_configurationError ?? "Run \"panda update\" and then try again."}',
      );
    }
  }

  // ── Activation d'extension ───────────────────────────────────────────────

  /// Activates an extension: spawns the Node.js process and sends "activate".
  Future<void> activate(InstalledExtension ext) async {
    await _ensureConfigured();

    final id = ext.manifest.id;
    final existing = _hosts[id];
    if (existing != null) {
      if (!existing.bridge.isClosed) return; // already active
      // A crashed Node process must not permanently block lazy reactivation.
      _hosts.remove(id);
    }

    if (!ext.isRunnable) {
      throw StateError(
          'Extension $id is not runnable (disabled, no entry point, or requires native binaries).');
    }

    // Determine the entry point
    final entryPoint = _resolveEntryPoint(ext);
    if (entryPoint == null) {
      throw StateError('Cannot resolve entry point for $id');
    }

    // Android's terminal Node binary is a Linux guest executable. It must be
    // started through the same PRoot wrapper as the terminal, never with a
    // direct Process.start() from the Android host.
    final process = await TerminalNodeLauncher.instance.startNode(
      arguments: [_hostJsPath!, entryPoint],
      environment: {
        'PANDA_EXT_ID': id,
        'PANDA_EXT_PATH': ext.installPath,
        'PANDA_EXT_VERSION': ext.manifest.version,
        'HOME': ext.installPath,
        // Disables ANSI colors in Node.js logs
        'NO_COLOR': '1',
        'FORCE_COLOR': '0',
      },
      workingDirectory: ext.installPath,
    );

    // Attach the IPC bridge
    final bridge = await IpcBridge.attach(process, (msg) async {
      final handler = apiCallHandler;
      if (handler == null) {
        throw StateError('No apiCallHandler registered');
      }
      return handler(id, msg);
    });

    final host = ActiveExtensionHost(extension: ext, bridge: bridge);
    _hosts[id] = host;

    // Send "activate" with the extension context
    try {
      await bridge.call('activate', [_buildActivationContext(ext)]);
      await host.markActivated();

      // Auto-register contributed commands into CommandPalette
      final contributes = ext.manifest.contributes;
      if (contributes.commands.isNotEmpty) {
        for (final cmd in contributes.commands) {
          final commandId = cmd['command'] as String?;
          if (commandId != null) {
            CommandRegistry.instance.register(
              command: commandId,
              extensionId: id,
              title: cmd['title'] as String?,
              category: cmd['category'] as String?,
              description: cmd['description'] as String?,
            );
          }
        }
        // ignore: avoid_print
        print('[ExtHostManager] Registered ${contributes.commands.length} commands for $id');
      }
    } catch (e) {
      await host.dispose();
      _hosts.remove(id);
      await ExtensionRegistry.instance.setError(id, e.toString());
      rethrow;
    }
  }

  /// Disables an extension: sends "deactivate" then closes the process.
  Future<void> deactivate(String extensionId) async {
    final host = _hosts[extensionId];
    if (host == null) return;

    try {
      if (host.isActivated) {
        await host.bridge.call('deactivate').timeout(const Duration(seconds: 5));
      }
    } catch (_) {
      // We'll still close it even if the plant is deactivated
    }

    await host.dispose();
    _hosts.remove(extensionId);
  }

  /// Enables all extensions marked as "startup".
  Future<void> activateStartupExtensions() async {
    await ExtensionRegistry.instance.load();
    final startups = ExtensionRegistry.instance.startupExtensions;
    await Future.wait(startups.map((e) => _safeActivate(e)));
  }

  /// Activates extensions for a given language (lazy activation).
  Future<void> activateForLanguage(String languageId) async {
    await ExtensionRegistry.instance.load();
    final exts = ExtensionRegistry.instance.forLanguage(languageId);
    await Future.wait(exts.map((e) => _safeActivate(e)));
  }

  /// Enables extensions for a given command.
  Future<void> activateForCommand(String commandId) async {
    await ExtensionRegistry.instance.load();
    final exts = ExtensionRegistry.instance.forCommand(commandId);
    await Future.wait(exts.map((e) => _safeActivate(e)));
  }

  /// Activate installed extensions which contribute [viewId].
  Future<void> activateForView(String viewId) async {
    await ExtensionRegistry.instance.load();
    final exts = ExtensionRegistry.instance.all.where((ext) {
      final views = ext.manifest.contributes.views;
      final containers = ext.manifest.contributes.viewsContainers;
      return views.any((view) => view['id']?.toString() == viewId) ||
          containers.any((container) => container['id']?.toString() == viewId);
    });
    // A view click must report activation errors to the UI. Swallowing the
    // error made a broken provider look like a successful sidebar action.
    await Future.wait(exts.map(activate));
  }

  // ── Sending events to all active extensions ───────────────────────

  /// Notifies all extensions of an editor event.
  void broadcastEvent(String event, [dynamic data]) {
    for (final host in _hosts.values) {
      if (host.isActivated) {
        host.bridge.fireEvent(event, data);
      }
    }
  }

  /// Notifies a specific extension of an event.
  void sendEvent(String extensionId, String event, [dynamic data]) {
    _hosts[extensionId]?.bridge.fireEvent(event, data);
  }

  // ── Introspection ────────────────────────────────────────────────────────

  List<ActiveExtensionHost> get activeHosts => _hosts.values.toList();
  bool isActive(String extensionId) =>
      _hosts[extensionId]?.bridge.isClosed == false;
  ActiveExtensionHost? getHost(String extensionId) => _hosts[extensionId];

  /// Returns the IpcBridge of an active extension — used by LanguageFeatureRouter.
  IpcBridge? getBridge(String extensionId) {
    final bridge = _hosts[extensionId]?.bridge;
    return bridge != null && !bridge.isClosed ? bridge : null;
  }

  // ── Dispose ──────────────────────────────────────────────────────────────

  Future<void> disposeAll() async {
    final futures = _hosts.keys.map(deactivate).toList();
    await Future.wait(futures);
    _hosts.clear();
  }

  // ── Private Helpers ───────────────────────────────────────────────────────────────

  Future<void> _safeActivate(InstalledExtension ext) async {
    try {
      await activate(ext);
    } catch (e) {
      // We log but we don't interrupt the activation of the others
      // ignore: avoid_print
      print('[ExtHostManager] Failed to activate ${ext.manifest.id}: $e');
    }
  }

  /// Resolves the absolute path of the entry point of the extension.
  String? _resolveEntryPoint(InstalledExtension ext) {
    final base = ext.installPath;
    final main = ext.manifest.main ?? ext.manifest.browser;
    if (main == null) return null;

    // Normalizes the path (may start with "./")
    final cleaned = main.replaceFirst(RegExp(r'^\.\/'), '');
    // Adds .js if no extension
    final withExt = p.extension(cleaned).isEmpty ? '$cleaned.js' : cleaned;
    final full = p.join(base, withExt);

    return File(full).existsSync() ? full : null;
  }

  /// Constructs the context object passed to activate(context).
  Map<String, dynamic> _buildActivationContext(InstalledExtension ext) {
    return {
      'extensionPath': ext.installPath,
      'extensionUri': 'file://${ext.installPath}',
      'globalStoragePath':
          p.join(ext.installPath, '..', '.storage', ext.manifest.id),
      'storagePath': p.join(ext.installPath, '..', '.storage', ext.manifest.id),
      'logPath': p.join(ext.installPath, '..', '.logs', ext.manifest.id),
      'workspaceState': <String, dynamic>{},
      'globalState': <String, dynamic>{},
      'subscriptions': <dynamic>[],
      'extension': {
        'id': ext.manifest.id,
        'extensionPath': ext.installPath,
        'isActive': true,
        'packageJSON': ext.manifest.raw,
      },
    };
  }
}
