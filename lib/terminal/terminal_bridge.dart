/// TerminalBridge — a singleton that allows the terminal to send
/// of the selected text directly to the Panda agent and access the terminal outputs.
library;

class TerminalBridge {
  TerminalBridge._();
  static final TerminalBridge instance = TerminalBridge._();

  /// Callback installed by home.dart to receive messages from the terminal.
  void Function(String text)? onSendToAgent;

  /// True if home.dart has registered a listener.
  bool get isActive => onSendToAgent != null;

  /// Sends [text] to the agent (no-op if no listener is registered).
  void sendToAgent(String text) => onSendToAgent?.call(text);

  final List<String> _outputBuffer = [];
  static const int _maxBufferLines = 500;

  void appendOutput(String data) {
    final lines = data.split('\n');
    _outputBuffer.addAll(lines);
    if (_outputBuffer.length > _maxBufferLines) {
      _outputBuffer.removeRange(0, _outputBuffer.length - _maxBufferLines);
    }
  }

  String getRecentOutput([int lines = 100]) {
    if (_outputBuffer.isEmpty) return '(No recent terminal output)';
    final count = lines > _outputBuffer.length ? _outputBuffer.length : lines;
    final slice = _outputBuffer.sublist(_outputBuffer.length - count);
    return slice.join('\n');
  }
}
