/// ExtensionExportsRegistry — vscode.extensions.* inter-extension API — Phase 6.
///
/// Stores the exports returned by activate() for each active extension.
/// Allows one extension to access another's public APIs via
/// vscode.extensions.getExtension('id').exports
library;

// ── ExtensionExportsRegistry ──────────────────────────────────────────────

class ExtensionExportsRegistry {
  static final ExtensionExportsRegistry instance =
      ExtensionExportsRegistry._();
  ExtensionExportsRegistry._();

  /// exports par extensionId
  final Map<String, dynamic> _exports = {};

  /// Lightweight metadata (id, version, isActive, extensionPath)
  final Map<String, Map<String, dynamic>> _metadata = {};

  // ── Enregistrement ────────────────────────────────────────────────────────

  void register({
    required String extensionId,
    required String version,
    required String extensionPath,
    dynamic exports,
  }) {
    _exports[extensionId]  = exports;
    _metadata[extensionId] = {
      'id':            extensionId,
      'version':       version,
      'extensionPath': extensionPath,
      'isActive':      true,
      'packageJSON':   <String, dynamic>{}, // rempli par ExtensionHostManager si besoin
    };
  }

  void unregister(String extensionId) {
    _exports.remove(extensionId);
    _metadata.remove(extensionId);
  }

  // ── Query ─────────────────────────────────────────────────────────────────

  /// Returns the Serializable Extension object (for JSON IPC).
  Map<String, dynamic>? getExtensionJson(String extensionId) {
    final meta = _metadata[extensionId];
    if (meta == null) return null;
    return {
      ...meta,
      'exports': _exports[extensionId],
    };
  }

  /// Returns the raw exports of an extension (null if not active).
  dynamic getExports(String extensionId) => _exports[extensionId];

  /// Returns all metadata (for vscode.extensions.all).
  List<Map<String, dynamic>> getAll() => _metadata.values.toList();

  bool isActive(String extensionId) => _metadata.containsKey(extensionId);

  // ── Updating JSON packages ─────────────────────────────────────────────

  void setPackageJson(String extensionId, Map<String, dynamic> packageJson) {
    final meta = _metadata[extensionId];
    if (meta != null) {
      meta['packageJSON'] = packageJson;
    }
  }
}
