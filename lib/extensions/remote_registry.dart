/// Remote extension registry — ferelking242/panda-extensions.
///
/// Network resilience (mobile proot, unstable connections):
/// - short timeout on each request (never an infinite spinner)
/// - fallback CDN jsdelivr if raw.githubusercontent is slow/blocked
library;
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;




/// An entry in the catalog (index.json).
class RegistryEntry {
  final String id;
  final String name;
  final String version;
  /// Latest published version (versions[0] of the registry) — may differ
  /// from [version] when the index includes a history.
  final String latestVersion;
  final List<String> dependencies;
  final String? author;
  final String description;
  final String? iconUrl;
  final List<String> permissions;
  final List<String> tags;
  final String category;
  final String path;
  final bool featured;

  const RegistryEntry({
    required this.id,
    required this.name,
    required this.version,
    this.latestVersion = '',
    this.dependencies = const [],
    this.author,
    this.description = '',
    this.iconUrl,
    this.permissions = const [],
    this.tags = const [],
    this.category = 'tools',
    required this.path,
    this.featured = false,
  });

  factory RegistryEntry.fromJson(Map<String, dynamic> j) {
    // Latest version: versions[0].version if present (way
    // VS Code marketplace), otherwise the plain version field.
    var latest = (j['version'] ?? '0.0.0').toString();
    final versions = j['versions'];
    if (versions is List && versions.isNotEmpty) {
      final first = versions.first;
      if (first is Map && first['version'] != null) {
        latest = first['version'].toString();
      }
    }
    return RegistryEntry(
        id: j['id'] ?? '',
        name: j['name'] ?? '',
        version: (j['version'] ?? '0.0.0').toString(),
        latestVersion: latest,
        dependencies: (j['extensionDependencies'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const [],
        author: j['author'],
        description: j['description'] ?? '',
        iconUrl: j['icon'] is Map ? j['icon']['src'] as String? : null,
        permissions:
            (j['permissions'] as List?)?.map((e) => e.toString()).toList() ??
                const [],
        tags: (j['tags'] as List?)?.map((e) => e.toString()).toList() ??
            const [],
        category: j['category'] ?? 'tools',
        path: j['path'] ?? '',
        featured: j['featured'] == true,
      );
  }

  /// true if [candidate] is strictly newer than [installed]
  /// (simple semantic comparison XYZ).
  static bool isNewer(String candidate, String installed) {
    List<int> parse(String v) => v
        .split('-')
        .first
        .split('.')
        .map((e) => int.tryParse(e) ?? 0)
        .toList();
    final a = parse(candidate), b = parse(installed);
    for (var i = 0; i < 3; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }
}

class RegistryIndex {
  final List<RegistryEntry> extensions;
  final DateTime updatedAt;
  RegistryIndex({required this.extensions, required this.updatedAt});
}

class RemoteExtensionRegistry {
  RemoteExtensionRegistry._();
  static final RemoteExtensionRegistry instance =
      RemoteExtensionRegistry._();

  static const repoRawBase =
      'https://raw.githubusercontent.com/ferelking242/panda-extensions/main';
  static const repoApiBase =
      'https://api.github.com/repos/ferelking242/panda-extensions/contents';
  /// CDN fallback: serves the repo files even if GitHub raw is slow.
  static const cdnBase =
      'https://cdn.jsdelivr.net/gh/ferelking242/panda-extensions@main';
  static const indexUrl = '$repoRawBase/index.json';
  static const cdnIndexUrl = '$cdnBase/index.json';

  static const _timeout = Duration(seconds: 12);

  String installRoot = 'extensions';

  RegistryIndex? _cache;
  DateTime _cacheTime = DateTime.fromMillisecondsSinceEpoch(0);
  static const cacheTtl = Duration(minutes: 30);

  // ── Catalogue Reading ────────────────────────────────────────────

  Future<RegistryIndex> fetchIndex({bool force = false}) async {
    if (!force &&
        _cache != null &&
        DateTime.now().difference(_cacheTime) < cacheTtl) {
      return _cache!;
    }

    // Raw first, CDN as a backup — with timeout, NEVER infinite blocking
    Object? lastErr;
    for (final url in [indexUrl, cdnIndexUrl]) {
      try {
        final body = await _getString(url);
        final doc = jsonDecode(body) as Map<String, dynamic>;

        // Tolerant parser: accepts ALL forms of index.
        //  - v1 simple   : { "extensions": [...] }
        //  - sharding    : { "inline": [...], "featured": [...],
        //                    "shards": { "pages": [{url}] } }
        // Deduplicated by id — featured and inline may overlap.
        final seen = <String>{};
        final list = <RegistryEntry>[];
        void addAllFrom(List<dynamic>? raw) {
          if (raw == null) return;
          for (final e in raw) {
            if (e is! Map<String, dynamic>) continue;
            final id = (e['id'] ?? '').toString();
            if (id.isEmpty || !seen.add(id)) continue;
            list.add(RegistryEntry.fromJson(e));
          }
        }

        addAllFrom(doc['extensions'] as List<dynamic>?);
        addAllFrom(doc['inline'] as List<dynamic>?);
        addAllFrom(doc['featured'] as List<dynamic>?);

        // Shards (large registries): paginate the rest lazily
        final shards = doc['shards'];
        if (shards is Map) {
          for (final page in (shards['pages'] as List? ?? [])) {
            try {
              final shardUrl =
                  ((page as Map)['url'] ?? '') as String;
              if (shardUrl.isEmpty) continue;
              String sBody;
              try {
                sBody = await _getString(shardUrl);
              } catch (_) {
                sBody = await _getString(
                    shardUrl.replaceFirst(repoRawBase, cdnBase));
              }
              addAllFrom((jsonDecode(sBody)
                  as Map<String, dynamic>)['extensions'] as List<dynamic>?);
            } catch (_) {} // A missing shard never breaks the index
          }
        }

        _cache = RegistryIndex(
          extensions: list,
          updatedAt:
              DateTime.tryParse(doc['updatedAt'] ?? '') ?? DateTime.now(),
        );
        _cacheTime = DateTime.now();
        return _cache!;
      } catch (e) {
        lastErr = e;
      }
    }
    throw StateError(
        'Registry inaccessible (raw + CDN). Checking connection.\n$lastErr');
  }

  // ── Installation runtime ─────────────────────────────────────────

  Future<String> install(RegistryEntry entry,
      {void Function(int received, int total, String file)? onProgress}) async {
    final targetDir = p.join(installRoot, entry.id);
    await Directory(targetDir).create(recursive: true);

    final files = <_RemoteFile>[];
    await _listRecursive(entry.path, files);
    if (files.isEmpty) {
      throw StateError('No file found for ${entry.id}');
    }

    var done = 0;
    for (final f in files) {
      onProgress?.call(done, files.length, f.relPath);
      final relUnderExt = f.relPath.substring(entry.path.length + 1);
      final localPath = p.join(targetDir, relUnderExt);
      await File(localPath).parent.create(recursive: true);
      final bytes = await _download(f.rawUrl);
      await File(localPath).writeAsBytes(bytes);
      done++;
    }
    onProgress?.call(files.length, files.length, '');
    return targetDir;
  }

  Future<bool> uninstall(String extensionId) async {
    final dir = Directory(p.join(installRoot, extensionId));
    if (!await dir.exists()) return false;
    try {
      await dir.delete(recursive: true);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  Future<List<String>> listInstalled() async {
    final root = Directory(installRoot);
    if (!await root.exists()) return [];
    final ids = <String>[];
    await for (final e in root.list()) {
      if (e is Directory) {
        final hasPanda = await File(p.join(e.path, 'panda.yaml')).exists();
        final hasVsix = await File(p.join(e.path, 'package.json')).exists();
        if (hasPanda || hasVsix) {
          ids.add(p.basename(e.path));
        }
      }
    }
    return ids;
  }

  Future<bool> isInstalled(String id) async {
    final dir = p.join(installRoot, id);
    return await File(p.join(dir, 'panda.yaml')).exists() ||
        await File(p.join(dir, 'package.json')).exists();
  }

  // ── HTTP helpers ─────────────────────────────────────────────────

  Future<String> _getString(String url) async {
    final client = HttpClient()
      ..connectionTimeout = _timeout;
    try {
      final req = await client.getUrl(Uri.parse(url)).timeout(_timeout);
      final res = await req.close().timeout(_timeout);
      if (res.statusCode != 200) {
        throw HttpException('$url → ${res.statusCode}');
      }
      return await res.transform(utf8.decoder).join().timeout(_timeout);
    } finally {
      client.close();
    }
  }

  Future<void> _listRecursive(String apiPath, List<_RemoteFile> out,
      {int depth = 0}) async {
    if (depth > 6) return;
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final req = await client
          .getUrl(Uri.parse('$repoApiBase/$apiPath?ref=main'))
          .timeout(_timeout);
      req.headers.set('Accept', 'application/vnd.github+json');
      final res = await req.close().timeout(_timeout);
      if (res.statusCode != 200) return;
      final body =
          await res.transform(utf8.decoder).join().timeout(_timeout);
      final items = jsonDecode(body) as List;
      for (final item in items) {
        final m = item as Map<String, dynamic>;
        if (m['type'] == 'file') {
          out.add(_RemoteFile(
            relPath: m['path'] as String,
            rawUrl: m['download_url'] as String? ??
                '$repoRawBase/${m['path']}',
            size: (m['size'] as num?)?.toInt() ?? 0,
          ));
        } else if (m['type'] == 'dir') {
          await _listRecursive(m['path'] as String, out, depth: depth + 1);
        }
      }
    } finally {
      client.close();
    }
  }

  /// File download with automatic CDN fallback.
  Future<List<int>> _download(String url) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      for (final u in [url, url.replaceFirst(repoRawBase, cdnBase)]) {
        try {
          final req = await client.getUrl(Uri.parse(u)).timeout(_timeout);
          final res = await req.close().timeout(_timeout);
          if (res.statusCode != 200) continue;
          final builder = BytesBuilder();
          await for (final chunk in res) {
            builder.add(chunk);
          }
          return builder.takeBytes();
        } catch (_) {
          continue; // next attempt (CDN)
        }
      }
      throw HttpException('download $url failed (raw + CDN)');
    } finally {
      client.close();
    }
  }
}

class _RemoteFile {
  final String relPath;
  final String rawUrl;
  final int size;
  const _RemoteFile({
    required this.relPath,
    required this.rawUrl,
    required this.size,
  });
}
