import '../../ui/agent/agent_models.dart';
import 'agent_event.dart';
import 'agent_event_bus.dart';

/// Bridges the new AgentEventBus with the existing AgentActivityController.
///
/// When events come through the bus, they update the activity controller
/// so the existing Activity Feed UI works without modification.
class EventActivityBridge {
  final AgentEventBus _eventBus;
  final AgentActivityController _activityCtrl;

  EventActivityBridge({
    required this._eventBus,
    required this._activityCtrl,
  });

  /// Start listening to events and updating the activity controller.
  void start() {
    _eventBus.events.listen(_onEvent);
  }

  void _onEvent(AgentEvent event) {
    switch (event) {
      case AgentStarted():
        _activityCtrl.startRun();
        break;

      case AgentThinkingStarted():
        _activityCtrl.updateNarrative('Thinking…');
        break;

      case AgentThinkingFinished():
        _activityCtrl.updateNarrative('Thinking complete');
        break;

      case AgentStreamingStarted():
        _activityCtrl.updateNarrative('Generating…');
        break;

      case AgentStreamingChunk():
        // Don't update narrative on every chunk to avoid flicker
        break;

      case AgentToolStarted():
        _activityCtrl.startTool(
          toolId: event.toolId,
          toolName: event.toolName,
          args: event.args,
        );
        break;

      case AgentToolFinished():
        _activityCtrl.completeTool(
          toolId: event.toolId,
          result: event.result,
        );
        break;

      case AgentToolFailed():
        _activityCtrl.failTool(
          toolId: event.toolId,
          error: event.error,
        );
        break;

      case AgentToolBlocked():
        _activityCtrl.failTool(
          toolId: event.toolId,
          error: 'Blocked: ${event.reason}',
        );
        break;

      case AgentVerificationStarted():
        _activityCtrl.updateNarrative('Verification…');
        break;

      case AgentVerificationPassed():
        _activityCtrl.updateNarrative('Verification OK');
        break;

      case AgentVerificationFailed():
        _activityCtrl.updateNarrative('${event.errors.length} error(s)');
        break;

      case AgentSubagentStarted():
        _activityCtrl.updateNarrative('Sub-agent ${event.agentType}…');
        break;

      case AgentSubagentFinished():
        _activityCtrl.updateNarrative('Sub-agent finished');
        break;

      case AgentContextCompacted():
        _activityCtrl.updateNarrative(
            'Contexte compresse (${event.tokensAfter} tokens)');
        break;

      case AgentRetryStarted():
        _activityCtrl.updateNarrative(
            'Retry ${event.attempt}/${event.maxAttempts}: ${event.reason}');
        break;

      case AgentFinished():
        _activityCtrl.finishRun();
        break;

      case AgentError():
        _activityCtrl.finishRun(error: event.error);
        break;

      case AgentCancelled():
        _activityCtrl.finishRun(error: 'Canceled');
        break;

      default:
        // Other events don't need activity feed updates
        break;
    }
  }

  void dispose() {
    // Stream subscription is managed by the caller
  }
}
