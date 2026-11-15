import 'package:path/path.dart' as p;

/// Windows path_provider derives the folder from ProductName. Keep the original
/// ledger location across the public rename to ApriFinance, without moving files.
String ledgerStoragePath(String supportPath, {required bool windows}) {
  if (!windows) return supportPath;
  final paths = p.Context(style: p.Style.windows);
  return paths.join(paths.dirname(supportPath), 'personal_finance');
}
