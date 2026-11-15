import 'package:material_ui/material_ui.dart';

import 'cloud_controller.dart';

class CloudStatusBanner extends StatelessWidget {
  const CloudStatusBanner({
    super.key,
    required this.controller,
    required this.onOpen,
  });
  final CloudController controller;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (_, _) {
      if (!controller.needsAttention) return const SizedBox.shrink();
      return Container(
        width: double.infinity,
        color: Theme.of(context).colorScheme.secondaryContainer,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Wrap(
          spacing: 16,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('Обмен приостановлен. Требуется ваше решение.'),
            TextButton(
              key: const Key('resolve-cloud-attention'),
              onPressed: controller.busy ? null : onOpen,
              child: const Text('Проверить'),
            ),
          ],
        ),
      );
    },
  );
}
