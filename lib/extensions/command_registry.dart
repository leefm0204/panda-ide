/// CommandRegistry — vscode.commands.* — Phase 5.
///
/// Central registry of VSCode commands recorded by extensions.
/// The commands can then be executed from:
/// - The Flutter CommandPalette (Phase 5)
///   - Other extensions via vscode.commands.executeCommand()
/// - Buttons from the status bar (command:xxx)
/// - Context menu items (Phase 13)
library;
import 'dart:async';
import 'extension_host_manager.dart';




// ── Command model ─────────────────────────────────────────────────────────

class RegisteredCommand {
  final String command;
  final String extensionId;
  final String? title;       // provided by contributes.commands in package.json
  final String? category;    // ex: "Git", "Prettier"
  final String? description;

  const RegisteredCommand({
    required this.command,
    required this.extensionId,
    this.title,
    this.category,
    this.description,
  });

  /// Label displayed in the CommandPalette: "Category: Title" or just title.
  String get displayLabel {
    if (category != null && title != null) return '$category: $title';
    return title ?? command;
  }
}

// ── CommandRegistry ───────────────────────────────────────────────────────

class CommandRegistry {
  static final CommandRegistry instance = CommandRegistry._();
  CommandRegistry._();

  /// All registered commands: commandId → RegisteredCommand.
  final Map<String, RegisteredCommand> _commands = {};

  /// Listeners notified when the list changes (for the CommandPalette).
  final List<void Function()> _listeners = [];

  // ── Registration ──────────────────────────────────────────────────────────

  void register({
    required String command,
    required String extensionId,
    String? title,
    String? category,
    String? description,
  }) {
    _commands[command] = RegisteredCommand(
      command:     command,
      extensionId: extensionId,
      title:       title ?? command,
      category:    category,
      description: description,
    );
    _notifyListeners();
  }

  void unregister(String command) {
    if (_commands.remove(command) != null) _notifyListeners();
  }

  /// Registers the commands declared in contributes.commands of the manifest.
  void registerContributed(String extensionId, List<dynamic> contributes) {
    for (final item in contributes.whereType<Map<String, dynamic>>()) {
      final cmd = item['command'] as String?;
      if (cmd == null) continue;
      register(
        command:     cmd,
        extensionId: extensionId,
        title:       item['title'] as String?,
        category:    item['category'] as String?,
        description: item['description'] as String?,
      );
    }
    _notifyListeners();
  }

  void unregisterAll(String extensionId) {
    _commands.removeWhere((_, v) => v.extensionId == extensionId);
    _notifyListeners();
  }

  // ── Execution ─────────────────────────────────────────────────────────────

  /// Executes a command.
  /// Sends a 'command.invoke' event to the owner extension.
  Future<dynamic> execute(String command, List<dynamic> args) async {
    final registered = _commands[command];
    if (registered == null) {
      throw StateError('Command not registered: $command');
    }

    final bridge = ExtensionHostManager.instance.getBridge(registered.extensionId);
    if (bridge == null) {
      throw StateError(
          'The host of ${registered.extensionId} is not active for $command');
    }

    // host.js dispatches this call to the handler registered by
    // vscode.commands.registerCommand(). Calling a made-up
    // `command.<id>` RPC first caused every palette action to wait for an
    // error before falling back to an event with no result.
    return bridge.call('command.invoke', [
      {'command': command, 'args': args},
    ]);
  }

  // ── Query ─────────────────────────────────────────────────────────────────

  List<RegisteredCommand> get all => _commands.values.toList();

  List<RegisteredCommand> search(String query) {
    if (query.isEmpty) return all;
    final q = query.toLowerCase();
    return _commands.values
        .where((c) =>
            c.displayLabel.toLowerCase().contains(q) ||
            c.command.toLowerCase().contains(q))
        .toList();
  }

  RegisteredCommand? get(String command) => _commands[command];

  List<String> get commandIds => _commands.keys.toList();

  // ── Listeners ─────────────────────────────────────────────────────────────

  void addListener(void Function() fn) => _listeners.add(fn);
  void removeListener(void Function() fn) => _listeners.remove(fn);

  void _notifyListeners() {
    for (final fn in List.of(_listeners)) {
      fn();
    }
  }
}
