#!/bin/bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
signing_dir=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/apri-signing.XXXXXX")
trap 'rm -f -- "$signing_dir/key.jks"; rmdir -- "$signing_dir"' EXIT
export APRI_ANDROID_KEYSTORE="$signing_dir/key.jks"
if [[ -n "${APRI_ANDROID_KEYSTORE_BASE64:-}" ]]; then
  : "${APRI_ANDROID_STORE_PASSWORD:?Missing signing password}"
  : "${APRI_ANDROID_KEY_ALIAS:?Missing signing alias}"
  : "${APRI_ANDROID_KEY_PASSWORD:?Missing key password}"
  printf '%s' "$APRI_ANDROID_KEYSTORE_BASE64" | base64 --decode > "$APRI_ANDROID_KEYSTORE"
else
  if [[ -n "${APRI_ANDROID_STORE_PASSWORD:-}${APRI_ANDROID_KEY_ALIAS:-}${APRI_ANDROID_KEY_PASSWORD:-}" ]]; then
    echo 'Incomplete signing configuration' >&2; exit 1
  fi
  export APRI_ANDROID_STORE_PASSWORD="$(openssl rand -base64 48)"
  export APRI_ANDROID_KEY_PASSWORD="$APRI_ANDROID_STORE_PASSWORD"
  export APRI_ANDROID_KEY_ALIAS='apri-preview'
  printf '::add-mask::%s\n' "$APRI_ANDROID_STORE_PASSWORD"
  keytool -genkeypair -noprompt -keystore "$APRI_ANDROID_KEYSTORE" \
    -storepass:env APRI_ANDROID_STORE_PASSWORD -keypass:env APRI_ANDROID_KEY_PASSWORD \
    -alias "$APRI_ANDROID_KEY_ALIAS" -keyalg RSA -keysize 3072 -validity 3650 \
    -dname 'CN=ApriFinance Preview, O=Bahadur'
fi
flutter pub get --enforce-lockfile
flutter build apk --release --target-platform android-arm64
apk='build/app/outputs/flutter-apk/app-release.apk'
python3 android/verify_apk.py "$apk"
python3 scripts/check-publication.py --archive "$apk"
tools="$ANDROID_HOME/build-tools/36.0.0"
"$tools/zipalign" -c -P 16 4 "$apk"
"$tools/apksigner" verify --verbose "$apk"
badging=$("$tools/aapt2" dump badging "$apk")
if [[ "$badging" == *application-debuggable* ]]; then
  echo 'Refusing to publish a debuggable APK' >&2; exit 1
fi
mkdir -p dist
cp "$apk" dist/ApriFinance-1.0.0-Android-arm64-preview.apk
sha256sum dist/*.apk > dist/SHA256SUMS-Android.txt
