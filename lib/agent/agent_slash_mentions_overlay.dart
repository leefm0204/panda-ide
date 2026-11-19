import 'package:material_ui/material_ui.dart';

class SlashCommandItem {
  final String command;
  final String description;
  final String prompt;

  const SlashCommandItem({
    required this.command,
    required this.description,
    required this.prompt,
  });
}

class MentionItem {
  final String key;
  final String label;
  final IconData icon;

  const MentionItem({
    required this.key,
    required this.label,
    required this.icon,
  });
}

const List<SlashCommandItem> kPandaSlashCommands = [
  SlashCommandItem(
    command: '/fix',
    description: 'Correct LSP errors in the active file',
    prompt: 'Corrects all errors and warnings in the active file.',
  ),
  SlashCommandItem(
    command: '/explain',
    description: 'Explain the code of the active file',
    prompt: 'Explains in detail the role and function of the active file.',
  ),
  SlashCommandItem(
    command: '/tests',
    description: 'Generate unit tests',
    prompt: 'Generates full unit tests for the active file.',
  ),
  SlashCommandItem(
    command: '/commit',
    description: 'Generate a git commit message',
    prompt: 'Analyzes the current git diff and generates a clear commit message.',
  ),
  SlashCommandItem(
    command: '/review',
    description: 'Perform a code review',
    prompt: 'Perform a thorough code review of current changes.',
  ),
];

const List<MentionItem> kPandaMentions = [
  MentionItem(key: '@file', label: 'Insert the contents of a file', icon: Icons.insert_drive_file),
  MentionItem(key: '@folder', label: 'Insert the folder tree', icon: Icons.folder),
  MentionItem(key: '@problems', label: 'Insert Build Diagnostics/LSP', icon: Icons.bug_report),
  MentionItem(key: '@git', label: 'Insert current git status/diff', icon: Icons.merge_type),
  MentionItem(key: '@terminal', label: 'Insert recent terminal output', icon: Icons.terminal),
];

class AgentSlashMentionsOverlay extends StatelessWidget {
  final String query;
  final Function(String selected) onSelected;

  const AgentSlashMentionsOverlay({
    super.key,
    required this.query,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final isSlash = query.startsWith('/');
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xff222230) : Colors.white;

    if (isSlash) {
      final matches = kPandaSlashCommands
          .where((cmd) => cmd.command.toLowerCase().contains(query.toLowerCase()))
          .toList();

      if (matches.isEmpty) return const SizedBox.shrink();

      return Card(
        elevation: 6,
        color: bg,
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Container(
          constraints: const BoxConstraints(maxHeight: 180),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: matches.length,
            itemBuilder: (context, index) {
              final cmd = matches[index];
              return ListTile(
                dense: true,
                title: Text(cmd.command, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.blueAccent)),
                subtitle: Text(cmd.description, style: const TextStyle(fontSize: 11)),
                onTap: () => onSelected(cmd.prompt),
              );
            },
          ),
        ),
      );
    } else if (query.startsWith('@')) {
      final matches = kPandaMentions
          .where((m) => m.key.toLowerCase().contains(query.toLowerCase()))
          .toList();

      if (matches.isEmpty) return const SizedBox.shrink();

      return Card(
        elevation: 6,
        color: bg,
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Container(
          constraints: const BoxConstraints(maxHeight: 180),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: matches.length,
            itemBuilder: (context, index) {
              final item = matches[index];
              return ListTile(
                dense: true,
                leading: Icon(item.icon, size: 16, color: Colors.orangeAccent),
                title: Text(item.key, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                subtitle: Text(item.label, style: const TextStyle(fontSize: 11)),
                onTap: () => onSelected('${item.key} '),
              );
            },
          ),
        ),
      );
    }

    return const SizedBox.shrink();
  }
}
