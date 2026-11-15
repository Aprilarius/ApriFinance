# Android: ApriFinance 1.0

Версия исходников 1.0.0+18, applicationId `com.bahadur.personal_finance` сохранён. ARM64 preview рассчитан на Android 7.0+ (API 24), target/compile API 36. Требуются Flutter 3.50.0, Java 17, Android SDK; версии зависимостей закреплены в pubspec.lock. AGP 9.3.3, Gradle 9.5, desugar_jdk_libs 2.1.5. Изменения интерфейса: [Android UI-аудит](../docs/android-ui-audit-1.0.md). Раздел: [первый выпуск анализа](../docs/insights-implementation-1.0.md) и [расширение build 14](../docs/insights-expansion-1.0.md), [повторения build 15](../docs/insights-patterns-1.0.md), [серии build 16](../docs/insights-series-1.0.md), [календарные сценарии build 17](../docs/insights-calendar-1.0.md).

## Локальная проверка

Из корня Flutter-проекта:

```powershell
flutter pub get
flutter analyze
flutter test
flutter build apk --debug --target-platform android-arm64
python android/verify_apk.py build/app/outputs/flutter-apk/app-debug.apk
./android/audit.ps1
```

`audit.ps1` запускает Android Lint после сборки и экранирует двоеточия только в сгенерированных Windows-путях SDK в local.properties. Установите JAVA_HOME на JDK 17. Верификатор APK использует стандартную библиотеку Python 3, проверяет CRC, полноту ARM64-библиотек и ELF-выравнивание 16 KiB. Дополнительно: `zipalign -c -P 16 -v 4 <apk>` и `apksigner verify --verbose --print-certs <apk>` из Android build-tools.

Для x64-эмулятора выбирайте `--target-platform android-x64`; для нескольких архитектур — соответствующий список через запятую. Gradle исключает библиотеки невыбранных архитектур. verify_apk.py намеренно предназначен только для выдаваемого ARM64 APK.

## Постоянная release-подпись

Preview использует debug-сертификат и не заменяет подписанный постоянным ключом выпуск. Для будущих обновлений нужно хранить один постоянный ключ и его резервную копию. Release больше не подставляет debug-ключ автоматически.

Скопируйте key.properties.example в приватный android/key.properties, укажите реальный путь и реквизиты ключа. Альтернатива — переменные окружения APRI_ANDROID_KEYSTORE, APRI_ANDROID_STORE_PASSWORD, APRI_ANDROID_KEY_ALIAS, APRI_ANDROID_KEY_PASSWORD. Переменные имеют приоритет. Не включайте реквизиты и keystore в исходники и отчёты.

```powershell
flutter build apk --release --target-platform android-arm64
python android/verify_apk.py build/app/outputs/flutter-apk/app-release.apk
./android/audit.ps1 -Variant Release
```

Без ключа упаковка release завершается явной ошибкой. Переход с debug на другой сертификат не является обычным обновлением Android: заранее экспортируйте зашифрованную .mfin-копию; не удаляйте приложение с единственной базой. Удаление приложения удаляет его закрытые данные.

Release Lint запускайте сразу после release-сборки: Flutter-команды для разработки могут заново добавить integration_test в генерируемый Android-регистратор. Если скрипт обнаружит этот случай, он предложит повторить release-сборку. Для проверки обоих вариантов порядок: release build → release Lint → debug build/Lint. Генерируемый регистратор в архив исходников не входит.

## Проверка на телефоне

Проверить создание/редактирование операций, поворот и клавиатуру, импорт/экспорт .mfin через системный файловый диалог, вложения, отказ и выдачу разрешения уведомлений, отключение именно канала «Платежи и сроки», доставку после перезапуска телефона. Напоминания неточные: система может задерживать их, особенно при ограничении батареи; точные будильники не запрашиваются. После смены часового пояса откройте приложение для перепланирования.

Физический Android и эмулятор в текущем аудите не запускались. Системное резервирование и перенос исключены явно; перенос между устройствами пока выполняется пользователем через зашифрованную копию. Синхронизация отложена.

## Build 18

Все 90 правил и формы явных данных: [итоговый отчёт](../docs/insights-complete-1.0.md). Цели, долги, серии и настройки включены в зашифрованную .mfin schema 5. Синхронизация анализа не подключена. Preview подписан прежним debug-ключом; release с временным QA-ключом только для проверки. Физическое устройство пока не проверено.
