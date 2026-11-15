import 'package:material_ui/material_ui.dart';

/// Keep the full value and the user's text scale. When a large amount needs
/// more than one line, break at thousands groups instead of splitting cents.
class MoneyText extends StatelessWidget {
  const MoneyText(this.value, {super.key, this.style});
  final String value;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final painter = TextPainter(
        text: TextSpan(
          text: value,
          style: DefaultTextStyle.of(context).style.merge(style),
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout(maxWidth: constraints.maxWidth);
      final needsWrap = painter.didExceedMaxLines;
      painter.dispose();
      return Semantics(
        label: value,
        excludeSemantics: true,
        child: Text(
          needsWrap ? value.replaceAll('\u00a0', ' ') : value,
          style: style,
        ),
      );
    },
  );
}
