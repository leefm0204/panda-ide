/// Panda extensions registry — EMBEDDED section in the marketplace.
///
/// [PandaRegistrySection] is displayed directly in the Home tab of the store
/// (no navigation to a new page). [PandaRegistryPage] remains
/// available as a standalone view (dedicated route).
library;
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import '../models/panda_manifest.dart';
import '../native_extension_loader.dart';
import '../remote_registry.dart';
import '../../services/ide_tab_opener.dart';






// ═══════════════════════════════════════════════════════════════
// EMBEDDED SECTION (in the store)
// ═══════════════════════════════════════════════════════════════

class PandaRegistrySection extends StatefulWidget {
  const PandaRegistrySection({super.key});

  @override
  State<PandaRegistrySection> createState() => _PandaRegistrySectionState();
}

class _PandaRegistrySectionState extends State<PandaRegistrySection>
    with AutomaticKeepAliveClientMixin {
  RegistryIndex? _index;
  String? _error;
  final Set<String> _installed = {};
  /// Versions actually installed (read from the local panda.yaml) —
  /// enables the "Update" state in VS Code style.
  final Map<String, String> _installedVersions = {};
  final Set<String> _busy = {};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      final support = await getApplicationSupportDirectory().timeout(
          const Duration(seconds: 5),
          onTimeout: () => throw TimeoutException('path_provider'));
      RemoteExtensionRegistry.instance.installRoot =
          Directory('${support.parent.path}/extensions').path;
      await Directory(RemoteExtensionRegistry.instance.installRoot)
          .create(recursive: true);

      // Global timeout: never an infinite spinner
      final index = await RemoteExtensionRegistry.instance
          .fetchIndex()
          .timeout(const Duration(seconds: 20));
      if (!mounted) return;
      setState(() {
        _index = index;
        _error = null;
      });
      for (final e in index.extensions) {
        final ver = await _readInstalledVersion(e.id);
        if (!mounted) return;
        setState(() {
          if (ver != null) {
            _installed.add(e.id);
            _installedVersions[e.id] = ver;
          } else {
            _installed.remove(e.id);
            _installedVersions.remove(e.id);
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// Reads the installed version — panda.yaml (.panda) OR package.json (.vsix).
  Future<String?> _readInstalledVersion(String id) async {
    final root = '\${RemoteExtensionRegistry.instance.installRoot}/\$id';
    // .panda format
    try {
      final f = File('$root/panda.yaml');
      if (await f.exists()) return (await PandaManifest.fromFile(f.path)).version;
    } catch (_) {}
    // .vsix format (package.json)
    try {
      final f = File('$root/package.json');
      if (await f.exists()) {
        final content = await f.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        return json['version']?.toString();
      }
    } catch (_) {}
    // Fallback: if the folder exists and has an entry point, it's installed
    try {
      final dir = Directory(root);
      if (await dir.exists()) {
        final hasEntry = await File('$root/extension.js').exists() ||
            await File('$root/lib/extension.dart').exists();
        if (hasEntry) return '1.0.0';
      }
    } catch (_) {}
    return null;
  }

  Future<void> _install(RegistryEntry entry) async {
    setState(() => _busy.add(entry.id));
    try {
      // Update: unload + purge the old folder first (files
      // deleted between versions should not linger).
      if (_installed.contains(entry.id)) {
        await NativeExtensionLoader.instance.unload(entry.id);
        await RemoteExtensionRegistry.instance.uninstall(entry.id);
      }
      // extensionDependencies (VS Code style): install dependencies
      // first, recursively but without an infinite loop.
      for (final depId in entry.dependencies) {
        if (_installed.contains(depId)) continue;
        RegistryEntry? dep;
        for (final x in _index?.extensions ?? const <RegistryEntry>[]) {
          if (x.id == depId) dep = x;
        }
        if (dep != null) {
          await RemoteExtensionRegistry.instance.install(dep);
        }
      }
      final path = await RemoteExtensionRegistry.instance.install(entry);
      // Detect the format: .vsix (package.json) vs .panda (panda.yaml)
      final isVsix = await File('$path/package.json').exists();
      if (isVsix) {
        //.vsix: load via the Node.js ExtensionHost
        // The extension will be activated on the next startup or via a command
        print('[Marketplace] .vsix extension installed: ${entry.id}');
      } else {
        //.panda: load via the Dart NativeExtensionLoader
        await NativeExtensionLoader.instance.load(path);
      }
      if (!mounted) return;
      setState(() {
        _installed.add(entry.id);
        _installedVersions[entry.id] = entry.latestVersion;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${entry.name} installed 🐼'),
          backgroundColor: Colors.green.shade700));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Failure: $e'),
          backgroundColor: Colors.red.shade700));
    } finally {
      if (mounted) setState(() => _busy.remove(entry.id));
    }
  }

  void _openDevicePanel() {
    // Opens the panel as an IDE tab (no fullscreen Navigator.push).
    IdeTabOpener.instance.openFlutterDevice();
  }

  Future<void> _uninstall(RegistryEntry entry) async {
    setState(() => _busy.add(entry.id));
    try {
      // Ignore unload errors (the .vsix extension is not in the NativeExtensionLoader)
      try { await NativeExtensionLoader.instance.unload(entry.id); } catch (_) {}
      await RemoteExtensionRegistry.instance.uninstall(entry.id);
      if (mounted) {
        setState(() {
          _installed.remove(entry.id);
          _installedVersions.remove(entry.id);
        });
      }
    } finally {
      if (mounted) setState(() => _busy.remove(entry.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final cs = Theme.of(context).colorScheme;

    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Row(children: [
          Icon(Icons.cloud_off_rounded,
              size: 16, color: cs.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text('Registre inaccessible — ${_error!.split('\n').first}',
                style:
                    TextStyle(fontSize: 13, color: cs.error)),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 18),
            onPressed: () {
              setState(() { _error = null; _index = null; });
              _bootstrap();
            },
          ),
        ]),
      );
    }
    if (_index == null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: SizedBox(
            width: 22, height: 22,
            child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }
    final exts = _index!.extensions;
    if (exts.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: cs.outlineVariant.withValues(alpha: .4)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              Icon(Icons.inbox_outlined, size: 32, color: cs.onSurfaceVariant),
              const SizedBox(height: 8),
              Text('The register is empty at the moment',
                  style: TextStyle(fontWeight: FontWeight.w600, color: cs.onSurface)),
              const SizedBox(height: 4),
              Text('Check your connection and then try again.',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Try Again'),
                onPressed: () {
                  setState(() { _index = null; _error = null; });
                  _bootstrap();
                },
              ),
            ]),
          ),
        ),
      );
    }
    return Column(
      children: [
        for (final e in exts) _buildCard(e, Theme.of(context).colorScheme),
      ],
    );
  }

  Widget _buildCard(RegistryEntry e, ColorScheme cs) {
    final isInstalled = _installed.contains(e.id);
    final isBusy = _busy.contains(e.id);
    final installedVer = _installedVersions[e.id];
    // Status "update available" as the marketplace VS Code:
    // The remote version is strictly more recent than the installed one.
    final needsUpdate = isInstalled &&
        installedVer != null &&
        RegistryEntry.isNewer(e.latestVersion, installedVer);
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: cs.outlineVariant.withValues(alpha: .4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: e.iconUrl != null
                  ? Image.network(e.iconUrl!,
                      width: 46,
                      height: 46,
                      errorBuilder: (_, _, _) => Container(
                          width: 46,
                          height: 46,
                          color: cs.primaryContainer,
                          child: Icon(Icons.extension,
                              color: cs.onPrimaryContainer)))
                  : Container(
                      width: 46,
                      height: 46,
                      color: cs.primaryContainer,
                      child: Icon(Icons.extension,
                          color: cs.onPrimaryContainer)),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(child: Text(e.name,
                        style: const TextStyle(fontWeight: FontWeight.w600))),
                    if (e.featured) ...[
                      const SizedBox(width: 6),
                      Icon(Icons.star_rounded, size: 15, color: Colors.amber),
                    ],
                  ]),
                  Text('${e.latestVersion.isNotEmpty ? e.latestVersion : e.version} · ${e.author ?? 'anonyme'}',
                      style: TextStyle(
                          fontSize: 12, color: cs.onSurfaceVariant)),
                ])),
          ]),
          const SizedBox(height: 10),
          Text(e.description,
              style: const TextStyle(fontSize: 13, height: 1.35)),
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final perm in e.permissions.take(5))
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest.withValues(alpha: .5),
                    borderRadius: BorderRadius.circular(20)),
                child: Text(perm,
                    style: TextStyle(
                        fontSize: 11, color: cs.onSurfaceVariant)),
              ),
          ]),
          const SizedBox(height: 12),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            if (!isBusy && isInstalled) ...[
              FilledButton.tonalIcon(
                icon: const Icon(Icons.play_arrow_rounded, size: 18),
                label: const Text('Open'),
                onPressed: _openDevicePanel,
              ),
              const SizedBox(width: 8),
            ],
            if (isBusy)
              const SizedBox(width: 18, height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
            else ...[
              if (needsUpdate)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text('\$installedVer → \${e.latestVersion}',
                      style: TextStyle(
                          fontSize: 11, color: cs.onSurfaceVariant)),
                ),
              FilledButton.icon(
                icon: Icon(
                    needsUpdate
                        ? Icons.update_rounded
                        : isInstalled
                            ? Icons.delete_outline
                            : Icons.download_rounded,
                    size: 17),
                label: Text(needsUpdate
                    ? 'Update'
                    : isInstalled
                        ? 'Uninstall'
                        : 'Installer'),
                style: FilledButton.styleFrom(
                  backgroundColor:
                      needsUpdate ? Colors.green.shade700 : null,
                  foregroundColor: isInstalled && !needsUpdate
                      ? cs.error
                      : cs.onPrimary,
                ),
                onPressed: () =>
                    needsUpdate || !isInstalled ? _install(e) : _uninstall(e),
              ),
            ],
          ]),
        ]),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// STANDALONE PAGE (direct route — kept for compatibility)
// ═══════════════════════════════════════════════════════════════

class PandaRegistryPage extends StatelessWidget {
  const PandaRegistryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Extensions Panda')),
      body: const SingleChildScrollView(child: PandaRegistrySection()),
    );
  }
}
