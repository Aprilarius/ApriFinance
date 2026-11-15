import 'dart:convert';
import 'dart:io';

import '../domain/insights/insight.dart';
import 'finance_repository.dart';

class DatabaseInsightsPreferences implements InsightsPreferences {
  DatabaseInsightsPreferences(this.repository, {this.legacyFile});
  final FinanceRepository repository;
  final File? legacyFile;
  bool _migrationAttempted = false;
  @override
  Future<AnalysisPolicy> read() async {
    final saved = await repository.readAnalysisPolicy();
    if (saved != null) return saved;
    final legacy = legacyFile;
    var policy = AnalysisPolicy();
    if (!_migrationAttempted && legacy != null && await legacy.exists()) {
      policy = await FileInsightsPreferences(legacy).read();
      await repository.writeAnalysisPolicy(policy);
      _migrationAttempted = true;
      // Keep a recoverable archive, but never import it again after restoring
      // an older .mfin without analysis settings.
      await legacy.rename(
        '${legacy.path}.migrated-${DateTime.now().microsecondsSinceEpoch}',
      );
      return policy;
    }
    _migrationAttempted = true;
    return policy;
  }

  @override
  Future<void> write(AnalysisPolicy policy) =>
      repository.writeAnalysisPolicy(policy);
}

abstract interface class InsightsPreferences {
  Future<AnalysisPolicy> read();
  Future<void> write(AnalysisPolicy policy);
}

class MemoryInsightsPreferences implements InsightsPreferences {
  AnalysisPolicy value = AnalysisPolicy();
  @override
  Future<AnalysisPolicy> read() async => value;
  @override
  Future<void> write(AnalysisPolicy policy) async {
    value = policy;
  }
}

class FileInsightsPreferences implements InsightsPreferences {
  FileInsightsPreferences(this.file);
  final File file;
  @override
  Future<AnalysisPolicy> read() async {
    if (!await file.exists()) return AnalysisPolicy();
    if (await file.length() > 1024 * 1024) {
      throw const FormatException('Настройки анализа слишком велики');
    }
    return AnalysisPolicy.fromJson(
      jsonDecode(await file.readAsString()) as Map<String, dynamic>,
    );
  }

  @override
  Future<void> write(AnalysisPolicy policy) async {
    final bytes = utf8.encode(jsonEncode(policy.toJson()));
    if (bytes.length > 1024 * 1024) {
      throw const FormatException('Настройки анализа слишком велики');
    }
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(file.path);
  }
}
