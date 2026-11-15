import 'package:material_ui/material_ui.dart';

/// Keep the title and fields in one viewport when a keyboard leaves little room.
/// Actions stay outside the scroll area so saving and cancelling remain visible.
class LedgerFormDialog extends StatelessWidget {
  const LedgerFormDialog({
    super.key,
    required this.title,
    required this.content,
    required this.actions,
  });

  final Widget title;
  final Widget content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < 600 || constraints.maxHeight < 600;
      return AlertDialog(
        scrollable: true,
        titleTextStyle: compact ? Theme.of(context).textTheme.titleLarge : null,
        insetPadding: EdgeInsets.symmetric(
          horizontal: compact ? 16 : 40,
          vertical: 16,
        ),
        titlePadding: EdgeInsets.fromLTRB(
          compact ? 16 : 24,
          24,
          compact ? 16 : 24,
          0,
        ),
        contentPadding: EdgeInsets.all(compact ? 16 : 24),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        title: title,
        content: content,
        actions: actions,
      );
    },
  );
}
