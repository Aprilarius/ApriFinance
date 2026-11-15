import 'dart:io';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'data/finance_repository.dart';
import 'data/ledger_database.dart';
import 'data/backup_service.dart';
import 'data/app_storage.dart';
import 'data/reminders_service.dart';
import 'data/insights_preferences_repository.dart';
import 'data/native_cloud_credentials.dart';
import 'ui/finance_view_model.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final support = await getApplicationSupportDirectory();
    final directory = Directory(
      ledgerStoragePath(support.path, windows: Platform.isWindows),
    );
    await directory.create(recursive: true);
    final database = LedgerDatabase(
      NativeDatabase.createInBackground(
        File(p.join(directory.path, 'finance.sqlite')),
      ),
    );
    final repository = FinanceRepository(database);
    final reminders = RemindersService(
      NativeReminderBackend(),
      File(p.join(directory.path, 'reminders.json')),
    );
    await reminders.initialize();
    final vm = FinanceViewModel(
      repository,
      insightsPreferences: DatabaseInsightsPreferences(
        repository,
        legacyFile: File(p.join(directory.path, 'insights.json')),
      ),
      cloudPreferences: File(p.join(directory.path, 'cloud.json')),
      cloudCredentials: const NativeCloudCredentialStore(),
      reminders: reminders,
      backup: BackupService(
        repository,
        Directory(p.join(directory.path, 'recovery')),
      ),
    );
    await vm.refresh();
    runApp(FinanceApp(viewModel: vm));
  } catch (_) {
    runApp(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Не удалось открыть хранилище приложения. Проверьте доступ к папке данных и перезапустите приложение.',
              ),
            ),
          ),
        ),
      ),
    );
  }
}
