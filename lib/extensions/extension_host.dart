/// ExtensionHost — lazy activation orchestrator like VS Code.
///
/// VS Code NEVER loads an extension's code on startup: it scans
/// only the manifests (package.json) then wait for an event
/// activation. This file carries the same semantics for the extensions
/// .panda :
///
/// scanInstalled() → indexes manifests WITHOUT executing code
///   activateEager()        → `*` / onStartup / onStartupFinished
///   executeCommand(id)     → `onCommand:<id>`   (palette, keybinding, menus)
/// onFileOpened(lang) → `onLanguage:<id> ` (opening a file)
///   onViewShown(viewId)    → `onView:<id>`      (vue sidebar/panel visible)
///   onWorkspaceOpened(dir) → `workspaceContains:<pattern>`
///   handleUri(uri)         → `panda://<extId>/<command>` (lien externe)
library;
import 'dart:io';
import 'package:path/path.dart' as p;
import 'models/panda_manifest.dart';
import 'native_extension_loader.dart';
import 'remote_registry.dart';





class ExtensionHost {
  ExtensionHost._();
  static final ExtensionHost instance = ExtensionHost._();

  /// id → path to the installed folder.
  final Map<String, String> _installPaths = {};

  /// id → manifest parsed (lightweight: no extension code executed).
  final Map<String, PandaManifest> _manifests = {};

  bool _scanned = false;

  List<PandaManifest> get knownManifests =>
      _manifests.values.toList(growable: false);

  PandaManifest? manifestOf(String id) => _manifests[id];

  /// Is the extension loaded AND activated?
  bool isActive(String id) {
    for (final ext in NativeExtensionLoader.instance.loaded) {
      if (ext.id == id) return ext.isActivated;
    }
    return false;
  }

  // ── Scanning manifests (equivalent to scanning package.json in VS Code) ─────

  /// Indexes all installed manifests. Fast (reads YAML files),
  /// No isolate launched, no activation.
  Future<void> scanInstalled() async {
    final root = Directory(RemoteExtensionRegistry.instance.installRoot);
    if (!await root.exists()) {
      _scanned = true;
      return;
    }
    await for (final e in root.list()) {
      if (e is! Directory) continue;
      final mf = File(p.join(e.path, 'panda.yaml'));
      if (!await mf.exists()) continue;
      try {
        final m = await PandaManifest.fromFile(mf.path);
        _installPaths[m.id] = e.path;
        _manifests[m.id] = m;
      } catch (_) {
        // manifest broken: ignored, never blocking for others
      }
    }
    _scanned = true;
  }

  Future<void> _ensureScanned() async {
    if (!_scanned) await scanInstalled();
  }

  /// To be called after uninstallation to purge the index.
  void forgetInstalled(String id) {
    _installPaths.remove(id);
    _manifests.remove(id);
  }

  /// Charges + activates an extension if it is not already done.
  Future<void> ensureActivated(String id) async {
    await _ensureScanned();
    if (isActive(id)) return;
    var dir = _installPaths[id];
    dir ??= p.join(RemoteExtensionRegistry.instance.installRoot, id);
    final ext = await NativeExtensionLoader.instance.load(dir);
    if (!ext.isActivated) {
      await NativeExtensionLoader.instance.activate(ext);
    }
  }

  // ── Activation Events ─────────────────────────────────────────────

  /// Enables all extensions declared on `*` / onStartup /
  /// onStartupFinished. To be called once the IDE has started.
  Future<void> activateEagerExtensions() async {
    await _ensureScanned();
    for (final m in _manifests.values) {
      if (m.activation.wantsStartup && !isActive(m.id)) {
        try {
          await ensureActivated(m.id);
        } catch (_) {
          // A broken extension never prevents the others from starting
        }
      }
    }
  }

  /// `onCommand:<id> ` — called by the command palette, the keybindings,
  /// Context menus, status bar items… This is THE entry point
  /// universal VS Code extensions.
  ///
  /// Returns the result sent by the extension (null if it does not return
  /// nothing), or throw if the command is unknown / not activatable.
  Future<dynamic> executeCommand(String commandId) async {
    await _ensureScanned();

    // 1. Find the extension that declares this command (without loading it).
    PandaManifest? owner;
    for (final m in _manifests.values) {
      if (m.contributes.commands.any((c) => c.id == commandId)) {
        owner = m;
        break;
      }
    }
    if (owner == null) {
      throw StateError('Unknown command: $commandId');
    }

    // 2. Lazy activation: only if onCommand:<id> matches,
    // or if the extension is eager/startup. Never otherwise.
    final evts = owner.activation.events;
    final lazilyActivatable =
        evts.contains('onCommand:$commandId') || owner.activation.wantsStartup;
    if (!isActive(owner.id)) {
      if (!lazilyActivatable && evts.isNotEmpty && !owner.activation.eager) {
        throw StateError(
            '${owner.id} is not activated via onCommand:$commandId'
            '(events: $evts)');
      }
      await ensureActivated(owner.id);
      await _notify(owner.id, {'reason': 'onCommand:$commandId'});
    }

    // 3. Delegate to the activated extension.
    for (final ext in NativeExtensionLoader.instance.loaded) {
      if (ext.id == owner.id) {
        return ext.request<dynamic>('command', {'command': commandId});
      }
    }
    throw StateError('${owner.id} not found after activation');
  }

  /// `onLanguage:<id> ` — to be called each time a file is opened/created.
  /// [languageId] : language identifier ('dart', 'python', 'markdown'…).
  Future<void> onFileOpened(String languageId) async {
    await _ensureScanned();
    for (final m in _manifests.values) {
      if (!isActive(m.id) &&
          m.activation.events.contains('onLanguage:$languageId')) {
        try {
          await ensureActivated(m.id);
          await _notify(m.id, {'reason': 'onLanguage:$languageId'});
        } catch (_) {}
      }
    }
  }

  /// `onView:<id> ` — to be called when a sidebar/panel view becomes visible.
  Future<void> onViewShown(String viewId) async {
    await _ensureScanned();
    for (final m in _manifests.values) {
      if (!isActive(m.id) &&
          (m.activation.events.contains('onView:$viewId') ||
              m.activation.matchesView(viewId))) {
        try {
          await ensureActivated(m.id);
          await _notify(m.id, {'reason': 'onView:$viewId'});
        } catch (_) {}
      }
    }
  }

  /// `workspaceContains:<pattern> ` — to be called when opening a file.
  /// Simple pattern: filename suffix ('**/*.x' → '.x',
  /// exact name otherwise).
  Future<void> onWorkspaceOpened(String rootPath) async {
    await _ensureScanned();
    for (final m in _manifests.values) {
      for (final evt in m.activation.events) {
        if (!evt.startsWith('workspaceContains:')) continue;
        final pattern =
            evt.substring('workspaceContains:'.length).trim();
        if (await _workspaceMatches(rootPath, pattern)) {
          try {
            await ensureActivated(m.id);
            await _notify(m.id, {'reason': evt});
          } catch (_) {}
          break;
        }
      }
    }
  }

  Future<bool> _workspaceMatches(String rootPath, String pattern) async {
    try {
      var suffix = pattern;
      if (suffix.startsWith('**/')) suffix = suffix.substring(3);
      if (suffix.startsWith('*.')) suffix = suffix.substring(1);
      final dir = Directory(rootPath);
      if (!await dir.exists()) return false;
      await for (final e in dir.list(recursive: true).take(200)) {
        if (e.path.endsWith(suffix)) return true;
      }
    } catch (_) {}
    return false;
  }

  // ── URI handler ────────────────────────────────────────────────────────

  /// `panda://<commandId> ` or `panda://<extId> /<command> ?a=b` — allows you to
  /// launch an extension command from outside (browser,
  /// notification, other app), like the vscode:// handler of VS Code.
  ///
  /// Returns true if the URI has been consumed.
  Future<bool> handleUri(Uri uri) async {
    if (uri.scheme != 'panda') return false;
    await _ensureScanned();
    var commandId = uri.host;
    final sub = uri.path.replaceFirst('/', '').trim();
    if (sub.isNotEmpty && !commandId.contains('.')) {
      commandId = '$commandId.$sub';
    } else if (sub.isNotEmpty) {
      commandId = sub;
    }
    try {
      await executeCommand(commandId);
      return true;
    } catch (_) {
      return false;
    }
  }

  // ── Interne ────────────────────────────────────────────────────────────

  Future<void> _notify(String id, Map<String, dynamic> ctx) async {
    for (final ext in NativeExtensionLoader.instance.loaded) {
      if (ext.id == id && ext.isActivated) {
        ext.send('event', {'event': 'activate', 'data': ctx});
      }
    }
  }
}
