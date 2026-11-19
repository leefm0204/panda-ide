/// IPC message template between Flutter and the Node.js Extension Host process.
/// Protocol: newline-delimited JSON over stdin/stdout.
library;

enum IpcMessageType {
  /// Flutter → Node.js: method call (activate, deactivate, fireEvent)
  call,
  /// Node.js → Flutter: return result after a call
  ret,
  /// Node.js → Flutter: vscode API call (the extension requests something from the IDE)
  apiCall,
  /// Flutter → Node.js: response to an apiCall
  apiReturn,
  /// Unidirectional: notification with no expected response
  event,
  /// Error
  error,
}

class IpcMessage {
  /// Unique transaction ID (incremented by the issuer).
  /// Events have id = 0.
  final int id;
  final IpcMessageType type;

  /// Method name / API / event.
  final String method;

  /// Parameters (for call, apiCall, event).
  final List<dynamic> params;

  /// Result (for ret, apiReturn).
  final dynamic result;

  /// Error (for error).
  final String? error;

  const IpcMessage({
    required this.id,
    required this.type,
    required this.method,
    this.params = const [],
    this.result,
    this.error,
  });

  // ── Convenience Builders ────────────────────────────────────────────

  /// Flutter call → Node.js (activate extension, send an editor event, etc.)
  factory IpcMessage.call(int id, String method, [List<dynamic> params = const []]) =>
      IpcMessage(id: id, type: IpcMessageType.call, method: method, params: params);

  /// Flutter → Node.js return in response to an apiCall from the extension.
  factory IpcMessage.apiReturn(int id, String method, dynamic result) =>
      IpcMessage(id: id, type: IpcMessageType.apiReturn, method: method, result: result);

  /// Flutter → Node.js return to report an error during an apiCall.
  factory IpcMessage.apiError(int id, String method, String error) =>
      IpcMessage(id: id, type: IpcMessageType.error, method: method, error: error);

  /// Event unidirectionnel Flutter → Node.js (ex: onDidChangeTextDocument).
  factory IpcMessage.event(String event, [dynamic data]) =>
      IpcMessage(id: 0, type: IpcMessageType.event, method: event, params: data != null ? [data] : []);

  // ── Serialization ─

  factory IpcMessage.fromJson(Map<String, dynamic> json) {
    final typeStr = json['type'] as String? ?? 'call';
    final type = switch (typeStr) {
      'call'      => IpcMessageType.call,
      'ret'       => IpcMessageType.ret,
      'apiCall'   => IpcMessageType.apiCall,
      'apiReturn' => IpcMessageType.apiReturn,
      'event'     => IpcMessageType.event,
      _           => IpcMessageType.error,
    };

    return IpcMessage(
      id: (json['id'] as num?)?.toInt() ?? 0,
      type: type,
      method: json['method'] as String? ?? '',
      params: (json['params'] as List?)?.cast<dynamic>() ?? const [],
      result: json['result'],
      error: json['error'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    final typeStr = switch (type) {
      IpcMessageType.call      => 'call',
      IpcMessageType.ret       => 'ret',
      IpcMessageType.apiCall   => 'apiCall',
      IpcMessageType.apiReturn => 'apiReturn',
      IpcMessageType.event     => 'event',
      IpcMessageType.error     => 'error',
    };

    return {
      'id': id,
      'type': typeStr,
      'method': method,
      if (params.isNotEmpty) 'params': params,
      if (result != null) 'result': result,
      if (error != null) 'error': error,
    };
  }

  @override
  String toString() => 'IpcMessage($type, id=$id, method=$method)';
}
