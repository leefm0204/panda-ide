/// ModelSelectorService — Automatic model selection according to the IDE task.
///
/// Chooses the best installed model according to the usage context:
///   • code_completion  → coding_score max, tool_calling optionnel
///   • agent_chat       → tool_calling + reasoning
///   • vision_analysis  → vision: true
///   • math_reasoning   → reasoning: true, coding_score >= 3
/// • general_chat → generalist model, balanced size
///
/// Fallback: if no installed model is perfect, returns the best available.
library;
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/ai_model_entry.dart';
import '../services/catalog_service.dart';
import '../services/model_download_manager.dart';



// ── IDE Task Types ─────────────────────────────────────────────────────────────

enum IdeTask {
  codeCompletion,  // inline completion in the editor
  agentChat,       // chat with standalone agent (tool calling)
  visionAnalysis,  // Image/Screenshot Analysis
  mathReasoning,   // mathematical reasoning
  generalChat,     // General chat, questions/answers
  codeReview,      // code review, explanation
  debugAssistance, // debugging assistance
}

extension IdleTaskLabel on IdeTask {
  String get label {
    switch (this) {
      case IdeTask.codeCompletion:  return 'Code completion';
      case IdeTask.agentChat:       return 'Agent autonome';
      case IdeTask.visionAnalysis:  return 'Analyse d\'image';
      case IdeTask.mathReasoning:   return 'Raisonnement maths';
      case IdeTask.generalChat:     return 'General Chat';
      case IdeTask.codeReview:      return 'Code review';
      case IdeTask.debugAssistance: return 'Debug assistance';
    }
  }

  String get emoji {
    switch (this) {
      case IdeTask.codeCompletion:  return '⌨️';
      case IdeTask.agentChat:       return '🤖';
      case IdeTask.visionAnalysis:  return '👁️';
      case IdeTask.mathReasoning:   return '🧮';
      case IdeTask.generalChat:     return '💬';
      case IdeTask.codeReview:      return '🔍';
      case IdeTask.debugAssistance: return '🐛';
    }
  }
}

// ── Selection Result ──────────────────────────────────────────────────────

class ModelSelectionResult {
  final AiModelEntry? model;
  final InstalledModel? installed;
  final String          quantLevel;
  final double          score;       // Matching score 0-100
  final String          reason;      // Explication lisible
  final bool            isInstalled; // false if no model is installed

  const ModelSelectionResult({
    required this.model,
    required this.installed,
    required this.quantLevel,
    required this.score,
    required this.reason,
    required this.isInstalled,
  });

  /// No model available.
  static const ModelSelectionResult none = ModelSelectionResult(
    model:       null,
    installed:   null,
    quantLevel:  '',
    score:       0,
    reason:      'No model installed',
    isInstalled: false,
  );

  /// aiConfig ID of the selected model (LocalLlama-... format)
  String get aiConfigId {
    if (model == null) return '';
    return 'LocalLlama-${model!.id}-${quantLevel.replaceAll("_", "").toLowerCase()}';
  }
}

// ── Service ───────────────────────────────────────────────────────────────────

class ModelSelectorService {

  /// Selects the best installed model for a given task.
  ///
  /// [task] — IDE task type
  /// [catalog] — current catalog (optional, loaded automatically if null)
  static Future<ModelSelectionResult> selectFor({
    required IdeTask       task,
    ModelCatalog?          catalog,
  }) async {
    catalog ??= await CatalogService.load();
    await ModelDownloadManager.instance.init();

    final installed = ModelDownloadManager.instance.allInstalled;
    if (installed.isEmpty) return ModelSelectionResult.none;

    // Retrieves the information for the installed models
    final candidates = <_Candidate>[];
    for (final inst in installed) {
      final entry = _findEntry(catalog, inst.modelId);
      if (entry == null) continue;
      final score = _scoreForTask(entry, inst, task);
      candidates.add(_Candidate(entry: entry, installed: inst, score: score));
    }

    if (candidates.isEmpty) return ModelSelectionResult.none;

    // Sort by score descending
    candidates.sort((a, b) => b.score.compareTo(a.score));
    final best = candidates.first;

    return ModelSelectionResult(
      model:       best.entry,
      installed:   best.installed,
      quantLevel:  best.installed.quantLevel,
      score:       best.score,
      reason:      _reason(best.entry, task, best.score),
      isInstalled: true,
    );
  }

  /// Saves the selected template as the default for a task in the preferences.
  static Future<void> setDefaultForTask(
      IdeTask task, ModelSelectionResult result) async {
    if (!result.isInstalled) return;
    final prefs   = await SharedPreferences.getInstance();
    final raw     = prefs.getString('panda_task_model_defaults') ?? '{}';
    final Map<String, dynamic> map =
        Map<String, dynamic>.from(jsonDecode(raw) as Map);
    map[task.name] = result.aiConfigId;
    await prefs.setString('panda_task_model_defaults', jsonEncode(map));
  }

  /// Retrieves the manual override for a task (if the user has forced a pattern).
  static Future<String?> getOverrideForTask(IdeTask task) async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString('panda_task_model_defaults') ?? '{}';
    final map   = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    return map[task.name] as String?;
  }

  /// Returns the best model for each IDE task (overall summary).
  static Future<Map<IdeTask, ModelSelectionResult>> selectAll(
      ModelCatalog catalog) async {
    final results = <IdeTask, ModelSelectionResult>{};
    await Future.wait(IdeTask.values.map((task) async {
      results[task] = await selectFor(task: task, catalog: catalog);
    }));
    return results;
  }

  // ── Scoring ───────────────────────────────────────────────────────────────

  static double _scoreForTask(AiModelEntry entry, InstalledModel inst, IdeTask task) {
    double score = 0;
    final caps   = entry.capabilities;

    switch (task) {
      case IdeTask.codeCompletion:
        score += caps.codingScore * 15.0;          // coding ×15 (0-75)
        if (!caps.vision) score += 10;             // visual lightness bonus
        if (entry.quantizations.any((q) => q.level == inst.quantLevel && q.sizeGb < 3.0)) {
          score += 10;                             // bonus lightweight model = fast
        }
        break;

      case IdeTask.agentChat:
        if (caps.toolCalling)  score += 40;
        if (caps.reasoning)    score += 20;
        score += caps.codingScore * 5.0;
        break;

      case IdeTask.visionAnalysis:
        if (caps.vision) score += 80;
        score += caps.codingScore * 4.0;
        break;

      case IdeTask.mathReasoning:
        if (caps.reasoning)   score += 50;
        score += caps.codingScore * 5.0;
        if (caps.toolCalling) score += 10;
        break;

      case IdeTask.generalChat:
        score += 30; // base for any model
        if (caps.contextLength >= 32768) score += 20;
        if (!caps.vision) score += 10;             // vision = overhead inutile
        score += caps.codingScore * 3.0;
        break;

      case IdeTask.codeReview:
        score += caps.codingScore * 16.0;          // coding ×16 (0-80)
        if (caps.contextLength >= 32768) score += 15;
        if (caps.reasoning) score += 5;
        break;

      case IdeTask.debugAssistance:
        score += caps.codingScore * 12.0;
        if (caps.reasoning)  score += 20;
        if (caps.toolCalling) score += 10;
        if (caps.vision)     score += 8;           // can analyze screenshot
        break;
    }

    // LRU Bonus: prefers recently used models (slight preference)
    final daysSince = DateTime.now().difference(inst.lastUsedAt).inDays;
    if (daysSince < 7) score += 5;

    return score.clamp(0, 100);
  }

  static String _reason(AiModelEntry entry, IdeTask task, double score) {
    final caps = entry.capabilities;
    final parts = <String>[];
    switch (task) {
      case IdeTask.codeCompletion:
        parts.add('coding ${caps.codingScore}/5');
        break;
      case IdeTask.agentChat:
        if (caps.toolCalling) parts.add('tool calling ✓');
        if (caps.reasoning)   parts.add('reasoning ✓');
        break;
      case IdeTask.visionAnalysis:
        if (caps.vision) parts.add('vision ✓');
        break;
      case IdeTask.mathReasoning:
        if (caps.reasoning) parts.add('reasoning ✓');
        break;
      default:
        parts.add('score ${score.toInt()}/100');
    }
    return '${entry.name} — ${parts.join(", ")}';
  }

  static AiModelEntry? _findEntry(ModelCatalog catalog, String modelId) {
    try {
      return catalog.models.firstWhere((m) => m.id == modelId);
    } catch (_) {
      return null;
    }
  }
}

// ── Interne ───────────────────────────────────────────────────────────────────

class _Candidate {
  final AiModelEntry  entry;
  final InstalledModel installed;
  final double         score;
  const _Candidate({
    required this.entry,
    required this.installed,
    required this.score,
  });
}
