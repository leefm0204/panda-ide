/// AgentRunner — streaming AI runner for Panda Agent.
///
/// Supports all existing providers (Gemini, OpenAI, Claude, OpenAI-compat,
/// LocalLlama) as well as the "thinking" states (Claude extended thinking,
/// o1/o3 reasoning_content, Gemini thinking models).
///
/// Also supports tool calling: when a BuildContext and a workspacePath
/// are provided, the agent can execute shell commands, read/write files, etc.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

import '../bloc/ui_bloc/ui_bloc.dart';
import '../utils/ai.dart';
import '../utils/llama_wrapper.dart';
import '../agent/events/agent_event.dart';
import '../agent/events/agent_event_bus.dart';
import '../utils/agentic_tools.dart';
import '../utils/panda_log.dart';
import '../terminal/terminal_bridge.dart';
import '../utils/pandarules_service.dart';
import '../utils/agent_settings_service.dart';
import '../agent/tools/tool_registry.dart';
import '../agent/tools/tool_executor.dart';
import '../agent/tools/native_tool_bridge.dart';
import '../agent/context/context_manager.dart';
import '../agent/sessions/session_manager.dart';
import '../agent/runtime/retry_manager.dart';
import '../agent/runtime/error_classifier.dart';
import '../agent/agents/agent_registry.dart';
import '../agent/modes/mode_registry.dart';
import '../agent/events/event_activity_bridge.dart';

import '../agent/subagents/subagent_manager.dart';
import '../agent/context/history_compactor.dart';
import '../agent/context/code_map.dart';
import '../agent/verification/verification_pipeline.dart';

import '../agent/mcp/mcp_tool_bridge.dart';


// ─────────────────────────────────────────────────────────────────────────────
// AgentPhase — agent state machine
// ─────────────────────────────────────────────────────────────────────────────

enum AgentPhase {
  idle,        // waiting for a message
  thinking,    // the "reflects" model (extended thinking / reasoning)
  toolRunning, // a tool is running
  toolDone,    // A tool has just finished (result available)
  streaming,   // text being generated
  done,        // full answer
  error,       // network or parsing error
}

// ─────────────────────────────────────────────────────────────────────────────
// AgentChunk — unit issued by the stream
// ─────────────────────────────────────────────────────────────────────────────

class AgentChunk {
  final AgentPhase phase;
  final String text;
  /// Tool name (toolRunning / toolDone)
  final String? toolName;
  /// Arguments passed to the tool (toolRunning)
  final Map<String, dynamic>? toolArgs;
  /// Result returned by the tool (toolDone)
  final String? toolResult;
  /// Chronological block identifier (reflection / text / tools).
  /// Allows the UI to display the steps in the correct order instead of everything
  /// stack the thinking on top and the tools in the middle.
  final int? blockId;
  const AgentChunk({
    required this.phase,
    this.text = '',
    this.toolName,
    this.toolArgs,
    this.toolResult,
    this.blockId,
  });
}

/// Time-block sequencer shared by both runners.
/// A new block is opened as soon as the event type changes
/// (thinking → text → tools → text…), which restores the actual sequence.
class _BlockSequencer {
  int _seq = -1;
  String _lastKind = '';

  int next(String kind) {
    if (kind != _lastKind) {
      _seq += 1;
      _lastKind = kind;
    }
    return _seq;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// AgentRunner
// ─────────────────────────────────────────────────────────────────────────────

class AgentRunner {
  http.Client? _client;
  AgenticTools? _activeTools;

  /// V3 agent components
  final ToolRegistry toolRegistry = ToolRegistry();
  late final ToolExecutor toolExecutor;
  final ContextManager contextManager = ContextManager();
  final SessionManager sessionManager = SessionManager();
  final RetryManager retryManager = RetryManager();
  final ErrorClassifier errorClassifier = ErrorClassifier();
  final AgentRegistry agentRegistry = AgentRegistry();
  final ModeRegistry modeRegistry = ModeRegistry();
  SubagentManager? subagentManager;
  McpToolBridge? mcpToolBridge;
  EventActivityBridge? activityBridge;

  final AgentEventBus _eventBus = AgentEventBus();

  AgentRunner() {
    toolExecutor = ToolExecutor(
      registry: toolRegistry,
      eventBus: _eventBus,
    );
  }

  void cancel() {
    try {
      _client?.close();
      _client = null;
      _activeTools?.interrupt();
      _activeTools = null;
    } catch (_) {}
  }

  Stream<AgentChunk> run({
    required Models model,
    required List<Map<String, dynamic>> messages,
    BuildContext? context,
    String workspacePath = '',
    String agentMode = 'agent',
    String? systemPromptOverride,
    AgentConfirmCallback? onConfirmRequired,
    String approvalMode = 'default',
    AgentIdeControlCallback? onIdeControl,
    AgentEventBus? eventBus,
  }) {
    final ctrl = StreamController<AgentChunk>();
    _run(
      model: model,
      messages: messages,
      systemPromptOverride: systemPromptOverride,
      ctrl: ctrl,
      context: context,
      workspacePath: workspacePath,
      agentMode: agentMode,
      onConfirmRequired: onConfirmRequired,
      approvalMode: approvalMode,
      onIdeControl: onIdeControl,
      eventBus: eventBus,
    );
    return ctrl.stream;
  }

  /// Dynamically generates the system prompt from the actual project context.
  /// Called in [_run] after the toolSchemas are known.
  static Future<String> _buildSystemPrompt(
    String workspacePath,
    List<Map<String, dynamic>> toolSchemas, {
    String agentMode = "agent",
  }) async {
    final StringBuffer projectSection = StringBuffer();
    final StringBuffer repoSection   = StringBuffer();

    if (workspacePath.isNotEmpty) {
      final dir = Directory(workspacePath);
      if (dir.existsSync()) {
        final projectName = path.basename(workspacePath);
        String projectType = 'Inconnu';
        String extraCtx = '';
        if (File('$workspacePath/pubspec.yaml').existsSync()) {
          projectType = 'Flutter / Dart';
          extraCtx = 'To compile: `flutter build apk`. For testing: `flutter test`.';
        } else if (File('$workspacePath/package.json').existsSync()) {
          projectType = 'Node.js / TypeScript';
          extraCtx = 'To install: `npm install`. To start: `npm run dev`.';
        } else if (File('$workspacePath/Cargo.toml').existsSync()) {
          projectType = 'Rust';
          extraCtx = 'To compile: `cargo build`. For testing: `cargo test`.';
        } else if (File('$workspacePath/go.mod').existsSync()) {
          projectType = 'Go';
          extraCtx = 'To compile: `go build ./...`. For testing: `go test ./...`.';
        } else if (File('$workspacePath/pom.xml').existsSync() ||
                   File('$workspacePath/build.gradle').existsSync()) {
          projectType = 'Java / Android';
          extraCtx = 'To compile: `./gradlew build`.';
        } else if (File('$workspacePath/requirements.txt').existsSync() ||
                   File('$workspacePath/pyproject.toml').existsSync()) {
          projectType = 'Python';
          extraCtx = 'To install: `pip install -r requirements.txt`. To start: `python main.py`.';
        }

        projectSection
          ..writeln('## OPEN PROJECT')
          ..writeln('Nom : $projectName')
          ..writeln('Type : $projectType')
          ..writeln('Path: $workspacePath')
          ..writeln(extraCtx);

        // V3 CodeMap: analyze code structure
        try {
          final codeStructure = await CodeMap.analyze(workspacePath);
          if (codeStructure.classes.isNotEmpty || codeStructure.functions.isNotEmpty) {
            projectSection
              ..writeln()
              ..writeln(codeStructure.toContextString());
          }
        } catch (_) {}

        try {
          final entries = dir
              .listSync(followLinks: false)
              .where((e) {
                final n = path.basename(e.path);
                return !n.startsWith('.') &&
                    n != 'build' &&
                    n != '.dart_tool' &&
                    n != 'node_modules' &&
                    n != '__pycache__' &&
                    n != 'target';
              })
              .toList()
            ..sort((a, b) {
              final aIsDir = a is Directory;
              final bIsDir = b is Directory;
              if (aIsDir && !bIsDir) return -1;
              if (!aIsDir && bIsDir) return 1;
              return path.basename(a.path).compareTo(path.basename(b.path));
            });

          repoSection.writeln('## PROJECT STRUCTURE');
          repoSection.writeln('```');
          for (final entry in entries.take(25)) {
            final name = path.basename(entry.path);
            if (entry is Directory) {
              repoSection.writeln('📁 $name/');
              try {
                final subEntries = Directory(entry.path)
                    .listSync(followLinks: false)
                    .where((e) => !path.basename(e.path).startsWith('.'))
                    .toList()
                  ..sort((a, b) =>
                      path.basename(a.path).compareTo(path.basename(b.path)));
                for (final sub in subEntries.take(12)) {
                  final subName = path.basename(sub.path);
                  final icon = sub is Directory ? '📁' : '📄';
                  repoSection.writeln('   $icon $subName');
                }
                if (subEntries.length > 12) {
                  repoSection.writeln('   … (${subEntries.length - 12} more)');
                }
              } catch (_) {}
            } else {
              repoSection.writeln('📄 $name');
            }
          }
          if (entries.length > 25) {
            repoSection.writeln('... (${entries.length - 25} other entries)');
          }
          repoSection.writeln('```');
        } catch (_) {}
      }
    }

    final toolLines = toolSchemas
        .map((t) {
          final fn = t['function'];
          if (fn is! Map) return null;
          final name = fn['name']?.toString() ?? '';
          final desc = fn['description']?.toString() ?? '';
          final params = fn['parameters'];
          final required = (params is Map)
              ? ((params['required'] as List?)?.join(', ') ?? '')
              : '';
          final suffix = required.isNotEmpty ? ' [requis: $required]' : '';
          return '  • **$name**$suffix — $desc';
        })
        .whereType<String>()
        .join('\n');

    String customPrompt = '';
    String customRules  = '';
    Map<String, String> secretsMap = {};
    List<String> activeSkills      = [];
    String? projectRules;
    String memoryContent = '';
    try {
      customPrompt = await AgentSettingsService.getCustomPrompt();
      customRules  = await AgentSettingsService.getCustomRules();
      secretsMap   = await AgentSettingsService.getSecrets();
      activeSkills = await AgentSettingsService.getSkills();
      projectRules = await PandaRulesService.loadRules(workspacePath);
      final memFile = File('$workspacePath/.panda/memory.md');
      if (await memFile.exists()) {
        memoryContent = await memFile.readAsString();
      }
    } catch (_) {}

    final String modeInstructions;
    if (agentMode == 'ask') {
      modeInstructions = '''====
## ASK MODE ACTIVE (QUESTIONS & ANSWERS)
- You are currently in ASK MODE (Discussion and explanations).
- In Ask Mode, you do not execute ANY tools or ANY shell commands.
- You must respond directly to the user in a pedagogical, clear and concise manner in French.
- Provides conceptual explanations and perfectly formatted Markdown code examples.
- If the user requests to perform code modifications, installations or shell commands (e.g. clone, git push, build), indicate the procedure to follow and prompt them to switch to AGENT MODE.''';
    } else if (agentMode == 'plan') {
      modeInstructions = '''====
## ACTIVE PLAN MODE (STEP-BY-STEP PLANNING)
- You are currently in MAP MODE.
- Your role is to discuss with the user to understand their needs, analyze the project with your read-only tools, and propose a detailed implementation plan.
- You CANNOT create, modify or delete files directly, nor execute shell commands in Plane Mode.
- When the plan is ready and complete, write it clearly and in a structured way in Markdown format with subheadings and checkboxes `- [ ] Task`.
- Includes the special tag `<plan> ...</plan> around the final plan. Example:
<plan>
# 📋 Implementation Plan: [Feature/Project Name]

## 🎯 Objectif
[Concise description of the objective]

## 📐 Choix techniques & Architecture
- ...

## 📝 Task List
- [ ] **Task 1**: ...
- [ ] **Task 2**: ...
- [ ] **Task 3**: ...
</plan>
The interface will automatically display an interactive map with buttons to approve the plan and switch directly to Agent Mode to start coding!''';
    } else {
      modeInstructions = '''====
## ACTIVE AGENT MODE (AUTONOMY AND CODE EDITING)
- You are in AGENT MODE (Total autonomy).
- You have full powers to create, modify, delete files, execute shell commands, manage dependencies and make Git commits.
- If a plan has been previously validated (in `.panda/plan.md` or in the chat), execute it methodically step by step, ticking off completed tasks as you go.''';
    }

    final String customSection = customPrompt.trim().isNotEmpty
        ? '\n====\n## CUSTOM USER INSTRUCTIONS\n${customPrompt.trim()}\n'
        : '';

    final String userRulesSection = customRules.trim().isNotEmpty
        ? '\n====\n## USER CUSTOM RULES\n${customRules.trim()}\n'
        : '';

    final String rulesSection = (projectRules != null && projectRules.trim().isNotEmpty)
        ? '\n====\n## PROJECT RULES (.pandarules)\n${projectRules.trim()}\n'
        : '';

    final String memorySection = memoryContent.trim().isNotEmpty
        ? '\n====\n## PROJECT MEMORY (.panda/memory.md)\n${memoryContent.trim()}\n'
        : '';

    final String secretsSection = secretsMap.isNotEmpty
        ? '\n====\n## AVAILABLE ENVIRONMENT SECRETS\nConfigured secrets: ${secretsMap.keys.join(', ')}\n'
        : '';

    final String skillsSection = activeSkills.isNotEmpty
        ? '\n====\n## ACTIVATED SKILLS\n${activeSkills.map((s) => '• $s').join('\n')}\n'
        : '';

    return '''You are the Panda IDE integrated development agent.
You possess in-depth expertise in numerous languages, frameworks, design patterns, and engineering tools.
You are working in a complete IDE environment (web / mobile) with a PTY terminal, a file manager and development tools.

$modeInstructions
$customSection
$userRulesSection
$rulesSection
$memorySection
$secretsSection
$skillsSection

${projectSection.isNotEmpty ? projectSection.toString() : ''}
${repoSection.isNotEmpty ? repoSection.toString() : ''}

====
## USE OF TOOLS
You have a set of tools that you must use to accomplish the tasks.
Each tool call is executed immediately and you receive its result before continuing.
Uses **one tool at a time**, iteratively — each call being informed by the result of the previous one.

### Outils disponibles (${toolSchemas.length})
$toolLines

====
## ABSOLUTE RULES
1. **Act, do not describe.** When a tool is needed, call it and then briefly summarize its result.
2. **readFile required before editFile.** Never invent the contents of a file that has not been read.
3. **Follow the necessary steps** until a verifiable result is obtained, without restarting a previous request.
4. **After each tool**, use its actual result to decide on the next step.
5. **Dangerous or destructive tools** must wait for user approval.
6. **Never reveal private reasoning.** Visible events are short statuses: analyze, read, modify, command, or result.
7. **Do not add decorative prefixes, emojis, or repetitive greetings** to replies.
8. **In Ask Mode**, it does not execute any shell commands and does not modify any files. It simply explains the process.

====
## RESPONSE FORMAT AND STYLE
- **Language:** responds in the user's language (French if French).
- **Ton :** direct, professionnel, sans fioritures.
- **Code:** always in ```language blocks.
- **Actions:** Announce in 1 short sentence what you are doing, then do it immediately.
- **User Progress:** Before each tool, write a short sentence for the user (e.g., "Okay, I'll check the repository first." or "Now I'll install the dependencies."), then call the tool. After the result, summarize what was actually achieved before continuing.''';
  }


  Future<void> _run({
    required Models model,
    required List<Map<String, dynamic>> messages,
    String? systemPromptOverride,
    required StreamController<AgentChunk> ctrl,
    BuildContext? context,
    String workspacePath = '',
    String agentMode = 'agent',
    AgentConfirmCallback? onConfirmRequired,
    String approvalMode = 'default',
    AgentIdeControlCallback? onIdeControl,
    AgentEventBus? eventBus,
  }) async {
    _client = http.Client();
    bool terminalError = false;
    eventBus?.emit(AgentStarted(taskId: DateTime.now().millisecondsSinceEpoch.toString(), mode: agentMode));
    try {
      // Ask = no tools at all. Plan = read-only tools.
      // Agent = all tools.
      final shouldUseTools =
          context != null && (agentMode == 'agent' || agentMode == 'plan');
      final agenticTools = shouldUseTools
          ? AgenticTools(
              workspacePath: workspacePath,
              context: context,
              onConfirmRequired: onConfirmRequired,
              onIdeControl: onIdeControl,
              approvalMode: approvalMode,
            )
          : null;
      _activeTools = agenticTools;

      // Register native tools in V3 ToolRegistry
      // Tool definitions capture the current context, approval callback and
      // workspace. Re-register them on every run so a changed model or
      // approval mode never keeps stale closures from the previous turn.
      if (context != null) {
        toolRegistry.clear();
        NativeToolBridge.registerAll(
          registry: toolRegistry,
          context: context,
          workspacePath: workspacePath,
          onConfirmRequired: onConfirmRequired,
          onIdeControl: onIdeControl,
          approvalMode: approvalMode,
        );
      }

      // Initialize SubagentManager
      subagentManager ??= SubagentManager(
        registry: agentRegistry,
        eventBus: _eventBus,
      );

      // Initialize McpToolBridge and sync MCP tools
      mcpToolBridge ??= McpToolBridge(registry: toolRegistry);
      try {
        await mcpToolBridge!.syncAll();
      } catch (_) {}

      // Initialize EventActivityBridge if eventBus available
      if (eventBus != null && activityBridge == null) {
        // ActivityBridge needs ActivityController from UI - skip for now
      }

      final toolSchemas = toolRegistry.count > 0
          ? toolRegistry.getSchemas(mode: agentMode)
          : (agenticTools?.getTools(
                readAccessOnly: agentMode != 'agent',
              ) ??
              const <Map<String, dynamic>>[]);

      // ── Dynamic generation of the system prompt (V3 ContextManager) ──────
      final basePrompt = await _buildSystemPrompt(workspacePath, toolSchemas, agentMode: agentMode);
      
      // Enrich context with V3 ContextManager
      String enrichedContext = '';
      if (workspacePath.isNotEmpty) {
        try {
          final agentContext = await contextManager.build(
            workspacePath: workspacePath,
            userRequest: messages.isNotEmpty ? (messages.last['content']?.toString() ?? '') : '',
            conversationHistory: messages,
          );
          if (agentContext.usagePercent > 0.1) {
            enrichedContext = '\n\n## PROJECT CONTEXT (auto-generated)\n${agentContext.buildString()}';
          }
        } catch (_) {}
      }
      
      final systemPrompt = (systemPromptOverride == null ||
              systemPromptOverride.trim().isEmpty)
          ? '$basePrompt$enrichedContext'
          : '$basePrompt$enrichedContext\n\n## CUSTOM CONTEXTURE\n$systemPromptOverride';

      // Save session start
      final sessionId = 'session_${DateTime.now().millisecondsSinceEpoch}';
      await sessionManager.save(AgentSessionData(
        id: sessionId,
        title: messages.isNotEmpty ? ((messages.last['content']?.toString() ?? 'Session').length > 50 ? (messages.last['content']?.toString() ?? 'Session').substring(0, 50) : (messages.last['content']?.toString() ?? 'Session')) : 'Session',
        mode: agentMode,
        model: model.runtimeType.toString(),
        messages: messages,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      PandaLog.i(
        'AgentRunner',
        'Starting run — provider=${model.runtimeType} '
        'mode=$agentMode tools=${agenticTools != null} '
        'toolCount=${toolSchemas.length} workspace=$workspacePath '
        'sessionId=$sessionId',
      );
      if (model is LocalLlama) {
        await _runLocalLlama(
          model,
          messages,
          systemPrompt,
          ctrl,
          context,
        );
      } else if (model is Gemini) {
        await _runGemini(
          model,
          messages,
          systemPrompt,
          ctrl,
          agenticTools,
          toolSchemas,
          allowWrites: agentMode == 'agent',
          agentMode: agentMode,
          workspacePath: workspacePath,
          blocks: _BlockSequencer(),
           approvalMode: approvalMode,
           onConfirmRequired: onConfirmRequired,
          eventBus: eventBus,
        );
      } else {
        await _runSse(
          model,
          messages,
          systemPrompt,
          ctrl,
          agenticTools,
          toolSchemas,
          allowWrites: agentMode == 'agent',
          agentMode: agentMode,
          workspacePath: workspacePath,
          blocks: _BlockSequencer(),
           approvalMode: approvalMode,
           onConfirmRequired: onConfirmRequired,
          eventBus: eventBus,
        );
      }
    } catch (e) {
      terminalError = true;
      final classified = ErrorClassifier.classify(e);
      PandaLog.e('AgentRunner', 'Uncaught error in _run [category=${classified.category}]', error: e);
      eventBus?.emit(AgentError(taskId: '', error: e.toString()));
      if (!ctrl.isClosed) {
        final errorMsg = classified.suggestion.isNotEmpty
            ? '${e.toString()}\nSuggestion: ${classified.suggestion}'
            : e.toString();
        ctrl.add(AgentChunk(phase: AgentPhase.error, text: errorMsg));
      }
    } finally {
      _client?.close();
      _client = null;
      _activeTools = null;
      PandaLog.i('AgentRunner', 'Run complete');
      eventBus?.emit(AgentFinished(taskId: '', result: ''));
      if (!terminalError && !ctrl.isClosed) {
        ctrl.add(const AgentChunk(phase: AgentPhase.done, text: ''));
      }
      await ctrl.close();
    }
  }

  Future<void> _runLocalLlama(
    LocalLlama model,
    List<Map<String, dynamic>> messages,
    String systemPrompt,
    StreamController<AgentChunk> ctrl,
    BuildContext? context,
  ) async {
    if (context == null) {
      throw StateError('The local model requires the Panda Agent context.');
    }

    final bloc = context.read<LocalLlamaBloc>();
    if (bloc.state.loadedModelPath != model.modelPath ||
        !bloc.state.isReady) {
      bloc.add(LocalLlamaLoadModel(model));
      await bloc.stream.firstWhere((state) =>
          state.isReady || state.status == LocalLlamaStatus.error).timeout(
        const Duration(minutes: 5),
        onTimeout: () => throw TimeoutException(
          'Local model loading has exceeded the expected time limit.',
        ),
      );
      if (!bloc.state.isReady) {
        throw StateError(
          bloc.state.error ?? 'Unable to load local model.',
        );
      }
    }

    final chatMessages = <ChatMessage>[
      ChatMessage(role: 'system', content: systemPrompt),
      ...messages.where((message) {
        final role = message['role']?.toString();
        return role == 'user' || role == 'assistant' || role == 'system';
      }).map((message) => ChatMessage(
            role: message['role']?.toString() ?? 'user',
            content: message['content']?.toString() ?? '',
          )),
    ];

    ctrl.add(const AgentChunk(phase: AgentPhase.streaming));
    final stream = bloc.controller!.generateChat(
      messages: chatMessages,
      maxTokens: model.maxTokens,
      temperature: model.temperature,
      topP: model.topP,
      topK: model.topK,
      repeatPenalty: model.repeatPenalty,
      frequencyPenalty: model.frequencyPenalty,
      presencePenalty: model.presencePenalty,
      repeatLastN: model.repeatLastN,
      mirostat: model.mirostat,
      mirostatTau: model.mirostatTau,
      mirostatEta: model.mirostatEta,
      seed: model.seed,
    );

    await for (final token in stream) {
      if (token.isNotEmpty && !ctrl.isClosed) {
        ctrl.add(AgentChunk(phase: AgentPhase.streaming, text: token));
      }
    }
  }

  // ── Gemini (direct JSON response + tool calling loop) ─────────────────────
  Future<void> _runGemini(
    Gemini model,
    List<Map<String, dynamic>> messages,
    String systemPrompt,
    StreamController<AgentChunk> ctrl,
    AgenticTools? tools,
    List<Map<String, dynamic>> toolSchemas,
    {
      required bool allowWrites,
      String agentMode = 'agent',
      String workspacePath = '',
      String approvalMode = 'default',
      AgentConfirmCallback? onConfirmRequired,
      _BlockSequencer? blocks,
      AgentEventBus? eventBus,
    }
  ) async {
    final seq = blocks ?? _BlockSequencer();
    final conversationMessages = <Map<String, dynamic>>[
      <String, dynamic>{'role': 'system', 'content': systemPrompt},
      ...messages,
    ];

    for (var turn = 0; turn < 12; turn++) {
      if (ctrl.isClosed) return;

      final body = model.buildToolCallingRequest(
        messages: conversationMessages,
        tools: toolSchemas,
        stream: false,
      );

      PandaLog.httpRequest('Gemini', 'POST', model.url,
          body: 'turn=$turn messages=${conversationMessages.length} tools=${toolSchemas.length}');

      final resp = await _client!.post(
        Uri.parse(model.url),
        headers: model.headers,
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 90), onTimeout: () {
        throw TimeoutException('The Gemini request exceeded 90 seconds.');
      });

      PandaLog.httpResponse('Gemini', resp.statusCode, model.url, body: resp.body);

      if (resp.statusCode >= 400) {
        ctrl.add(AgentChunk(
          phase: AgentPhase.error,
          text: _friendlyHttpError(resp.statusCode, resp.body, provider: 'Gemini'),
        ));
        return;
      }

      final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
      final parts = decoded['candidates']?[0]?['content']?['parts'];

      if (parts is! List) {
        final text = decoded['candidates']?[0]?['content']?['parts']?[0]?['text'] ?? '';
        if (text.toString().isNotEmpty) {
          ctrl.add(AgentChunk(phase: AgentPhase.streaming, text: text.toString()));
          eventBus?.emit(AgentStreamingChunk(text: text.toString()));
        }
        return;
      }

      // Collect text/thinking parts and function calls
      String assistantText = '';
      final List<Map<String, dynamic>> functionCalls = [];

      for (final part in parts) {
        if (part['thought'] == true) {
          final t = part['text']?.toString() ?? '';
          if (t.isNotEmpty) {
            ctrl.add(AgentChunk(phase: AgentPhase.thinking, text: t, blockId: seq.next('thinking')));
            eventBus?.emit(AgentThinkingChunk(text: t));
          }
        } else if (part['functionCall'] != null) {
          functionCalls.add(Map<String, dynamic>.from(part['functionCall'] as Map));
        } else {
          final t = part['text']?.toString() ?? '';
          if (t.isNotEmpty) {
            assistantText += t;
            ctrl.add(AgentChunk(phase: AgentPhase.streaming, text: t, blockId: seq.next('text')));
            eventBus?.emit(AgentStreamingChunk(text: t));
          }
        }
      }

      // No tool calls → done
      if (functionCalls.isEmpty || tools == null) return;

      // Compact history if too long (in-place)
      if (conversationMessages.length > 50) {
        final compacted = await HistoryCompactor.compact(
          conversationMessages,
          maxTokens: 8000,
          summarize: (text) async => text.substring(0, text.length ~/ 2),
        );
        conversationMessages
          ..clear()
          ..addAll(compacted);
      }

      // Add assistant turn to conversation
      conversationMessages.add({
        'role': 'assistant',
        'content': assistantText,
        'tool_calls': functionCalls.map((fc) => {
          'id': fc['name'] ?? 'call_${turn}_${functionCalls.indexOf(fc)}',
          'type': 'function',
          'function': {
            'name': fc['name'],
            'arguments': jsonEncode(fc['args'] ?? {}),
          },
        }).toList(),
      });

      // Execute each tool call
      final toolResults = <Map<String, dynamic>>[];
      for (final fc in functionCalls) {
        final name = fc['name']?.toString() ?? '';
        final args = (fc['args'] is Map)
            ? Map<String, dynamic>.from(fc['args'] as Map)
            : <String, dynamic>{};

        ctrl.add(AgentChunk(phase: AgentPhase.toolRunning, toolName: name, toolArgs: args, blockId: seq.next('tool')));
        eventBus?.emit(AgentToolStarted(toolId: name, toolName: name, args: args));
        _eventBus.emit(AgentToolStarted(toolId: name, toolName: name, args: args));
        PandaLog.toolCall('Gemini', name, args);

        final approved = await _confirmEveryTool(
          approvalMode: approvalMode,
          onConfirmRequired: onConfirmRequired,
          toolName: name,
          args: args,
        );

        // Use V3 ToolExecutor when available, fallback to old dispatch
        String result;
        if (!approved) {
          result = 'Tool "$name" canceled by the user.';
        } else if (toolRegistry.has(name)) {
          result = await toolExecutor.execute(name, args);
        } else {
          result = await _dispatchTool(
            tools,
            name,
            args,
            allowWrites: allowWrites,
            agentMode: agentMode,
          );
        }
        // Wrap with timeout
        final timedResult = await Future<String>.delayed(
          Duration.zero,
          () => Future.value(result),
        ).timeout(const Duration(seconds: 150), onTimeout: () {
          PandaLog.w('Gemini', 'Tool $name timed out after 150 s');
          return 'Error: tool $name exceeded 150 s timeout';
        });
        result = timedResult;
        PandaLog.toolResult('Gemini', name, result);
        ctrl.add(AgentChunk(phase: AgentPhase.toolDone, toolName: name, toolResult: result));
        eventBus?.emit(AgentToolFinished(toolId: name, toolName: name, result: result));

        // V3 Verification: run checks after mutating tool calls
        if (allowWrites && ['writeFile', 'editFile', 'deleteFile'].contains(name)) {
          final changedFile = args['filePath']?.toString() ?? '';
          if (changedFile.isNotEmpty && workspacePath.isNotEmpty) {
            try {
              final vResult = await VerificationPipeline.run(
                changedFiles: [changedFile],
                workspacePath: workspacePath,
                level: VerificationLevel.basic,
              );
              if (!vResult.passed) {
                eventBus?.emit(AgentVerificationFailed(
                  errors: vResult.errors,
                ));
              }
            } catch (_) {}
          }
        }
        toolResults.add({
          'tool_call_id': name,
          'role': 'tool',
          'name': name,
          'content': result,
        });
      }

      // Add tool results to conversation
      conversationMessages.addAll(toolResults);
    }

    // Exceeded max turns
    ctrl.add(const AgentChunk(
      phase: AgentPhase.streaming,
      text: '\nThe action limit has been reached. Check the result before continuing.',
    ));
  }

  // ── SSE streaming (OpenAI-compat + Anthropic) + tool calling ─────────────
  Future<void> _emitProgressiveText(
    String text,
    StreamController<AgentChunk> ctrl, {
    required _BlockSequencer sequence,
    AgentEventBus? eventBus,
  }) async {
    if (text.isEmpty || ctrl.isClosed) return;

    // Tool-calling providers return the final assistant message as one JSON
    // response. Keep the same visual contract as SSE providers by delivering
    // that response in small, timed chunks instead of making it pop in whole.
    const chunkSize = 12;
    final blockId = sequence.next('text');
    for (var offset = 0; offset < text.length; offset += chunkSize) {
      if (ctrl.isClosed) return;
      final end = (offset + chunkSize).clamp(0, text.length).toInt();
      final chunk = text.substring(offset, end);
      ctrl.add(
        AgentChunk(
          phase: AgentPhase.streaming,
          text: chunk,
          blockId: blockId,
        ),
      );
      eventBus?.emit(AgentStreamingChunk(text: chunk));
      await Future<void>.delayed(const Duration(milliseconds: 18));
    }
  }

  Future<void> _runSse(
    Models model,
    List<Map<String, dynamic>> messages,
    String systemPrompt,
    StreamController<AgentChunk> ctrl,
    AgenticTools? tools,
    List<Map<String, dynamic>> toolSchemas,
    {
      required bool allowWrites,
      String agentMode = 'agent',
      String workspacePath = '',
      String approvalMode = 'default',
      AgentConfirmCallback? onConfirmRequired,
      _BlockSequencer? blocks,
      AgentEventBus? eventBus,
    }
  ) async {
    final seq = blocks ?? _BlockSequencer();
    final conversationMessages = <Map<String, dynamic>>[
      <String, dynamic>{'role': 'system', 'content': systemPrompt},
      ...messages,
    ];

    for (var turn = 0; turn < 12; turn++) {
      if (ctrl.isClosed) return;

      final body = model.buildToolCallingRequest(
        messages: conversationMessages,
        tools: toolSchemas,
        // For tool calling we need non-streaming to parse tool calls cleanly
        stream: toolSchemas.isEmpty,
      );

      // If streaming with no tools, use the old SSE path
      // NOTE: use chatUrl (not url) — for OpenAI, url→/v1/responses,
      //       chatUrl→/v1/chat/completions (correct Chat Completions format).
      if (toolSchemas.isEmpty) {
        final chatUrl = model.chatUrl;
        PandaLog.httpRequest('SSE', 'POST', chatUrl,
            body: 'turn=$turn messages=${conversationMessages.length} stream=true');
        final req = http.Request('POST', Uri.parse(chatUrl))
          ..headers.addAll(model.headers)
          ..body = jsonEncode(body);
        final streamed = await _client!.send(req).timeout(const Duration(seconds: 90), onTimeout: () {
          throw TimeoutException('The SSE connection has exceeded 90 seconds.');
        });

        if (streamed.statusCode != 200) {
          final body = await streamed.stream.bytesToString();
          PandaLog.e('SSE', 'HTTP ${streamed.statusCode} from $chatUrl', body: body);
          ctrl.add(AgentChunk(
            phase: AgentPhase.error,
            text: 'HTTP ${streamed.statusCode}: $body',
          ));
          return;
        }

        int chunkCount = 0;
        final lines = streamed.stream
            .transform(const Utf8Decoder())
            .transform(const LineSplitter())
            // Per-event timeout: abort if the server stops sending for 60 s
            .timeout(
              const Duration(seconds: 60),
              onTimeout: (sink) {
                PandaLog.w('SSE', 'Per-event timeout reached (60 s) — surfacing error');
                sink.addError(TimeoutException('The model did not respond within the allotted time.'));
                sink.close();
              },
            );
        final startMs = DateTime.now().millisecondsSinceEpoch;
        await for (final line in lines) {
          if (ctrl.isClosed) break;
          if (!line.startsWith('data:')) continue;
          final data = line.substring(5).trim();
          if (data == '[DONE]') break;
          if (data.isEmpty) continue;
          Map<String, dynamic> obj;
          try {
            obj = jsonDecode(data) as Map<String, dynamic>;
          } catch (parseErr) {
            PandaLog.w('SSE', 'Failed to parse chunk: $parseErr', body: data);
            continue;
          }
          chunkCount++;
          _parseChunk(obj, ctrl);
        }
        final elapsed = DateTime.now().millisecondsSinceEpoch - startMs;
        if (chunkCount == 0) {
          const message =
              'The model closed the feed without sending any content'
              '(empty response or session refused).';
          PandaLog.e('SSE', 'Stream ended with ZERO chunks in ${elapsed}ms');
          if (!ctrl.isClosed) {
            ctrl.add(const AgentChunk(
              phase: AgentPhase.error,
              text: message,
            ));
          }
        } else {
          PandaLog.i('SSE', 'Stream done — $chunkCount chunks in ${elapsed}ms');
        }
        return;
      }

      // Non-streaming for tool calling
      // NOTE: use chatUrl — same reason as above.
      final chatUrl = model.chatUrl;
      PandaLog.httpRequest('SSE', 'POST', chatUrl,
          body: 'turn=$turn messages=${conversationMessages.length} tools=${toolSchemas.length} stream=false');
      final resp = await _client!.post(
        Uri.parse(chatUrl),
        headers: model.headers,
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 90), onTimeout: () {
        throw TimeoutException('The tool-calling request exceeded 90 seconds.');
      });

      PandaLog.httpResponse('SSE', resp.statusCode, chatUrl, body: resp.body);

      if (resp.statusCode >= 400) {
        ctrl.add(AgentChunk(
          phase: AgentPhase.error,
          text: _friendlyHttpError(
            resp.statusCode,
            resp.body,
            provider: model is DeepSeek ? 'DeepSeek' : model.runtimeType.toString(),
          ),
        ));
        return;
      }

      final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
      final reasoningText = _extractNonStreamingReasoning(decoded);
      if (reasoningText.isNotEmpty) {
        ctrl.add(AgentChunk(
          phase: AgentPhase.thinking,
          text: reasoningText,
          blockId: seq.next('thinking'),
        ));
        eventBus?.emit(AgentThinkingChunk(text: reasoningText));
        PandaLog.d(
          'AgentRunner',
          'Non-stream reasoning received (${reasoningText.length} chars)',
        );
      }
      final assistantText = model.parseChatMessage(decoded);
      final toolCalls = model.parseToolCalls(decoded);
      PandaLog.d('SSE', 'Parsed response — text=${assistantText.length} chars toolCalls=${toolCalls.length}');

      if (assistantText.isNotEmpty) {
        await _emitProgressiveText(
          assistantText,
          ctrl,
          sequence: seq,
          eventBus: eventBus,
        );
      } else {
        final fallbackChunks = parseSsePayload(decoded);
        if (fallbackChunks.isNotEmpty) {
          for (final chunk in fallbackChunks) {
            ctrl.add(chunk);
          }
        } else if (tools == null || toolCalls.isEmpty) {
          ctrl.add(const AgentChunk(
            phase: AgentPhase.error,
            text: 'The model returned no usable content.',
          ));
          return;
        }
      }

      if (toolCalls.isEmpty || tools == null) return;

      conversationMessages.add({
        'role': 'assistant',
        'content': assistantText,
        if (toolCalls.isNotEmpty) 'tool_calls': toolCalls,
      });

      final toolResults = <String>[];
      for (final call in toolCalls) {
        final callFunction = call['function'];
        if (callFunction is! Map) {
          toolResults.add('Malformed tool call');
          continue;
        }
        final functionName = callFunction['name']?.toString() ?? '';
        final rawArgs = callFunction['arguments'];
        Map<String, dynamic> args = {};
        if (rawArgs is String && rawArgs.trim().isNotEmpty) {
          try {
            final parsed = jsonDecode(rawArgs);
            if (parsed is Map) args = Map<String, dynamic>.from(parsed);
          } catch (_) {}
        } else if (rawArgs is Map) {
          args = Map<String, dynamic>.from(rawArgs);
        }

        ctrl.add(AgentChunk(
          phase: AgentPhase.toolRunning,
          toolName: functionName,
          toolArgs: args,
          blockId: seq.next('tool'),
        ));
        eventBus?.emit(AgentToolStarted(toolId: functionName, toolName: functionName, args: args));
        PandaLog.toolCall('SSE', functionName, args);
        final approved = await _confirmEveryTool(
          approvalMode: approvalMode,
          onConfirmRequired: onConfirmRequired,
          toolName: functionName,
          args: args,
        );
        final String result;
        if (!approved) {
          result = 'Tool "$functionName" cancelled by the user.';
        } else {
          result = await _dispatchTool(
            tools,
            functionName,
            args,
            allowWrites: allowWrites,
            agentMode: agentMode,
          ).timeout(const Duration(seconds: 150), onTimeout: () {
            PandaLog.w('SSE', 'Tool $functionName timed out after 150 s');
            return 'Error: tool $functionName exceeded 150 s timeout';
          });
        }
        PandaLog.toolResult('SSE', functionName, result);
        ctrl.add(AgentChunk(phase: AgentPhase.toolDone, toolName: functionName, toolResult: result));
        eventBus?.emit(AgentToolFinished(toolId: functionName, toolName: functionName, result: result));

        // V3 Verification: run checks after mutating tool calls
        if (allowWrites && ['writeFile', 'editFile', 'deleteFile'].contains(functionName)) {
          final changedFile = args['filePath']?.toString() ?? '';
          if (changedFile.isNotEmpty && workspacePath.isNotEmpty) {
            try {
              final vResult = await VerificationPipeline.run(
                changedFiles: [changedFile],
                workspacePath: workspacePath,
                level: VerificationLevel.basic,
              );
              if (!vResult.passed) {
                eventBus?.emit(AgentVerificationFailed(
                  errors: vResult.errors,
                ));
              }
            } catch (_) {}
          }
        }
        toolResults.add(result);
      }

      conversationMessages.addAll(
        model.buildToolResultMessages(toolCalls, toolResults),
      );
    }

    ctrl.add(const AgentChunk(
      phase: AgentPhase.streaming,
      text: '\nThe action limit has been reached. Check the result before continuing.',
    ));
  }

  // ── Tool dispatch ─────────────────────────────────────────────────────────
  Future<bool> _confirmEveryTool({
    required String approvalMode,
    required AgentConfirmCallback? onConfirmRequired,
    required String toolName,
    required Map<String, dynamic> args,
  }) async {
    if (approvalMode != 'every') return true;
    if (onConfirmRequired == null) return false;
    return onConfirmRequired(
      toolName: toolName,
      command: toolName,
      details: args.isEmpty
          ? 'The agent requests the execution of this tool.'
          : 'Arguments : ${jsonEncode(args)}',
    );
  }

  Future<String> _dispatchTool(
    AgenticTools tools,
    String functionName,
    Map<String, dynamic> args,
    {required bool allowWrites, String agentMode = 'agent'}
  ) async {
    // Use V3 ToolExecutor when available
    if (toolRegistry.has(functionName)) {
      return await toolExecutor.execute(functionName, args);
    }
    try {
      const mutatingTools = {
        'writeFile',
        'deleteFile',
        'renamePath',
        'rename',
        'insertAtLine',
        'replaceAllInFile',
        'editFile',
        'runShellCommand',
        'formatCode',
        'startBackgroundProcess',
        'stopBackgroundProcess',
        'updateProjectMemory',
      };
      if (!allowWrites && mutatingTools.contains(functionName)) {
        return "Block: The tool \"$functionName\" modifies the workspace and is unavailable in $agentMode. Please switch to Agent Mode to allow execution.";
      }
      switch (functionName) {
        case 'activeEditorFile':
          final res = await tools.activeEditorFile();
          return res.success ? (res.data ?? 'No active file') : (res.error ?? 'Error');
        case 'controlIde':
          final res = await tools.controlIde(
            args['action']?.toString() ?? '',
            targetPath: args['targetPath']?.toString(),
          );
          return res.success ? (res.data ?? 'IDE controlled') : (res.error ?? 'Error');
        case 'currentlySelectedText':
          final res = await tools.currentlySelectedText();
          return res.success
              ? 'Start: ${res.data?['startLine']}, End: ${res.data?['endLine']}, Text: ${res.data?['selectedText'] ?? ''}'
              : (res.error ?? 'Error');
        case 'getTerminalOutput':
          final lines = args['lines'] is int ? args['lines'] as int : 100;
          return TerminalBridge.instance.getRecentOutput(lines);
        case 'getLspDiagnostics':
          final res = await tools.getLspDiagnostics(args['filePath']);
          return res.success ? jsonEncode(res.data) : (res.error ?? 'Error');
        case 'getDefinition':
          final res = await tools.getDefinition(
            args['filePath'],
            args['line'] ?? 1,
            args['character'] ?? 1,
          );
          return res.success ? jsonEncode(res.data) : (res.error ?? 'Error');
        case 'findReferences':
          final res = await tools.findReferences(
            args['filePath'],
            args['line'] ?? 1,
            args['character'] ?? 1,
          );
          return res.success ? jsonEncode(res.data) : (res.error ?? 'Error');
        case 'getFileOutline':
          final res = await tools.getFileOutline(args['filePath']);
          return res.success ? jsonEncode(res.data) : (res.error ?? 'Error');
        case 'readFile':
          final res = await tools.readFile(args['filePath'], args['startLine'], args['endLine']);
          return res.success ? (res.data ?? '') : (res.error ?? 'Error reading file');
        case 'writeFile':
          final res = await tools.writeFile(args['filePath'], args['content']);
          return res.success ? 'File written successfully' : (res.error ?? 'Error writing file');
        case 'deleteFile':
          final res = await tools.deleteFile(args['filePath']);
          return res.success ? 'File deleted successfully' : (res.error ?? 'Error deleting file');
        case 'renamePath':
          final res = await tools.renamePath(args['oldPath'], args['newPath']);
          return res.success ? 'Renamed successfully' : (res.error ?? 'Error renaming');
        case 'rename':
          final res = await tools.rename(args['oldPath'], args['newPath']);
          return res.success ? 'Renamed successfully' : (res.error ?? 'Error renaming');
        case 'insertAtLine':
          final res = await tools.insertAtLine(
            args['filePath'], args['line'], args['text'],
            position: args['position'] ?? 'before',
          );
          return res.success ? 'Text inserted successfully' : (res.error ?? 'Error inserting');
        case 'replaceAllInFile':
          final res = await tools.replaceAllInFile(
            args['filePath'], args['oldText'], args['newText'],
            useRegex: args['useRegex'] ?? false,
            maxReplacements: args['maxReplacements'],
            caseSensitive: args['caseSensitive'] ?? true,
          );
          return res.success ? jsonEncode(res.data) : (res.error ?? 'Error replacing');
        case 'listFiles':
          final res = await tools.listFiles(
            args['directoryPath'],
            pattern: args['pattern'],
            recursive: args['recursive'] ?? false,
          );
          return res.success ? (res.data?.join('\n') ?? 'No files') : (res.error ?? 'Error listing');
        case 'readFilesBatch':
          final res = await tools.readFilesBatch((args['files'] as List?) ?? []);
          return res.success ? jsonEncode(res.data) : (res.error ?? 'Error');
        case 'globSearchFiles':
          final res = await tools.globSearchFiles(
            args['pattern'],
            directoryPath: args['directoryPath'] ?? '.',
            excludePatterns: (args['excludePatterns'] as List?)?.map((e) => e.toString()).toList(),
            recursive: args['recursive'] ?? true,
            maxResults: args['maxResults'],
          );
          return res.success ? (res.data?.join('\n') ?? 'No matches') : (res.error ?? 'Error');
        case 'searchInFiles':
          final res = await tools.searchInFiles(
            args['query'],
            filePattern: args['filePattern'],
            caseSensitive: args['caseSensitive'] ?? false,
            matchWholeWord: args['matchWholeWord'] ?? false,
            useRegex: args['useRegex'] ?? false,
          );
          return res.success
              ? (res.data?.map((s) => '${s.filePath}:${s.lineNumber}: ${s.lineContent}').join('\n') ?? 'No results')
              : (res.error ?? 'Error');
        case 'grepInFiles':
          final res = await tools.grepInFiles(
            args['query'],
            filePattern: args['filePattern'],
            caseSensitive: args['caseSensitive'] ?? false,
            matchWholeWord: args['matchWholeWord'] ?? false,
            useRegex: args['useRegex'] ?? false,
            before: args['before'] ?? 2,
            after: args['after'] ?? 2,
            maxResults: args['maxResults'],
          );
          return res.success
              ? (res.data?.map((r) => r.toString()).join('\n') ?? 'No results')
              : (res.error ?? 'Error');
        case 'editFile':
          final res = await tools.editFile(args['filePath'], args['oldText'], args['newText']);
          return res.success ? 'File edited successfully' : (res.error ?? 'Error editing file');
        case 'getPendingEditsForFile':
          final res = await tools.getPendingEditsForFile(args['filePath']);
          return res.success
              ? (res.data == null ? 'No pending edits' : jsonEncode(res.data!.toJson()))
              : (res.error ?? 'Error');
        case 'getFileInfo':
          final res = await tools.getFileInfo(args['filePath']);
          return res.success
              ? 'Path: ${res.data?.path}, Size: ${res.data?.size}, Modified: ${res.data?.modified}, IsDir: ${res.data?.isDirectory}'
              : (res.error ?? 'Error');
        case 'openLinks':
          final res = await tools.openLinks(args['url']);
          return res.success ? (res.data?.toString() ?? '') : (res.error ?? 'Error');
        case 'searchInWeb':
          final res = await tools.searchInWeb(args['searchQuery']);
          return res.success
              ? (res.data?.map((w) => '${w.title}\n${w.url}\n${w.snippet}').join('\n---\n') ?? 'No results')
              : (res.error ?? 'Error');
        case 'runShellCommand':
          final parsedArgs = (args['args'] as List?)?.map((e) => e.toString()).toList() ?? <String>[];
          final parsedEnvs = (args['envs'] as Map?)?.map((k, v) => MapEntry(k.toString(), v.toString())) ?? <String, String>{};
          final res = await tools.runShellCommand(args['command'], parsedArgs, parsedEnvs);
          return res.success ? jsonEncode(res.data) : (res.error ?? 'Error running command');
        case 'formatCode':
          final res = await tools.formatCode(args['filePath']);
          return res.success ? jsonEncode(res.data) : (res.error ?? 'Error formatting code');
        case 'startBackgroundProcess':
          final res = await tools.startBackgroundProcess(
            args['command'],
            processId: args['processId']?.toString(),
          );
          return res.success ? jsonEncode(res.data) : (res.error ?? 'Error starting process');
        case 'getProcessLogs':
          final res = await tools.getProcessLogs(args['processId']?.toString());
          return res.success ? jsonEncode(res.data) : (res.error ?? 'Error getting process logs');
        case 'stopBackgroundProcess':
          final res = await tools.stopBackgroundProcess(args['processId']?.toString() ?? '');
          return res.success ? (res.data ?? '') : (res.error ?? 'Error stopping process');
        case 'gitStatus':
          final res = await tools.gitStatus();
          return res.success ? jsonEncode(res.data?.toJson()) : (res.error ?? 'Error');
        case 'gitDiff':
          final res = await tools.gitDiff(
            filePath: args['filePath'],
            staged: args['staged'] ?? false,
            contextLines: args['contextLines'] ?? 3,
          );
          return res.success ? (res.data ?? '') : (res.error ?? 'Error');
        case 'gitLog':
          final res = await tools.gitLog(limit: args['limit'] ?? 20, filePath: args['filePath']);
          return res.success
              ? jsonEncode(res.data?.map((c) => c.toJson()).toList() ?? [])
              : (res.error ?? 'Error');
                case 'getSecret':
          final secretName = (args['name'] ?? args['secretName'] ?? '').toString();
          final res = await tools.getSecret(secretName);
          return res.success ? (res.data ?? '') : (res.error ?? 'Error getting secret');
        case 'listSecrets':
          final res = await tools.listSecrets();
          return res.success ? jsonEncode(res.data) : (res.error ?? 'Error listing secrets');
        case 'getAgentSkills':
          final res = await tools.getAgentSkills();
          return res.success ? jsonEncode(res.data) : (res.error ?? 'Error getting skills');
        case 'useAgentSkill':
          final sName = (args['skillName'] ?? args['name'] ?? '').toString();
          final res = await tools.useAgentSkill(sName);
          return res.success ? (res.data ?? '') : (res.error ?? 'Error using skill');
        case 'updateProjectMemory':
          final res = await tools.updateProjectMemory(args['content']?.toString() ?? '');
          return res.success
              ? 'Project memory updated at .panda/memory.md'
              : (res.error ?? 'Error updating project memory');
        default:
          return 'Unknown tool: $functionName';
      }
    } catch (e) {
      return 'Error executing $functionName: $e';
    }
  }

  /// Converts an HTTP error code + body into a user-friendly error message.
  static String _friendlyHttpError(
    int statusCode,
    String body, {
    String? provider,
  }) {
    // Try to extract message from JSON body
    String? extracted;
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      extracted = json['error']?['message']?.toString()
          ?? json['message']?.toString()
          ?? json['error']?.toString();
    } catch (_) {}

    switch (statusCode) {
      case 400:
        final detail = extracted ?? body;
        final deepSeekHint = provider == 'DeepSeek'
            ? '\n\nDeepSeek is waiting for a valid Chat Completions payload: '
                'Model available, non-empty messages and tool arguments in JSON.'
            : '';
        return 'Invalid query (400). $detail$deepSeekHint';
      case 401:
        return 'Invalid or expired API key (401).\n\n'
            '• Check your key in the Agent Settings (Providers tab).\n'
            '• For Gemini: the key must be activated on aistudio.google.com.'
            '• For DeepSeek/OpenAI: copy it from the provider\'s dashboard.';
      case 402:
        final detail = extracted ?? 'Insufficient Balance';
        if (provider == 'Gemini') {
          return 'Quota Gemini indisponible (402) — $detail\n\n'
              'The key may be attached to the wrong project or this project'
              'has no more quota. Check the project associated with the key in Google AI Studio.';
        }
        return 'Solde insuffisant (402) — $detail\n\n'
            'Your account has no more credit. Top up your balance at'
            'the provider\'s platform.';
      case 403:
        return 'Access denied (403). ${extracted ?? 'Your key does not have the necessary permissions.'}';
      case 404:
        // 404 can come from an incorrect endpoint URL OR a non-existent template name.
        final hint404 = extracted != null && extracted.isNotEmpty
            ? extracted
            : 'The selected model may no longer exist from this provider.';
        return 'Resource not found (404) — $hint404\n\n'
            'Reconfigure your provider in the Agent Settings to choose a valid template.';
      case 429:
        return 'Broadband limit reached (429). ${extracted ?? 'Wait a few seconds and try again.'}';
      case 500:
      case 502:
      case 503:
        return 'Server error ($statusCode). ${extracted ?? 'The provider is temporarily unavailable.'}';
      default:
        return 'HTTP $statusCode: ${extracted ?? body}';
    }
  }

  bool _shouldUseTools(List<Map<String, dynamic>> messages) {
    Map<String, dynamic>? latestUser;
    for (final message in messages.reversed) {
      if (message['role']?.toString() == 'user') {
        latestUser = message;
        break;
      }
    }
    final text = latestUser?['content']?.toString() ?? '';
    if (text.trim().isEmpty || text.trim().length < 8) {
      return false;
    }

    final lowered = text.toLowerCase();
    final actionTerms = [
      'create', 'edit', 'write', 'read', 'search', 'find', 'open', 'run', 'clone', 'delete',
      'rename', 'install', 'fix', 'build', 'analyze', 'summarize', 'debug', 'test', 'update',
      'generate', 'list', 'inspect', 'compare', 'explain', 'help', 'implement',
    ];
    return actionTerms.any(lowered.contains);
  }

  static (String, String) _extractThinkingTags(String text) {
    final matches = RegExp(r'<think>([\s\S]*?)</think>').allMatches(text);
    if (matches.isEmpty) {
      return ('', text);
    }

    final thinkingParts = <String>[];
    String cleaned = text;
    for (final match in matches.toList().reversed) {
      final value = match.group(1)?.trim() ?? '';
      if (value.isNotEmpty) {
        thinkingParts.add(value);
      }
      cleaned = cleaned.replaceRange(match.start, match.end, '');
    }

    return (thinkingParts.join('\n').trim(), cleaned.trim());
  }

  static List<AgentChunk> parseSsePayload(Map<String, dynamic> payload) {
    final chunks = <AgentChunk>[];

    void addTextChunk(String text) {
      if (text.trim().isEmpty) return;
      final (thinking, cleaned) = _extractThinkingTags(text);
      if (thinking.isNotEmpty) {
        chunks.add(AgentChunk(phase: AgentPhase.thinking, text: thinking));
      }
      if (cleaned.isNotEmpty) {
        chunks.add(AgentChunk(phase: AgentPhase.streaming, text: cleaned));
      }
    }

    final choices = payload['choices'];
    if (choices is List && choices.isNotEmpty) {
      for (final entry in choices) {
        if (entry is! Map) continue;
        final delta = entry['delta'];
        if (delta is Map) {
          final content = delta['content'];
          if (content is String && content.isNotEmpty) {
            addTextChunk(content);
          } else if (content is List) {
            for (final item in content) {
              if (item is String && item.isNotEmpty) {
                addTextChunk(item);
              } else if (item is Map) {
                final text = item['text']?.toString();
                if (text != null && text.isNotEmpty) {
                  addTextChunk(text);
                }
              }
            }
          }

          final reasoning = delta['reasoning_content'] ?? delta['reasoning'] ?? delta['thinking'];
          if (reasoning is String && reasoning.isNotEmpty) {
            chunks.add(AgentChunk(phase: AgentPhase.thinking, text: reasoning));
          }
        }

        final message = entry['message'];
        if (message is Map) {
          final content = message['content'];
          if (content is String && content.isNotEmpty) {
            addTextChunk(content);
          } else if (content is List) {
            for (final item in content) {
              if (item is String && item.isNotEmpty) {
                addTextChunk(item);
              } else if (item is Map) {
                final text = item['text']?.toString();
                if (text != null && text.isNotEmpty) {
                  addTextChunk(text);
                }
              }
            }
          }
        }
      }
      return chunks;
    }

    final output = payload['output'];
    if (output is List) {
      for (final item in output) {
        if (item is! Map) continue;
        final content = item['content'];
        if (content is List) {
          for (final part in content) {
            if (part is Map) {
              final text = part['text']?.toString();
              if (text != null && text.isNotEmpty) {
                addTextChunk(text);
              }
            }
          }
        }
      }
      if (chunks.isNotEmpty) return chunks;
    }

    final content = payload['content'];
    if (content is String && content.isNotEmpty) {
      addTextChunk(content);
      return chunks;
    }
    if (content is List) {
      for (final item in content) {
        if (item is Map) {
          final text = item['text']?.toString();
          if (text != null && text.isNotEmpty) {
            addTextChunk(text);
          }
        } else if (item is String && item.isNotEmpty) {
          addTextChunk(item);
        }
      }
    }

    final type = payload['type']?.toString() ?? '';
    if (type == 'content_block_delta') {
      final dt = payload['delta'];
      if (dt is Map) {
        final dtType = dt['type']?.toString() ?? '';
        if (dtType == 'text_delta') {
          final t = dt['text']?.toString() ?? '';
          if (t.isNotEmpty) addTextChunk(t);
        } else if (dtType == 'thinking_delta') {
          final t = dt['thinking']?.toString() ?? '';
          if (t.isNotEmpty) chunks.add(AgentChunk(phase: AgentPhase.thinking, text: t));
        }
      }
    }

    return chunks;
  }

  void _parseChunk(Map<String, dynamic> obj, StreamController<AgentChunk> ctrl) {
    final parsed = parseSsePayload(obj);
    if (parsed.isEmpty) return;
    for (final chunk in parsed) {
      ctrl.add(chunk);
    }
  }

  /// Extract provider-specific reasoning from a non-streaming response.
  ///
  /// Tool-calling requests intentionally use `stream: false`, so reasoning
  /// does not pass through the SSE parser. Providers place it under different
  /// keys (`reasoning_content`, `reasoning`, `thinking`, or `thought`).
  String _extractNonStreamingReasoning(Map<String, dynamic> payload) {
    final parts = <String>[];

    void visit(dynamic value) {
      if (value is List) {
        for (final item in value) {
          visit(item);
        }
        return;
      }
      if (value is! Map) return;

      for (final entry in value.entries) {
        final key = entry.key.toString();
        final child = entry.value;
        final isReasoningKey = key == 'reasoning_content' ||
            key == 'reasoning' ||
            key == 'thinking' ||
            key == 'thought';

        if (isReasoningKey) {
          if (child is String && child.trim().isNotEmpty) {
            parts.add(child);
          } else if (child is Map || child is List) {
            visit(child);
          }
          continue;
        }

        // Walk response envelopes, but do not inspect ordinary text fields.
        if (child is Map || child is List) {
          visit(child);
        }
      }
    }

    visit(payload);
    return parts.join();
  }
}
