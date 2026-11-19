/// Bridge Flutter for vscode.workspace.* — Phase 3.
///
/// Implements workspace operations on the Flutter side:
/// - openTextDocument
/// - saveAll
/// - applyEdit (WorkspaceEdit)
/// - findFiles
/// - getConfiguration (delegates to ConfigStore)
/// - FileSystem API (delegates to FsBridge)
///
/// This bridge is called by ExtensionApiRouter._routeWorkspace().
library;
import 'dart:io';
import 'package:path/path.dart' as p;
import 'config_store.dart';





// ── Document Text Model (lightweight proxy) ──────────────────────────────

class TextDocumentProxy {
  final String fsPath;
  final String languageId;
  final String content;
  final int version;

  const TextDocumentProxy({
    required this.fsPath,
    required this.languageId,
    required this.content,
    required this.version,
  });

  Map<String, dynamic> toJson() => {
    'uri': 'file://$fsPath',
    'fsPath': fsPath,
    'languageId': languageId,
    'content': content,
    'lineCount': content.split('\n').length,
    'version': version,
    'isDirty': false,
    'isUntitled': false,
    'fileName': p.basename(fsPath),
    'getText': null, // JS side, getText() returns content directly
  };
}

// ── WorkspaceBridge ───────────────────────────────────────────────────────

class WorkspaceBridge {
  static final WorkspaceBridge instance = WorkspaceBridge._();
  WorkspaceBridge._();

  /// Root folder of the active workspace (provided by the IDE).
  String? workspaceRoot;

  /// Callback to the IDE to save all open files.
  Future<bool> Function()? onSaveAll;

  /// Callback to apply a WorkspaceEdit (list of text edits).
  Future<bool> Function(List<Map<String, dynamic>> edits)? onApplyEdit;

  // ── openTextDocument ─────────────────────────────────────────────────────

  Future<Map<String, dynamic>?> openTextDocument(dynamic arg) async {
    String? fsPath;
    String? languageId;
    String? content;

    if (arg is Map<String, dynamic>) {
      // { language, content } — document virtuel (untitled)
      if (arg.containsKey('content')) {
        content    = arg['content'] as String? ?? '';
        languageId = arg['language'] as String? ?? 'plaintext';
        fsPath     = 'untitled://untitled';
        return TextDocumentProxy(
          fsPath: fsPath,
          languageId: languageId,
          content: content,
          version: 1,
        ).toJson();
      }
      // { scheme, path, ... } — serialized URI
      fsPath = arg['fsPath'] as String? ?? arg['path'] as String?;
    } else if (arg is String) {
      fsPath = arg;
    }

    if (fsPath == null) return null;

    // Read the file from the FS
    final file = File(fsPath);
    if (!file.existsSync()) return null;

    content    = await file.readAsString();
    languageId = _inferLanguageId(fsPath);

    return TextDocumentProxy(
      fsPath: fsPath,
      languageId: languageId,
      content: content,
      version: 1,
    ).toJson();
  }

  // ── saveAll ───────────────────────────────────────────────────────────────

  Future<bool> saveAll(bool includeUntitled) async {
    return await onSaveAll?.call() ?? false;
  }

  // ── applyEdit ─────────────────────────────────────────────────────────────

  Future<bool> applyEdit(List<dynamic> edits) async {
    // Try the IDE callback first (for files opened in the editor)
    final typed = edits.whereType<Map<String, dynamic>>().toList();

    if (onApplyEdit != null) {
      return await onApplyEdit!(typed);
    }

    // Fallback: apply directly to the FS
    try {
      for (final edit in typed) {
        final uriMap = edit['uri'] as Map<String, dynamic>?;
        final fsPath = uriMap?['fsPath'] as String? ?? uriMap?['path'] as String?;
        if (fsPath == null) continue;

        final file = File(fsPath);
        if (!file.existsSync()) continue;

        final type    = edit['type'] as String? ?? 'replace';
        final newText = edit['newText'] as String? ?? '';

        if (type == 'replace' || type == 'insert' || type == 'delete') {
          var content = await file.readAsString();
          final range = edit['range'] as Map<String, dynamic>?;
          if (range != null) {
            content = _applyRangeEdit(content, range, newText);
          }
          await file.writeAsString(content);
        }
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  String _applyRangeEdit(
      String content, Map<String, dynamic> range, String newText) {
    final lines = content.split('\n');
    final startLine = (range['start']?['line'] as num?)?.toInt() ?? 0;
    final startChar = (range['start']?['character'] as num?)?.toInt() ?? 0;
    final endLine   = (range['end']?['line'] as num?)?.toInt() ?? startLine;
    final endChar   = (range['end']?['character'] as num?)?.toInt() ?? startChar;

    if (startLine >= lines.length) return content;

    final before = lines[startLine].substring(0, startChar.clamp(0, lines[startLine].length));
    final after  = endLine < lines.length
        ? lines[endLine].substring(endChar.clamp(0, lines[endLine].length))
        : '';

    final newLines = <String>[...lines.sublist(0, startLine), '$before$newText$after', ...lines.sublist((endLine + 1).clamp(0, lines.length))];
    return newLines.join('\n');
  }

  // ── findFiles ─────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> findFiles(
    String include,
    String? exclude,
    int? maxResults,
  ) async {
    final root = workspaceRoot;
    if (root == null) return [];

    final results = <Map<String, dynamic>>[];
    final rootDir = Directory(root);
    if (!rootDir.existsSync()) return [];

    await for (final entity in rootDir.list(recursive: true)) {
      if (entity is File) {
        final rel = p.relative(entity.path, from: root);
        // Simplified pattern matching — supports **.ext and **/folder/**
        if (_matchGlob(rel, include)) {
          if (exclude != null && _matchGlob(rel, exclude)) continue;
          results.add({
            'scheme': 'file',
            'authority': '',
            'path': entity.path,
            'fsPath': entity.path,
          });
          if (maxResults != null && results.length >= maxResults) break;
        }
      }
    }

    return results;
  }

  bool _matchGlob(String path, String pattern) {
    // Conversion glob → RegExp basique
    final regexStr = pattern
        .replaceAll('.', r'\.')
        .replaceAll('**/', '(.*/)?')
        .replaceAll('**', '.*')
        .replaceAll('*', '[^/]*')
        .replaceAll('?', '[^/]');
    try {
      return RegExp('^$regexStr\$').hasMatch(path);
    } catch (_) {
      return path.contains(pattern.replaceAll('*', '').replaceAll('?', ''));
    }
  }

  // ── getConfiguration ──────────────────────────────────────────────────────

  Map<String, dynamic> getConfiguration(String? section) {
    return ConfigStore.instance.getSectionProxy(section);
  }

  Future<void> updateConfiguration(
    String? section,
    String key,
    dynamic value,
    int? target,
  ) async {
    await ConfigStore.instance.update(section, key, value, target);
  }

  // ── workspaceFolders ──────────────────────────────────────────────────────

  List<Map<String, dynamic>> get workspaceFolders {
    if (workspaceRoot == null) return [];
    return [
      {
        'index': 0,
        'name': p.basename(workspaceRoot!),
        'uri': {
          'scheme': 'file',
          'authority': '',
          'path': workspaceRoot,
          'fsPath': workspaceRoot,
        },
      }
    ];
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static String _inferLanguageId(String fsPath) {
    final ext = p.extension(fsPath).toLowerCase().replaceFirst('.', '');
    return const {
      'dart': 'dart', 'js': 'javascript', 'ts': 'typescript',
      'jsx': 'javascriptreact', 'tsx': 'typescriptreact',
      'py': 'python', 'rb': 'ruby', 'rs': 'rust', 'go': 'go',
      'java': 'java', 'kt': 'kotlin', 'swift': 'swift',
      'c': 'c', 'cpp': 'cpp', 'cc': 'cpp', 'h': 'c', 'hpp': 'cpp',
      'cs': 'csharp', 'php': 'php', 'html': 'html', 'css': 'css',
      'scss': 'scss', 'sass': 'sass', 'less': 'less',
      'json': 'json', 'yaml': 'yaml', 'yml': 'yaml',
      'toml': 'toml', 'xml': 'xml', 'sh': 'shellscript',
      'bash': 'shellscript', 'zsh': 'shellscript', 'fish': 'shellscript',
      'md': 'markdown', 'lua': 'lua', 'vim': 'vim',
      'dockerfile': 'dockerfile', 'makefile': 'makefile',
      'sql': 'sql', 'r': 'r', 'tex': 'latex', 'vue': 'vue',
      'svelte': 'svelte', 'ex': 'elixir', 'exs': 'elixir',
      'elm': 'elm', 'clj': 'clojure', 'hs': 'haskell',
      'erl': 'erlang', 'ml': 'ocaml', 'fs': 'fsharp',
    }[ext] ?? 'plaintext';
  }
}
