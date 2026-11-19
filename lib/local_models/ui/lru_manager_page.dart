/// LruManagerPage — LRU Cache management interface for models.
///
/// Displays installed models sorted by last used,
/// allows you to see the space used, and to start a manual or automatic cleaning.
library;
import 'dart:async';
import 'package:material_ui/material_ui.dart';
import '../models/ai_model_entry.dart';
import '../services/catalog_service.dart';
import '../services/lru_cache_service.dart';
import '../services/model_download_manager.dart';



// ══════════════════════════════════════════════════════════════════════════════
// LruManagerPage
// ══════════════════════════════════════════════════════════════════════════════

class LruManagerPage extends StatefulWidget {
  const LruManagerPage({super.key});

  @override
  State<LruManagerPage> createState() => _LruManagerPageState();
}

class _LruManagerPageState extends State<LruManagerPage> {
  List<LruCandidate>  _candidates   = [];
  ModelCatalog?       _catalog;
  bool                _loading      = true;
  bool                _cleaning     = false;
  LruSettings         _settings     = const LruSettings();
  final Set<String>   _selected     = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; });
    try {
      await Future.wait([
        LruCacheService.instance.loadSettings(),
        ModelDownloadManager.instance.init(),
        CatalogService.load().then((c) => _catalog = c),
      ]);
      _settings   = LruCacheService.instance.settings;
      _candidates = LruCacheService.instance.getCandidates();
    } finally {
      if (mounted) setState(() { _loading = false; });
    }
  }

  // ── Nettoyage ─────────────────────────────────────────────────────────────

  Future<void> _cleanSelected() async {
    if (_selected.isEmpty) return;
    final toDelete = _candidates
        .where((c) => _selected.contains(_key(c)))
        .toList();

    final confirm = await _showConfirmDialog(toDelete);
    if (!confirm) return;

    setState(() => _cleaning = true);
    try {
      final result =
          await LruCacheService.instance.cleanupSelected(toDelete);
      _selected.clear();
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            '${result.deletedCount} model(s) deleted'
            '(${result.freedGb.toStringAsFixed(1)} GB freed)'),
          duration: const Duration(seconds: 3),
        ));
      }
    } finally {
      if (mounted) setState(() => _cleaning = false);
    }
  }

  Future<void> _autoCleanup() async {
    setState(() => _cleaning = true);
    try {
      final result = await LruCacheService.instance.runAutoCleanup();
      await _load();
      if (mounted) {
        if (result == null) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Sufficient space — no cleaning required'),
          ));
        } else if (!result.anyDeleted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('No models eligible for cleanup'),
          ));
        } else {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
              '${result.deletedCount} model(s) deleted'
              '(${result.freedGb.toStringAsFixed(1)} GB freed)'),
          ));
        }
      }
    } finally {
      if (mounted) setState(() => _cleaning = false);
    }
  }

  // ── Settings LRU ─────────────────────────────────────────────────────────

  Future<void> _editSettings() async {
    final result = await showDialog<LruSettings>(
      context: context,
      builder: (_) => _LruSettingsDialog(initial: _settings),
    );
    if (result != null) {
      await LruCacheService.instance.saveSettings(result);
      setState(() { _settings = result; });
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs   = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: dark ? const Color(0xff1e1e1e) : const Color(0xfff5f5f5),
      appBar: AppBar(
        backgroundColor: dark ? const Color(0xff252526) : Colors.white,
        elevation: 0,
        titleSpacing: 0,
        title: Text(
          'Storage Management',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: cs.onSurface,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined, size: 18),
            onPressed: _editSettings,
            tooltip: 'LRU Parameters',
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 18),
            onPressed: _load,
            tooltip: 'Actualiser',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _buildStorageSummary(cs, dark),
                if (_candidates.isNotEmpty) _buildActions(cs, dark),
                Expanded(
                  child: _candidates.isEmpty
                      ? _buildEmpty(cs)
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 80),
                          itemCount: _candidates.length,
                          itemBuilder: (_, i) =>
                              _buildCard(_candidates[i], cs, dark),
                        ),
                ),
              ],
            ),
      floatingActionButton: _selected.isNotEmpty
          ? FloatingActionButton.extended(
              onPressed: _cleaning ? null : _cleanSelected,
              backgroundColor: cs.error,
              icon: _cleaning
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.delete_outline, color: Colors.white),
              label: Text(
                'Delete (${_selected.length})',
                style: const TextStyle(color: Colors.white),
              ),
            )
          : null,
    );
  }

  // ── Storage Summary ─────────────────────────────────────────────────────────────

  Widget _buildStorageSummary(ColorScheme cs, bool dark) {
    final totalGb = LruCacheService.instance.totalInstalledGb;
    final count   = LruCacheService.instance.totalInstalledCount;
    return Container(
      margin:  const EdgeInsets.all(12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color:        dark ? const Color(0xff252526) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border:       Border.all(color: cs.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          _infoChip(
            cs, '💾', '$count model${count > 1 ? "s" : ""} installed${count > 1 ? "s" : ""}',
          ),
          const SizedBox(width: 12),
          _infoChip(cs, '📦', '${totalGb.toStringAsFixed(1)} GB used'),
          const Spacer(),
          OutlinedButton.icon(
            onPressed: _cleaning ? null : _autoCleanup,
            icon: const Icon(Icons.auto_delete_outlined, size: 14),
            label: const Text('Auto-cleanup', style: TextStyle(fontSize: 12)),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoChip(ColorScheme cs, String emoji, String label) => Row(
    children: [
      Text(emoji, style: const TextStyle(fontSize: 16)),
      const SizedBox(width: 6),
      Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: cs.onSurface,
        ),
      ),
    ],
  );

  // ── Barre d'actions ───────────────────────────────────────────────────────

  Widget _buildActions(ColorScheme cs, bool dark) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
    child: Row(
      children: [
        TextButton(
          onPressed: () => setState(() {
            if (_selected.length == _candidates.length) {
              _selected.clear();
            } else {
              _selected.addAll(_candidates.map(_key));
            }
          }),
          child: Text(
            _selected.length == _candidates.length ? 'Deselect all' : 'Select all',
            style: TextStyle(fontSize: 12, color: cs.primary),
          ),
        ),
        const Spacer(),
        Text(
          '${_candidates.where((c) => c.isEligible).length} eligible for cleaning',
          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
        ),
      ],
    ),
  );

  // ── Template Card ──────────────────────────────────────────────────────────────────

  Widget _buildCard(LruCandidate c, ColorScheme cs, bool dark) {
    final key      = _key(c);
    final selected = _selected.contains(key);
    final entry    = _catalog?.models.where((m) => m.id == c.model.modelId)
        .firstOrNull;

    return GestureDetector(
      onTap: () => setState(() {
        if (selected) {
          _selected.remove(key);
        } else {
          _selected.add(key);
        }
      }),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin:  const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected
              ? cs.errorContainer.withValues(alpha: 0.3)
              : dark ? const Color(0xff252526) : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? cs.error.withValues(alpha: 0.5)
                : c.isEligible
                    ? cs.error.withValues(alpha: 0.2)
                    : cs.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
        child: Row(
          children: [
            // Checkbox
            Checkbox(
              value:   selected,
              onChanged: (v) => setState(() {
                if (v == true) {
                  _selected.add(key);
                } else {
                  _selected.remove(key);
                }
              }),
            ),
            const SizedBox(width: 4),
            // Icon
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                color:        cs.primaryContainer.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.smart_toy_outlined, size: 18, color: cs.primary),
            ),
            const SizedBox(width: 12),
            // Infos
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry?.name ?? c.model.modelId,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: cs.onSurface,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${c.model.quantLevel}  ·  ${c.sizeLabel}',
                    style: TextStyle(
                      fontSize: 11,
                      color: cs.onSurfaceVariant,
                      fontFamily: 'firaCode',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Badge LRU
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  c.sizeLabel,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: c.isEligible
                        ? cs.errorContainer
                        : cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    c.lastUsedLabel,
                    style: TextStyle(
                      fontSize: 9,
                      color: c.isEligible ? cs.error : cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty(ColorScheme cs) => Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.inventory_2_outlined, size: 48, color: cs.onSurfaceVariant),
        const SizedBox(height: 12),
        Text(
          'No model installed',
          style: TextStyle(
              fontSize: 14, color: cs.onSurfaceVariant),
        ),
      ],
    ),
  );

  // ── Dialog confirmation ───────────────────────────────────────────────────

  Future<bool> _showConfirmDialog(List<LruCandidate> toDelete) async {
    final cs   = Theme.of(context).colorScheme;
    final totalGb = toDelete.fold(0.0, (s, c) => s + c.model.sizeGb);
    return await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete the templates?'),
        content: Text(
          'You are about to delete ${toDelete.length} model(s)'
          '(${totalGb.toStringAsFixed(1)} GB).\n\n'
          'This action is irreversible.'
          'You will be able to re-download them from the marketplace.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: cs.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    ) ?? false;
  }

  static String _key(LruCandidate c) => '${c.model.modelId}/${c.model.quantLevel}';
}

// ── Dialog Settings LRU ───────────────────────────────────────────────────────

class _LruSettingsDialog extends StatefulWidget {
  final LruSettings initial;
  const _LruSettingsDialog({required this.initial});

  @override
  State<_LruSettingsDialog> createState() => _LruSettingsDialogState();
}

class _LruSettingsDialogState extends State<_LruSettingsDialog> {
  late LruSettings _s;

  @override
  void initState() {
    super.initState();
    _s = widget.initial;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('LRU cache settings'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Auto cleanup toggle
        SwitchListTile(
          title: const Text('Nettoyage automatique', style: TextStyle(fontSize: 13)),
          subtitle: const Text('Deletes old templates if space is lacking',
              style: TextStyle(fontSize: 11)),
          value:    _s.autoCleanupEnabled,
          onChanged: (v) => setState(() { _s = _s.copyWith(autoCleanupEnabled: v); }),
          dense: true,
        ),
        const SizedBox(height: 8),

        // Jours
        Row(children: [
          const Expanded(child: Text(
            'Days before eligibility',
            style: TextStyle(fontSize: 13),
          )),
          Text('${_s.maxDaysUnused} j',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ]),
        Slider(
          value:   _s.maxDaysUnused.toDouble(),
          min:     7, max: 90, divisions: 11,
          label:   '${_s.maxDaysUnused} jours',
          onChanged: (v) =>
              setState(() { _s = _s.copyWith(maxDaysUnused: v.round()); }),
        ),
        const SizedBox(height: 8),

        // Seuil
        Row(children: [
          const Expanded(child: Text(
            'Free storage threshold (GB)',
            style: TextStyle(fontSize: 13),
          )),
          Text('${_s.cleanupThresholdGb.toStringAsFixed(1)} GB',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ]),
        Slider(
          value:     _s.cleanupThresholdGb,
          min:       0.5, max: 10.0, divisions: 19,
          label:     '${_s.cleanupThresholdGb.toStringAsFixed(1)} GB',
          onChanged: (v) =>
              setState(() { _s = _s.copyWith(cleanupThresholdGb: v); }),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Annuler'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _s),
        child: const Text('Save'),
      ),
    ],
  );
}
