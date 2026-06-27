#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESTINATION_DIR="/Users/macmini/Documents/code-proj/flask-proj/flask_web_backend/app/static/downloads/android"
OUTPUT_BASE_NAME="flask_call_app"
KEY_PROPERTIES_PATH="$SCRIPT_DIR/android/key.properties"
PRODUCTION_URL="https://web.flask-call-app.site/"


usage() {
  cat <<'EOF'
Usage: ./final_build_apk.sh [--destination-dir DIR] [--output-base-name NAME]

Options:
  --destination-dir, -d  Destination folder for copied APK.
  --output-base-name, -n Base name for generated APK file.
  --help, -h             Show this help message.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --destination-dir|-d)
      DESTINATION_DIR="${2:-}"
      shift 2
      ;;
    --output-base-name|-n)
      OUTPUT_BASE_NAME="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if ! command -v flutter >/dev/null 2>&1; then
  echo "Error: flutter not found in PATH." >&2
  exit 1
fi

if [[ ! -f "$KEY_PROPERTIES_PATH" ]]; then
  echo "Error: Release signing is not configured." >&2
  echo "Create $KEY_PROPERTIES_PATH with storeFile/storePassword/keyAlias/keyPassword." >&2
  exit 1
fi

PUBSPEC_PATH="$SCRIPT_DIR/pubspec.yaml"
if [[ ! -f "$PUBSPEC_PATH" ]]; then
  echo "Error: pubspec.yaml not found in project root." >&2
  exit 1
fi

raw_version="$(grep -E '^version:[[:space:]]*' "$PUBSPEC_PATH" | head -n1 | sed -E 's/^version:[[:space:]]*//')"
if [[ -z "$raw_version" ]]; then
  echo "Error: Could not parse version from pubspec.yaml." >&2
  exit 1
fi

version_name="$raw_version"
build_suffix=""
if [[ "$raw_version" =~ ^([^+]+)\+([0-9]+)$ ]]; then
  version_name="${BASH_REMATCH[1]}"
  build_suffix="_build${BASH_REMATCH[2]}"
fi

to_safe_part() {
  echo "$1" | tr '[:space:]/\\<>:"|?*' '-' | tr -s '-'
}

safe_app_name="$(to_safe_part "$OUTPUT_BASE_NAME")"
safe_version="$(to_safe_part "$version_name")"

target_file_name="${safe_app_name}_${safe_version}${build_suffix}.apk"

printf '========================================\n'
printf 'Final Build APK (Release + Copy)\n'
printf '========================================\n'
printf 'Output base name: %s\n' "$OUTPUT_BASE_NAME"
printf 'Version: %s\n' "$raw_version"
printf 'Target file: %s\n' "$target_file_name"
printf 'Destination: %s\n\n' "$DESTINATION_DIR"

echo "Updating API config to production URL..."
API_CONFIG_PATH="$SCRIPT_DIR/lib/config/api_config.dart"
if [[ ! -f "$API_CONFIG_PATH" ]]; then
  echo "Error: api_config.dart not found at $API_CONFIG_PATH" >&2
  exit 1
fi
sed -i '' "s|defaultValue: '[^']*'|defaultValue: '$PRODUCTION_URL'|g" "$API_CONFIG_PATH"
echo "  Set defaultValue → $PRODUCTION_URL"

echo "Running Flutter release build..."
flutter clean
flutter pub get
echo "Using release BASE_URL: $PRODUCTION_URL"
echo ".env.json is ignored for this release build."
flutter build apk --release --dart-define="BASE_URL=$PRODUCTION_URL"

source_apk_path="$SCRIPT_DIR/build/app/outputs/flutter-apk/app-release.apk"
if [[ ! -f "$source_apk_path" ]]; then
  echo "Error: Release APK not found at expected path: $source_apk_path" >&2
  exit 1
fi

mkdir -p "$DESTINATION_DIR"

destination_apk_path="$DESTINATION_DIR/$target_file_name"
cp -f "$source_apk_path" "$destination_apk_path"

apk_size_bytes="$(stat -f%z "$destination_apk_path")"
apk_size_mb="$(awk -v b="$apk_size_bytes" 'BEGIN { printf "%.2f", b/1024/1024 }')"

printf '\n========================================\n'
printf 'Build and transfer complete\n'
printf 'Saved APK: %s\n' "$destination_apk_path"
printf 'Size: %s MB\n' "$apk_size_mb"
printf '========================================\n'
