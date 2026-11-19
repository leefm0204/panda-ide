/// Initializing the Extension Host system.
///
/// To be called from main() before runApp() (Android only).
/// Responsibilities:
/// 1. Extract the JS assets to the Android filesystem
///   2. Configure ExtensionHostManager (node + host.js paths)
/// 3. Connect TasksBridge.launchInTerminal to the Android shell
/// 4. Load all static contributions (themes, snippets, grammars, icons)
library;
import 'dart:io';
import 'package:flutter/services.dart';
import '../utils/constants.dart';
import 'contributes/grammar_loader.dart';
import 'contributes/icon_theme_loader.dart';
import 'contributes/snippet_loader.dart';
import 'contributes/theme_loader.dart';
import 'extension_host_manager.dart';
import 'terminal_node.dart';
import 'tasks_bridge.dart';





/// JS files to extract from assets/ to the Android filesystem.
const _kExtensionHostAssets = [
  'assets/extension_host/host.js',
  'assets/extension_host/ipc.js',
  'assets/extension_host/api/types.js',
  'assets/extension_host/api/vscode.js',
  'assets/extension_host/api/webview.js',
  'assets/extension_host/api/scm.js',
  'assets/extension_host/api/tasks.js',
  'assets/extension_host/api/debug.js',
];

class ExtensionHostSetup {
  ExtensionHostSetup._();
  static Future<void>? _initFuture;

  /// Path on the filesystem to the extracted extension_host directory.
  static String get hostDir => '$appDir/extension_host';

  /// Path to host.js on the filesystem.
  static String get hostJsPath => '$hostDir/host.js';

  // ── Main Entry Point ──────────────────────────────────────────────

  /// Initializes the Extension Host system.
  ///
  /// [sharedPath] : result of NativeChannel.getLibraryPath().
  /// Must be called from main() after WidgetsFlutterBinding.ensureInitialized(),
  /// only on Android (!kIsWeb).
  static Future<void> init({required String sharedPath}) {
    final current = _initFuture;
    if (current != null) return current;

    final future = _doInit(sharedPath: sharedPath);
    _initFuture = future;
    future.catchError((_) {
      // A missing terminal Node is recoverable after the user runs `panda update`.
      // Do not permanently cache a failed initialization attempt.
      if (identical(_initFuture, future)) _initFuture = null;
    });
    return future;
  }

  static Future<void> _doInit({required String sharedPath}) async {
    // An interface action may require activation before the
    // Delayed start of main() until completed. Reuse exactly the
    // Even Future avoids the misleading "not configured" message.
    ExtensionHostManager.instance.setConfigurationLoader(
      () => init(sharedPath: sharedPath),
    );

    // 1. Extract the JS files to the filesystem.
    await _extractAssets();

    // 2. Validate Node from the terminal environment.
    final nodeReady = await TerminalNodeLauncher.instance.init();
    if (!nodeReady) {
      throw StateError(
        'Node.js unavailable in the terminal.'
        'Run "panda update" and then try again.',
      );
    }

    // 3. Configure the manager with host.js. Node remains provided by the terminal.
    if (nodeReady && File(hostJsPath).existsSync()) {
      ExtensionHostManager.instance.configure(
        hostJsPath: hostJsPath,
      );
    } else {
      throw StateError(
        'Extension host incomplet : '
        'Node.js=${nodeReady ? "present" : "absent"}, '
        'host.js=${File(hostJsPath).existsSync() ? "present" : "absent"}.',
      );
    }

    // 3. Plug TasksBridge into the Android shell (libbash.so).
    _wireTerminal(sharedPath: sharedPath);

    // 4. Load static contributions in parallel.
    await Future.wait([
      ThemeLoader.instance.loadAll(),
      SnippetLoader.instance.loadAll(),
      GrammarLoader.instance.loadAll(),
      IconThemeLoader.instance.loadAll(),
    ]);
  }

  // ── Extracting JS Assets ─────────────────────────────────────────────

  /// Copy each JS file from assets/ to $appDir/ if absent or outdated.
  ///
  /// Mapping : 'assets/extension_host/foo.js' → '$appDir/extension_host/foo.js'
  static Future<void> _extractAssets() async {
    for (final assetPath in _kExtensionHostAssets) {
      // Remove the 'assets/' prefix to get the relative path.
      final rel = assetPath.substring('assets/'.length); // 'extension_host/foo.js'
      final dest = File('$appDir/$rel');

      // Create parent directories if necessary.
      if (!dest.parent.existsSync()) {
        await dest.parent.create(recursive: true);
      }

      // Read from the Flutter bundle and write to disk.
      final data = await rootBundle.load(assetPath);
      await dest.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
  }

  // ── Wiring terminal for TasksBridge ──────────────────────────────────

  /// Branch TasksBridge.launchInTerminal to the Android shell (libbash.so).
  ///
  /// Extensions that use vscode.tasks.executeTask() will see their
  /// command launched in an Android bash subprocess.
  static void _wireTerminal({required String sharedPath}) {
    TasksBridge.instance.launchInTerminal =
        (String command, String? cwd, Map<String, String> env) async {
      await Process.start(
        '$sharedPath/libbash.so',
        ['-c', command],
        workingDirectory: cwd ?? homeDir,
        environment: {
          'PATH': '$binDir:/bin:/usr/bin:/sbin:/usr/sbin',
          'HOME': homeDir,
          'PREFIX': appDir,
          'ROXUM_SHARED_PATH': sharedPath,
          'LD_LIBRARY_PATH': '$sharedPath:$libDir:$runtimesDir/clang',
          ...env,
        },
        mode: ProcessStartMode.detached,
      );
    };
  }
}
