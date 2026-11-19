import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:flutter_archive/flutter_archive.dart';

/// GatewayInstaller — downloads and installs Panda AI Gateway.
///
/// Strategy:
/// 1. If the installation directory exists and is valid → skip
/// 2. Alternatively: download from GitHub Releases (panda-ai)
/// 3. Fallback: extract from assets/gateway/ (bundled in the APK)
///   4. Run pip install -r requirements.txt
class GatewayInstaller {
  static const _githubRepo = 'ferelking242/panda-ai';
  static const _releaseAsset = 'panda-ai.zip';
  static const _versionFile = '.gateway_version';

  /// Returns the installation directory (created if necessary).
  static Future<String> getInstallDir() async {
    final base = await getApplicationSupportDirectory();
    return '${base.path}/gateway';
  }

  /// Checks if the gateway is already installed and valid.
  static Future<bool> isInstalled() async {
    final dir = await getInstallDir();
    final marker = File('$dir/requirements.txt');
    return marker.exists();
  }

  /// Returns the installed version (GitHub tag or 'bundled').
  static Future<String> getInstalledVersion() async {
    final dir = await getInstallDir();
    final vFile = File('$dir/$_versionFile');
    if (await vFile.exists()) {
      return (await vFile.readAsString()).trim();
    }
    return 'unknown';
  }

  /// Checks if an update is available.
  static Future<String?> checkForUpdate() async {
    try {
      final apiUrl =
          'https://api.github.com/repos/$_githubRepo/releases/latest';
      final resp = await http.get(
        Uri.parse(apiUrl),
        headers: {'Accept': 'application/vnd.github+json'},
      ).timeout(const Duration(seconds: 10));

      if (resp.statusCode != 200) return null;

      final release = json.decode(resp.body) as Map<String, dynamic>;
      final latestTag = release['tag_name'] as String? ?? 'latest';
      final currentVersion = await getInstalledVersion();

      if (latestTag != currentVersion) {
        return latestTag;
      }
      return null; // already up to date
    } catch (_) {
      return null;
    }
  }

  /// Installs the gateway (download + pip install).
  /// [onProgress] receives progress messages.
  static Future<void> install({
    void Function(String msg)? onProgress,
    bool forceReinstall = false,
  }) async {
    final dir = await getInstallDir();

    void log(String msg) => onProgress?.call(msg);

    if (!forceReinstall && await isInstalled()) {
      log('✓ Gateway already installed in $dir');
      return;
    }

    log('📦 Installing Panda AI Gateway…');
    await Directory(dir).create(recursive: true);

    // 1. Attempt the GitHub download
    bool downloaded = false;
    String? tag;
    try {
      final result = await _downloadFromGitHub(dir, log: log);
      downloaded = result.$1;
      tag = result.$2;
    } catch (e) {
      log('⚠ GitHub download failed: $e');
    }

    // 2. Fallback: bundled assets
    if (!downloaded) {
      log('📦 Extraction from embedded assets…');
      await _extractFromAssets(dir, log: log);
      tag = 'bundled';
    }

    // 3. pip install
    await _pipInstall(dir, log: log);

    // 4. Save version
    if (tag != null) {
      await File('$dir/$_versionFile').writeAsString(tag);
    }

    log('✓ Complete installation — version $tag');
  }

  /// Updates the gateway to the latest version.
  static Future<void> update({
    void Function(String msg)? onProgress,
  }) async {
    await install(onProgress: onProgress, forceReinstall: true);
  }

  // ── GitHub download ────────────────────────────────────────────────────────

  static Future<(bool, String?)> _downloadFromGitHub(
    String destDir, {
    void Function(String)? log,
  }) async {
    log?.call('🌐 Retrieving the latest GitHub release…');

    final apiUrl =
        'https://api.github.com/repos/$_githubRepo/releases/latest';
    final resp = await http.get(
      Uri.parse(apiUrl),
      headers: {'Accept': 'application/vnd.github+json'},
    ).timeout(const Duration(seconds: 15));

    if (resp.statusCode != 200) {
      throw Exception('GitHub API ${resp.statusCode}');
    }

    final release = json.decode(resp.body) as Map<String, dynamic>;
    final assets = (release['assets'] as List?) ?? [];
    final tagName = release['tag_name'] as String? ?? 'latest';

    // Look for the ZIP asset
    String? downloadUrl;
    for (final asset in assets) {
      final name = asset['name'] as String;
      if (name.contains('panda-ai') && name.endsWith('.zip')) {
        downloadUrl = asset['browser_download_url'] as String;
        break;
      }
    }

    // Fallback: release zipball
    downloadUrl ??=
        'https://github.com/$_githubRepo/archive/refs/tags/$tagName.zip';

    log?.call('⬇ Download $tagName…');

    final zipResp =
        await http.get(Uri.parse(downloadUrl)).timeout(const Duration(seconds: 120));

    if (zipResp.statusCode != 200) {
      throw Exception('Download ${zipResp.statusCode}');
    }

    final zipFile = File('$destDir/gateway.zip');
    await zipFile.writeAsBytes(zipResp.bodyBytes);
    log?.call('✓ Downloaded (${zipResp.bodyBytes.length ~/ 1024} KB)');

    await _extractZip(zipFile, destDir, log: log);
    await zipFile.delete();
    return (true, tagName);
  }

  // ── Bundled Assets ──────────────────────────────────────────────────────────────

  static Future<void> _extractFromAssets(
    String destDir, {
    void Function(String)? log,
  }) async {
    final assetFiles = ['package.json', 'requirements.txt', 'android.env'];
    for (final name in assetFiles) {
      try {
        final data = await rootBundle.load('assets/gateway/$name');
        final file = File('$destDir/$name');
        await file.writeAsBytes(data.buffer.asUint8List());
        log?.call('  ✓ $name');
      } catch (e) {
        log?.call('  ⚠ assets/gateway/$name: $e');
      }
    }
    // Create the necessary folders
    await Directory('$destDir/src/api').create(recursive: true);
    await Directory('$destDir/src/browser').create(recursive: true);
    log?.call('Note: limited assets — clone the entire repo.');
    log?.call('git clone https://github.com/$_githubRepo');
  }

  // ── ZIP extraction ────────────────────────────────────────────────────────

  static Future<void> _extractZip(
    File zipFile,
    String destDir, {
    void Function(String)? log,
  }) async {
    log?.call('📂 ZIP extraction…');
    final destDirectory = Directory(destDir);

    try {
      await ZipFile.extractToDirectory(
        zipFile: zipFile,
        destinationDir: destDirectory,
      );
    } catch (e) {
      log?.call('⚠ ZipFile extraction failed: $e');
      final result = await Process.run(
        'unzip', ['-o', zipFile.path, '-d', destDir],
      );
      if (result.exitCode != 0) {
        throw Exception('unzip failed: ${result.stderr}');
      }
    }

    // If the extraction created a subfolder (as in the case of a GitHub zipball),
    // move the content to destDir
    final entries = await destDirectory.list().toList();
    if (entries.length == 1 && entries.first is Directory) {
      final subDir = entries.first as Directory;
      log?.call('  Reorganization since ${subDir.path}…');
      await _moveContents(subDir, destDirectory);
      await subDir.delete(recursive: true);
    }

    log?.call('✓ Complete extraction');
  }

  static Future<void> _moveContents(Directory from, Directory to) async {
    await for (final entity in from.list()) {
      final name = entity.path.split('/').last;
      if (entity is File) {
        await entity.copy('${to.path}/$name');
      } else if (entity is Directory) {
        await _copyDir(entity, Directory('${to.path}/$name'));
      }
    }
  }

  static Future<void> _copyDir(Directory from, Directory to) async {
    await to.create(recursive: true);
    await for (final entity in from.list()) {
      final name = entity.path.split('/').last;
      if (entity is File) {
        await entity.copy('${to.path}/$name');
      } else if (entity is Directory) {
        await _copyDir(entity, Directory('${to.path}/$name'));
      }
    }
  }

  // ── pip install ───────────────────────────────────────────────────────────

  static Future<void> _pipInstall(
    String installDir, {
    void Function(String)? log,
  }) async {
    final reqFile = File('$installDir/requirements.txt');
    if (!await reqFile.exists()) {
      log?.call('⚠ requirements.txt not found — pip install ignored');
      return;
    }

    log?.call('📦 Installing Python dependencies…');

    final pip = await _findPip();
    if (pip == null) {
      log?.call('⚠ pip not found. Install Python + pip via the Package Manager.');
      return;
    }

    final proc = await Process.start(
      pip,
      ['install', '-r', 'requirements.txt', '--quiet'],
      workingDirectory: installDir,
    );

    proc.stdout
        .transform(const Utf8Decoder())
        .transform(const LineSplitter())
        .listen((l) => log?.call('  $l'));
    proc.stderr
        .transform(const Utf8Decoder())
        .transform(const LineSplitter())
        .listen((l) => log?.call('  $l'));

    final code = await proc.exitCode;
    if (code == 0) {
      log?.call('✓ Installed outbuildings');
    } else {
      log?.call('⚠ pip install has finished with the code $code');
    }
  }

  static Future<String?> _findPip() async {
    final candidates = [
      '/data/data/com.termux.app/files/usr/bin/pip3',
      '/data/data/com.termux.app/files/usr/bin/pip',
      '/usr/bin/pip3',
      '/usr/local/bin/pip3',
    ];
    for (final p in candidates) {
      if (await File(p).exists()) return p;
    }
    try {
      final r = await Process.run('which', ['pip3']);
      if (r.exitCode == 0) {
        final p = (r.stdout as String).trim();
        if (p.isNotEmpty) return p;
      }
    } catch (_) {}
    return null;
  }
}
