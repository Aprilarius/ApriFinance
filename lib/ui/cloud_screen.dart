import 'package:material_ui/material_ui.dart';

import 'dart:convert';

import 'package:intl/intl.dart';

import '../domain/backup_data.dart';
import '../domain/insights/insight.dart';
import '../domain/money.dart';
import '../data/sync_service.dart';
import 'cloud_controller.dart';
import 'theme.dart';

class CloudScreen extends StatefulWidget {
  const CloudScreen({super.key, required this.controller});
  final CloudController controller;
  @override
  State<CloudScreen> createState() => _CloudScreenState();
}

class _CloudScreenState extends State<CloudScreen> {
  late final TextEditingController _url, _key;
  final _email = TextEditingController(),
      _loginPassword = TextEditingController();
  final _password = TextEditingController(), _repeat = TextEditingController();
  bool _replace = false;
  CloudController get c => widget.controller;
  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: c.url);
    _key = TextEditingController(text: c.publicKey);
  }

  @override
  void dispose() {
    c.forgetPreview();
    for (final field in [
      _url,
      _key,
      _email,
      _loginPassword,
      _password,
      _repeat,
    ]) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> _login() async {
    final password = _loginPassword.text;
    _loginPassword.clear();
    await c.signIn(_url.text, _key.text, _email.text, password);
  }

  Future<void> _check() async {
    if (_password.text.length < 10 ||
        _password.text.length > 256 ||
        _repeat.text != _password.text) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Пароль копии: 10–256 символов. Повтор должен совпадать.',
          ),
        ),
      );
      return;
    }
    final password = _password.text;
    _password.clear();
    _repeat.clear();
    setState(() => _replace = false);
    await c.check(password);
  }

  Widget _counts(String title, BackupData data) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Text(
      '$title\nВалюта: ${data.currency ?? 'не выбрана'} · счетов: ${data.accountCount}\nОпераций: ${data.entryCount} · платежей: ${data.obligationCount}\nПокупок: ${data.purchaseCount} · документов: ${data.documentCount}',
    ),
  );

  String _rowDescription(
    String table,
    Map<String, Object?>? row,
    String currency,
  ) {
    if (row == null) return 'Записи нет';
    if (row['deleted_at'] != null) return 'Удалено';
    if (table == 'settings' && row['key'] == 'analysis_policy') {
      final policy = AnalysisPolicy.fromJson(
        jsonDecode(row['value']! as String) as Map<String, dynamic>,
      );
      return 'Настройки анализа: целей ${policy.profile.goals.length}, долгов ${policy.profile.debts.length}, меток ${policy.profile.annotations.length}';
    }
    if (table == 'settings') return '${row['value']}';
    final body = row['body'] is String
        ? (jsonDecode(row['body']! as String) as Map).cast<String, Object?>()
        : row;
    final name = body['name'] ?? body['note'] ?? body['category'] ?? '';
    final amount =
        body['amountMinor'] ?? body['limit_minor'] ?? body['opening_minor'];
    final date =
        body['date'] ?? body['anchor'] ?? body['due_date'] ?? body['month'];
    return [
      if ('$name'.isNotEmpty) '$name',
      if (amount is int) formatMoney(amount, currency),
      if (date != null) '$date',
      if (table == 'settlements')
        row['status'] == 'paid' ? 'Подтверждён платёж' : 'Пропущен период',
      if (table == 'documents') '${row['size']} байт',
    ].join(' · ');
  }

  List<Widget> _conflicts(SyncPreview plan) => plan.conflicts.take(20).map((
    conflict,
  ) {
    final colon = conflict.indexOf(':');
    if (colon < 0 ||
        !BackupData.columns.containsKey(conflict.substring(0, colon))) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(conflict),
      );
    }
    final table = conflict.substring(0, colon),
        id = conflict.substring(colon + 1);
    Map<String, Object?>? row(BackupData? data) => data?.tables[table]
        ?.where((r) => r[table == 'settings' ? 'key' : 'id'] == id)
        .firstOrNull;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'На устройстве: ${_rowDescription(table, row(plan.local.data), plan.local.data.currency ?? '')}',
          ),
          Text(
            'В облаке: ${_rowDescription(table, row(plan.cloudData), plan.cloudData?.currency ?? '')}',
          ),
        ],
      ),
    );
  }).toList();
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) {
      final plan = c.preview;
      return PopScope(
        canPop: !c.busy,
        child: Scaffold(
          appBar: AppBar(title: const Text('Облачный обмен')),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    Text(
                      'Одна база на ваших устройствах',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Обмен переносит операции, чеки, цели, долги и настройки анализа. Автоматический режим доступен на текущую сессию. Домашний ПК может быть выключен.',
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Нужен личный проект Supabase с установленным cloud/supabase.sql и аккаунтом. Пароль копии шифрует данные до отправки. Используйте один пароль на всех устройствах и сохраните его отдельно.',
                    ),
                    const SizedBox(height: 24),
                    if (!c.signedIn) ...[
                      TextField(
                        key: const Key('cloud-url'),
                        controller: _url,
                        enabled: !c.busy,
                        decoration: const InputDecoration(
                          labelText: 'URL проекта',
                          hintText: 'https://project.supabase.co',
                        ),
                        keyboardType: TextInputType.url,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const Key('cloud-key'),
                        controller: _key,
                        enabled: !c.busy,
                        decoration: const InputDecoration(
                          labelText: 'Publishable / anon ключ',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const Key('cloud-email'),
                        controller: _email,
                        enabled: !c.busy,
                        decoration: const InputDecoration(
                          labelText: 'Email аккаунта',
                        ),
                        keyboardType: TextInputType.emailAddress,
                        autocorrect: false,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const Key('cloud-login-password'),
                        controller: _loginPassword,
                        enabled: !c.busy,
                        obscureText: true,
                        enableSuggestions: false,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: 'Пароль аккаунта',
                        ),
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        key: const Key('cloud-login'),
                        onPressed: c.busy ? null : _login,
                        child: const Text('Войти'),
                      ),
                    ] else ...[
                      Text(
                        c.url,
                        style: const TextStyle(color: LedgerColors.muted),
                      ),
                      const SizedBox(height: 12),
                      SwitchListTile(
                        key: const Key('cloud-auto'),
                        contentPadding: EdgeInsets.zero,
                        value: c.automaticEnabled,
                        onChanged: c.busy ? null : c.setAutomatic,
                        title: const Text('Автоматический обмен в этой сессии'),
                        subtitle: const Text(
                          'После успешного ручного обмена: при изменениях, возвращении в приложение и раз в минуту, пока оно открыто.',
                        ),
                      ),
                      Text(
                        c.automaticReady
                            ? 'Автоматический обмен разблокирован. Пароль хранится в памяти до выключения режима или выхода.'
                            : c.needsAttention
                            ? 'Автоматический обмен приостановлен. Проверьте пароль и данные ниже, затем подтвердите ручной обмен.'
                            : 'Для автоматического режима включите переключатель и выполните ручной обмен. При конфликте потребуется ваше решение.',
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Пароль копии отличается от пароля аккаунта. При первом обмене он задаёт защиту новой копии; при следующих — открывает существующую.',
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const Key('cloud-password'),
                        controller: _password,
                        enabled: !c.busy,
                        obscureText: true,
                        enableSuggestions: false,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: 'Пароль копии',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const Key('cloud-repeat'),
                        controller: _repeat,
                        enabled: !c.busy,
                        obscureText: true,
                        enableSuggestions: false,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: 'Повтор пароля копии',
                        ),
                      ),
                      const SizedBox(height: 16),
                      OutlinedButton(
                        key: const Key('cloud-check'),
                        onPressed: c.busy ? null : _check,
                        child: const Text('Проверить изменения'),
                      ),
                      if (plan != null) ...[
                        const Divider(height: 32),
                        _counts('На устройстве', plan.local.data),
                        if (plan.cloudData != null)
                          _counts(
                            'В облаке · версия ${plan.revision}',
                            plan.cloudData!,
                          ),
                        if (plan.cloudData == null)
                          const Text('Облачная копия ещё не создана.'),
                        const SizedBox(height: 12),
                        if (!plan.needsChoice) ...[
                          _counts('После обмена', plan.merged!),
                          const SizedBox(height: 16),
                          FilledButton(
                            key: const Key('cloud-commit'),
                            onPressed: c.busy ? null : () => c.commit(),
                            child: const Text('Выполнить обмен'),
                          ),
                        ] else ...[
                          const Text(
                            'Нужен выбор полной версии. Автоматически объединить данные безопасно не удалось.',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            'Причин или конфликтующих записей: ${plan.conflicts.length}',
                          ),
                          ..._conflicts(plan),
                          const SizedBox(height: 8),
                          const Text(
                            'Перед заменой сохраняется зашифрованная защитная копия вытесняемой версии. Выбор действует на всю базу, включая операции и документы.',
                          ),
                          CheckboxListTile(
                            key: const Key('cloud-replace-check'),
                            contentPadding: EdgeInsets.zero,
                            value: _replace,
                            onChanged: c.busy
                                ? null
                                : (v) => setState(() => _replace = v!),
                            title: const Text(
                              'Понимаю, что одна полная версия заменит другую',
                            ),
                          ),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              FilledButton(
                                key: const Key('cloud-choose-local'),
                                onPressed: c.busy || !_replace
                                    ? null
                                    : () => c.commit(choice: SyncChoice.local),
                                child: const Text('Использовать эту базу'),
                              ),
                              if (plan.cloudData != null)
                                OutlinedButton(
                                  key: const Key('cloud-choose-remote'),
                                  onPressed: c.busy || !_replace
                                      ? null
                                      : () =>
                                            c.commit(choice: SyncChoice.cloud),
                                  child: const Text('Использовать облачную'),
                                ),
                            ],
                          ),
                        ],
                      ],
                      const SizedBox(height: 16),
                      TextButton(
                        onPressed: c.busy ? null : c.signOut,
                        child: const Text('Выйти из аккаунта'),
                      ),
                    ],
                    const SizedBox(height: 20),
                    if (c.busy) const LinearProgressIndicator(),
                    const SizedBox(height: 12),
                    Text(c.status, key: const Key('cloud-status')),
                    Text(
                      'Изменений в очереди: ${plan?.local.pendingChanges ?? c.vm.snapshot?.pendingChanges ?? 0}',
                    ),
                    if (c.lastSuccess != null)
                      Text(
                        'Последний обмен: ${DateFormat('dd.MM.yyyy HH:mm').format(DateTime.parse(c.lastSuccess!).toLocal())}',
                      ),
                    const SizedBox(height: 20),
                    const Text(
                      'Пароли и сессия хранятся только в памяти. После перезапуска войдите снова. Без подключения учёт продолжает работать локально.',
                      style: TextStyle(color: LedgerColors.muted),
                    ),
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
