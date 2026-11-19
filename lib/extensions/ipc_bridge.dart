/// IPC bridge between Flutter and a Node.js Extension Host process.
///
/// Protocol: newline-delimited JSON over stdin/stdout.
/// Each line = a complete IpcMessage JSON.
///
/// Flutter → Node.js: call(activate, events editor)
/// Node.js → Flutter :  apiCall (vscode.window.show..., etc.)
library;
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'models/extension_message.dart';




typedef ApiCallHandler = Future<dynamic> Function(IpcMessage msg);

/// Manages JSON-RPC communication with a Node.js process.
class IpcBridge {
  final Process _process;
  final ApiCallHandler _onApiCall;

  int _nextId = 1;
  final Map<int, Completer<dynamic>> _pending = {};
  StreamSubscription<String>? _sub;
  Future<void>? _exitMonitor;
  bool _closed = false;

  IpcBridge._(this._process, this._onApiCall);

  // ── Factory ──────────────────────────────────────────────────────────────

  static Future<IpcBridge> attach(
    Process process,
    ApiCallHandler onApiCall,
  ) async {
    final bridge = IpcBridge._(process, onApiCall);
    bridge._listen();
    return bridge;
  }

  // ── API publique ─────────────────────────────────────────────────────────

  /// Sends a call and waits for a response.
  Future<dynamic> call(String method, [List<dynamic> params = const []]) async {
    if (_closed) throw StateError('IpcBridge is closed');

    final id = _nextId++;
    final msg = IpcMessage.call(id, method, params);
    final completer = Completer<dynamic>();
    _pending[id] = completer;

    _send(msg);

    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('IPC call "$method" timed out after 30s');
      },
    );
  }

  /// Sends a unidirectional event (no response expected).
  void fireEvent(String event, [dynamic data]) {
    if (_closed) return;
    _send(IpcMessage.event(event, data));
  }

  /// Close the bridge properly and kill the process.
  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    await _sub?.cancel();
    // Cancel all pending
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(StateError('IpcBridge disposed'));
      }
    }
    _pending.clear();
    _process.kill();
    await _process.exitCode;
  }

  bool get isClosed => _closed;

  // ── Reception ────────────────────────────────────────────────────────────────────

  void _listen() {
    _sub = _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _handleLine,
          onError: (e) => _closeWithError('stdout error: $e'),
          onDone: () => _closeWithError('Extension host stdout closed'),
        );

    // Stderr errors are logged but do not interrupt the bridge
    _process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      // ignore: avoid_print
      print('[ExtHost stderr] $line');
    });

    _exitMonitor = _process.exitCode.then((code) {
      if (!_closed) {
        _closeWithError('Extension host exited with code $code');
      }
    });
  }

  void _handleLine(String line) {
    if (line.trim().isEmpty) return;
    Map<String, dynamic> json;
    try {
      json = jsonDecode(line) as Map<String, dynamic>;
    } catch (e) {
      // non-JSON line (e.g., extension console.log) → ignore
      return;
    }

    final msg = IpcMessage.fromJson(json);

    switch (msg.type) {
      case IpcMessageType.ret:
        // Response to one of our calls
        final c = _pending.remove(msg.id);
        if (c != null && !c.isCompleted) {
          c.complete(msg.result);
        }

      case IpcMessageType.error:
        // Error in response to one of our calls
        final c = _pending.remove(msg.id);
        if (c != null && !c.isCompleted) {
          c.completeError(Exception(msg.error ?? 'Unknown IPC error'));
        }

      case IpcMessageType.apiCall:
        // The extension requests something from the IDE → it is processed and responded
        _handleApiCall(msg);

      case IpcMessageType.event:
        // Unilateral notification of the extension (rare in the direction of Node→Flutter)
        // We're ignoring them for now (the events will mostly Flutter→Node)
        break;

      default:
        break;
    }
  }

  Future<void> _handleApiCall(IpcMessage msg) async {
    try {
      final result = await _onApiCall(msg);
      _send(IpcMessage.apiReturn(msg.id, msg.method, result));
    } catch (e) {
      _send(IpcMessage.apiError(msg.id, msg.method, e.toString()));
    }
  }

  // ── Envoi ────────────────────────────────────────────────────────────────

  void _send(IpcMessage msg) {
    if (_closed) return;
    try {
      final line = '${jsonEncode(msg.toJson())}\n';
      _process.stdin.write(line);
    } catch (e) {
      // ignore: avoid_print
      print('[IpcBridge] send error: $e');
    }
  }

  void _closeWithError(String reason) {
    _closed = true;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError(reason));
    }
    _pending.clear();
  }
}
