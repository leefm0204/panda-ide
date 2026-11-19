/// Downloading and extracting .vsix files.
///
/// A .vsix file is a ZIP file containing:
///   extension/package.json   ← manifest
///   extension/package.nls.json (optionnel)
///   extension/<main>         ← entry point JS
/// extension/... ← rest of the extension
/// [Content_Types].xml ← ZIP metadata (ignored)
library;
import 'dart:convert';
import 'dart:io';
import 'package:flutter_archive/flutter_archive.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'extension_registry.dart';
import 'models/extension_manifest.dart';





/// Result of an installation.
sealed class InstallResult {
  const InstallResult();
}

class InstallSuccess extends InstallResult {
  final InstalledExtension extension;
  const InstallSuccess(this.extension);
}

class InstallFailure extends InstallResult {
  final String reason;
  const InstallFailure(this.reason);
}

/// Reason for rejecting an extension.
enum InstallRejectionReason {
  nativeBinaries,
  noEntryPoint,
  alreadyInstalled,
  downloadFailed,
  extractionFailed,
  manifestMissing,
  manifestInvalid,
}

class VsixInstaller {
  final void Function(double progress, String message)? onProgress;

  const VsixInstaller({this.onProgress});

  // ── Main Entry Point ────────────────────────────────────────────────

  /// Download and install an extension from a .vsix URL.
  Future<InstallResult> installFromUrl(String vsixUrl, {bool force = false}) async {
    _progress(0.0, 'Download…');

    // 1. Download
    final File vsixFile;
    try {
      vsixFile = await _download(vsixUrl);
    } catch (e) {
      return InstallFailure('Download failed: $e');
    }

    try {
      return await installFromFile(vsixFile, force: force);
    } finally {
      // Cleaning up temporary file
      try {
        await vsixFile.delete();
      } catch (_) {}
    }
  }

  /// Installs from a local .vsix file (e.g., selected via file_picker).
  Future<InstallResult> installFromFile(File vsixFile, {bool force = false}) async {
    _progress(0.3, 'Extraction…');

    // 2. Extract to temporary folder
    final tempDir = Directory(
        p.join(Directory.systemTemp.path, 'panda_vsix_${DateTime.now().millisecondsSinceEpoch}'));
    await tempDir.create(recursive: true);

    try {
      await ZipFile.extractToDirectory(
        zipFile: vsixFile,
        destinationDir: tempDir,
      );
    } catch (e) {
      await _cleanup(tempDir);
      return InstallFailure('Extraction failed: $e');
    }

    _progress(0.5, 'Reading manifest…');

    // 3. Reading the manifest
    final manifestFile = File(p.join(tempDir.path, 'extension', 'package.json'));
    if (!manifestFile.existsSync()) {
      await _cleanup(tempDir);
      return InstallFailure('package.json not found in .vsix');
    }

    ExtensionManifest manifest;
    try {
      final raw = jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
      manifest = ExtensionManifest.fromJson(raw);
    } catch (e) {
      await _cleanup(tempDir);
      return InstallFailure('Manifest invalide : $e');
    }

    _progress(0.6, 'Checking compatibility…');

    // 4. Compatibility checks
    if (manifest.requiresNativeBinaries) {
      await _cleanup(tempDir);
      return InstallFailure(
          'This extension uses native binaries (.node) compiled for x64 PC — '
          'Incompatible with Android ARM64.'
          'This extension cannot be installed in Panda IDE.');
    }

    // 5. Check if already installed
    await ExtensionRegistry.instance.load();
    if (!force && ExtensionRegistry.instance.isInstalled(manifest.id)) {
      await _cleanup(tempDir);
      return InstallFailure(
          '${manifest.id} is already installed. Use force: true to reinstall.');
    }

    _progress(0.7, 'Installation…');

    // 6. Move to the final installation folder
    final installPath = ExtensionRegistry.installPathFor(manifest.id, manifest.version);
    final installDir = Directory(installPath);

    if (installDir.existsSync()) {
      await installDir.delete(recursive: true);
    }

    await Directory(p.dirname(installPath)).create(recursive: true);

    // We move the "extension/" subfolder to installPath
    final extensionDir = Directory(p.join(tempDir.path, 'extension'));
    await extensionDir.rename(installPath);

    _progress(0.9, 'Enregistrement…');

    // 7. Register in the registry
    final installed = InstalledExtension(
      manifest: manifest,
      installPath: installPath,
      state: ExtensionState.enabled,
    );
    await ExtensionRegistry.instance.register(installed);

    await _cleanup(tempDir);
    _progress(1.0, 'Installation complete');

    return InstallSuccess(installed);
  }

  // ── Uninstall ───────────────────────────────────────────────────────────

  Future<bool> uninstall(String extensionId) async {
    await ExtensionRegistry.instance.load();
    final ext = ExtensionRegistry.instance.get(extensionId);
    if (ext == null) return false;

    // Delete files
    final dir = Directory(ext.installPath);
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }

    // Delete from registry
    await ExtensionRegistry.instance.unregister(extensionId);
    return true;
  }

  // ── Update ────────────────────────────────────────────────────────────────

  Future<InstallResult> update(String vsixUrl) async {
    return installFromUrl(vsixUrl, force: true);
  }

  // ── Private Helpers ─────────────────────────────────────────────────────────────

  Future<File> _download(String url) async {
    final uri = Uri.parse(url);
    final isOfficialMarketplaceHost =
        uri.host == 'marketplace.visualstudio.com' ||
        uri.host.endsWith('.gallerycdn.vsassets.io') ||
        uri.host.endsWith('.gallery.vsassets.io');
    if (uri.scheme != 'https' || !isOfficialMarketplaceHost) {
      throw ArgumentError('Unauthorized extension source');
    }
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }
    if (response.bodyBytes.length < 4 ||
        response.bodyBytes[0] != 0x50 ||
        response.bodyBytes[1] != 0x4b) {
      throw Exception('The download does not look like a VSIX archive');
    }

    final tempFile = File(
        p.join(Directory.systemTemp.path, 'panda_${DateTime.now().millisecondsSinceEpoch}.vsix'));
    await tempFile.writeAsBytes(response.bodyBytes);
    return tempFile;
  }

  Future<void> _cleanup(Directory dir) async {
    try {
      if (dir.existsSync()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  void _progress(double value, String message) {
    onProgress?.call(value, message);
  }
}
