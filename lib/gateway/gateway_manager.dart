import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'gateway_installer.dart';

/// Gateway States
enum GatewayStatus { idle, installing, starting, running, stopping, error }

/// GatewayManager — manages the lifecycle of the uvicorn Python server.
///
/// Sends notifications via ChangeNotifier so that the UI reacts.
/// Launch the gateway in extension mode: reads the configuration from assets/gateway/
/// or from the directory installed in the app's storage.
class GatewayManager extends ChangeNotifier {
  GatewayStatus _status = GatewayStatus.idle;
  String _statusMessage = 'Gateway stopped';
  final List<String> _logs = [];
  Process? _pythonProcess;
  final int _apiPort = 8000;
  String _provider = 'chatgpt';
  String _token = '';
  String _installedVersion = 'unknown';
  String? _availableUpdate;

  // Getters
  GatewayStatus get status => _status;
  String get statusMessage => _statusMessage;
  List<String> get logs => List.unmodifiable(_logs);
  bool get isRunning => _status == GatewayStatus.running;
  int get apiPort => _apiPort;
  String get provider => _provider;
  String get apiBaseUrl => 'http://127.0.0.1:$_apiPort/v1';
  String get installedVersion => _installedVersion;
  String? get availableUpdate => _availableUpdate;
  bool get hasUpdate => _availableUpdate != null && _availableUpdate != _installedVersion;

  void setProvider(String p) {
    _provider = p;
    notifyListeners();
  }

  void setToken(String t) {
    _token = t;
    notifyListeners();
  }

  /// Public wrapper so UI can detect Python without starting the server.
  Future<String?> findPython() => _findPython();

  /// Checks for available updates.
  Future<void> checkForUpdate() async {
    try {
      _availableUpdate = await GatewayInstaller.checkForUpdate();
      _installedVersion = await GatewayInstaller.getInstalledVersion();
      notifyListeners();
    } catch (_) {}
  }

  // ── Start ──────────────────────────────────────────────────────────────────────

  Future<void> start(String installDir) async {
    if (_status == GatewayStatus.running || _status == GatewayStatus.starting) return;

    _setStatus(GatewayStatus.starting, 'Gateway starting…');
    _addLog('▶ Panda AI Gateway Startup');

    final pythonBin = await _findPython();
    if (pythonBin == null) {
      _setStatus(GatewayStatus.error, 'Python not found. Install Python via the Package Manager.');
      return;
    }

    _addLog('Python: $pythonBin');
    _addLog('Directory: $installDir');

    // Check the installed version
    try {
      _installedVersion = await GatewayInstaller.getInstalledVersion();
      _addLog('Version: $_installedVersion');
    } catch (_) {}

    // Check for background updates
    checkForUpdate();

    // Find the Android .env file
    final envFile = File('$installDir/android.env');
    final envExists = await envFile.exists();

    // Construct environment variables
    final env = <String, String>{
      'API_HOST': '127.0.0.1',
      'API_PORT': '$_apiPort',
      'PROVIDER': _provider,
      'BROWSER_MODE': 'android',
      'WEBVIEW_BRIDGE_PORT': '9221',
      'HEADLESS': 'true',
      'SLOW_MO': '0',
      'LOG_LEVEL': 'INFO',
      'VERBOSE': 'false',
      'RESPONSE_TIMEOUT': '180000',
      'SELECTOR_TIMEOUT': '15000',
      'POLL_INTERVAL_MS': '500',
      if (_token.isNotEmpty) 'API_TOKEN': _token,
    };

    // Load the environment file if present
    if (envExists) {
      final lines = await envFile.readAsLines();
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
        final eq = trimmed.indexOf('=');
        if (eq < 0) continue;
        final key = trimmed.substring(0, eq).trim();
        final val = trimmed.substring(eq + 1).trim();
        env.putIfAbsent(key, () => val);
      }
    }

    try {
      _pythonProcess = await Process.start(
        pythonBin,
        [
          '-m', 'uvicorn', 'src.api.server:app',
          '--host', '127.0.0.1',
          '--port', '$_apiPort',
          '--log-level', 'info',
        ],
        workingDirectory: installDir,
        environment: env,
        runInShell: false,
      );

      _addLog('Python PID: ${_pythonProcess!.pid}');
      _listenProcess(_pythonProcess!);

    } catch (e) {
      _setStatus(GatewayStatus.error, 'Startup error: $e');
      _addLog('✗ Error: $e');
    }
  }

  void _listenProcess(Process proc) {
    bool started = false;

    void onLine(String line) {
      _addLog(line);
      if (!started &&
          (line.contains('Application startup complete') ||
           line.contains('Uvicorn running') ||
           line.contains('Started server process'))) {
        started = true;
        _setStatus(GatewayStatus.running, 'Gateway active on:$_apiPort');
        _addLog('✓ API available at http://127.0.0.1:$_apiPort');
      }
    }

    proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(onLine);
    proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(onLine);

    proc.exitCode.then((code) {
      if (_status != GatewayStatus.idle) {
        _setStatus(GatewayStatus.idle, 'Gateway stopped (code $code)');
        _addLog('■ Process completed (code $code)');
        // Auto-restart on crash
        if (code != 0) {
          _addLog('⚠ Crash detected — automatic restart in 3 seconds…');
          Future.delayed(const Duration(seconds: 3), () async {
            final dir = await GatewayInstaller.getInstallDir();
            start(dir);
          });
        }
      }
    });
  }

  // ── Stop ──────────────────────────────────────────────────────────────────────────

  Future<void> stop() async {
    _setStatus(GatewayStatus.stopping, 'Stop in progress…');
    _addLog('■ Gateway shutdown');

    _pythonProcess?.kill();
    _pythonProcess = null;

    await Future.delayed(const Duration(milliseconds: 500));
    _setStatus(GatewayStatus.idle, 'Gateway stopped');
  }

  // ── Update ────────────────────────────────────────────────────────────────

  Future<void> update({
    void Function(String msg)? onProgress,
  }) async {
    _setStatus(GatewayStatus.installing, 'Updating in progress…');
    _addLog('⬆ Gateway update…');

    await GatewayInstaller.update(onProgress: (msg) {
      _addLog(msg);
      onProgress?.call(msg);
    });

    _installedVersion = await GatewayInstaller.getInstalledVersion();
    _availableUpdate = null;
    notifyListeners();

    // Restart with new version
    if (_status != GatewayStatus.running) {
      final dir = await GatewayInstaller.getInstallDir();
      await start(dir);
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Future<String?> _findPython() async {
    final candidates = [
      '/data/data/com.termux.app/files/usr/bin/python3',
      '/usr/bin/python3',
      '/usr/local/bin/python3',
      '/usr/bin/python',
    ];
    for (final p in candidates) {
      if (await File(p).exists()) return p;
    }
    // Essai via PATH
    try {
      final result = await Process.run('which', ['python3']);
      if (result.exitCode == 0) {
        final p = (result.stdout as String).trim();
        if (p.isNotEmpty) return p;
      }
    } catch (_) {}
    return null;
  }

  void _setStatus(GatewayStatus s, String msg) {
    _status = s;
    _statusMessage = msg;
    notifyListeners();
  }

  void _addLog(String line) {
    final ts = DateTime.now().toIso8601String().substring(11, 19);
    _logs.add('[$ts] $line');
    if (_logs.length > 500) _logs.removeAt(0);
    notifyListeners();
  }

  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _pythonProcess?.kill();
    super.dispose();
  }
}
