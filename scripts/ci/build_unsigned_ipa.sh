#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

usage() {
  cat <<'EOF'
Build an unsigned iOS IPA payload for KeiBA.

This script is intentionally CI-friendly. Prefer scripts/package_unsigned_ipa.sh
for local use because it resolves version metadata and chooses .build paths.

Required environment:
  APP_MARKETING_VERSION      CFBundleShortVersionString / MARKETING_VERSION
  APP_BUILD_VERSION          CFBundleVersion / CURRENT_PROJECT_VERSION
  ARTIFACT_SLUG              Artifact filename version slug

Optional environment:
  PROJECT_PATH               Default: <repo>/KeiBA.xcodeproj
  SCHEME                     Default: KeiBA
  CONFIGURATION              Default: Release
  DERIVED_DATA_PATH          Default: ${RUNNER_TEMP:-<repo>/.build}/KeiBA-iOS-Device
  ARTIFACTS_DIR              Default: ${RUNNER_TEMP:-<repo>/.build}/KeiBA-artifacts
  SWIFTPM_CACHE_PATH         Default: <repo>/.build/xcode-sourcepackages
  IPA_BASENAME               Default: KeiBA-iOS-${ARTIFACT_SLUG}-unsigned.ipa
  SIDELOAD_BUNDLE_ID         Optional root bundle id for sideload-only payloads
  XCODEBUILD                 Default: xcodebuild
  SKIP_PACKAGE_RESOLVE       Set to 1 to skip explicit package resolution
  CLEAN_DERIVED_DATA         Set to 1 to remove DERIVED_DATA_PATH first

Output:
  Prints ipa_path=<absolute path> and writes the same key to GITHUB_OUTPUT when
  running in GitHub Actions.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "error: $name is required" >&2
    usage >&2
    exit 64
  fi
}

require_env APP_MARKETING_VERSION
require_env APP_BUILD_VERSION
require_env ARTIFACT_SLUG

default_work_root="${RUNNER_TEMP:-$repo_root/.build}"
project_path="${PROJECT_PATH:-$repo_root/KeiBA.xcodeproj}"
scheme="${SCHEME:-KeiBA}"
configuration="${CONFIGURATION:-Release}"
derived_data="${DERIVED_DATA_PATH:-$default_work_root/KeiBA-iOS-Device}"
artifacts_dir="${ARTIFACTS_DIR:-$default_work_root/KeiBA-artifacts}"
swiftpm_cache="${SWIFTPM_CACHE_PATH:-$repo_root/.build/xcode-sourcepackages}"
ipa_basename="${IPA_BASENAME:-KeiBA-iOS-$ARTIFACT_SLUG-unsigned.ipa}"
xcodebuild_bin="${XCODEBUILD:-xcodebuild}"
sideload_bundle_id="${SIDELOAD_BUNDLE_ID:-}"

absolute_path() {
  local path="$1"
  if [[ "$path" == /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$PWD" "$path"
  fi
}

project_path="$(absolute_path "$project_path")"
derived_data="$(absolute_path "$derived_data")"
artifacts_dir="$(absolute_path "$artifacts_dir")"
swiftpm_cache="$(absolute_path "$swiftpm_cache")"

if [[ "$ipa_basename" == */* ]]; then
  echo "error: IPA_BASENAME must be a filename, not a path: $ipa_basename" >&2
  exit 64
fi

validate_bundle_identifier() {
  local bundle_id="$1"
  if [[ ! "$bundle_id" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]] \
    || [[ "$bundle_id" != *.* ]] \
    || [[ "$bundle_id" == *..* ]]; then
    echo "error: invalid bundle identifier: $bundle_id" >&2
    exit 64
  fi
}

plist_get() {
  local plist_path="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist_path" 2>/dev/null || true
}

plist_set_string() {
  local plist_path="$1"
  local key="$2"
  local value="$3"
  /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist_path" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :$key string $value" "$plist_path" >/dev/null
}

bundle_identifier() {
  local bundle_path="$1"
  plist_get "$bundle_path/Info.plist" CFBundleIdentifier
}

replacement_bundle_identifier() {
  local current_id="$1"
  local old_prefix="$2"
  local new_prefix="$3"

  if [[ "$current_id" == "$old_prefix" ]]; then
    printf '%s\n' "$new_prefix"
  elif [[ "$current_id" == "$old_prefix."* ]]; then
    printf '%s%s\n' "$new_prefix" "${current_id#"$old_prefix"}"
  else
    printf '%s\n' "$current_id"
  fi
}

rewrite_bundle_identifier_with_prefix() {
  local bundle_path="$1"
  local old_prefix="$2"
  local new_prefix="$3"
  local label="$4"
  local current_id
  local new_id

  current_id="$(bundle_identifier "$bundle_path")"
  if [[ -z "$current_id" ]]; then
    echo "warning: $label has no CFBundleIdentifier: $bundle_path" >&2
    return 0
  fi

  new_id="$(replacement_bundle_identifier "$current_id" "$old_prefix" "$new_prefix")"
  if [[ "$new_id" == "$current_id" ]]; then
    echo "warning: $label bundle id is not under $old_prefix: $current_id" >&2
    return 0
  fi

  plist_set_string "$bundle_path/Info.plist" CFBundleIdentifier "$new_id"
}

rewrite_payload_for_sideload() {
  local payload_app="$1"
  local new_root_id="$2"
  local app_plist="$payload_app/Info.plist"
  local old_root_id

  validate_bundle_identifier "$new_root_id"

  old_root_id="$(plist_get "$app_plist" CFBundleIdentifier)"
  if [[ -z "$old_root_id" ]]; then
    echo "error: app bundle has no CFBundleIdentifier: $app_plist" >&2
    exit 1
  fi

  echo "Rewriting sideload bundle root: $old_root_id -> $new_root_id"
  plist_set_string "$app_plist" CFBundleIdentifier "$new_root_id"

  if [[ -d "$payload_app/PlugIns" ]]; then
    while IFS= read -r -d '' extension_path; do
      rewrite_bundle_identifier_with_prefix "$extension_path" "$old_root_id" "$new_root_id" "app extension"
    done < <(find "$payload_app/PlugIns" -maxdepth 1 -type d -name '*.appex' -print0)
  fi

  if [[ -d "$payload_app/Watch" ]]; then
    while IFS= read -r -d '' watch_app_path; do
      local old_watch_id
      local new_watch_id
      old_watch_id="$(bundle_identifier "$watch_app_path")"
      if [[ -z "$old_watch_id" ]]; then
        echo "warning: Watch app has no CFBundleIdentifier: $watch_app_path" >&2
        continue
      fi

      new_watch_id="$(replacement_bundle_identifier "$old_watch_id" "$old_root_id" "$new_root_id")"
      if [[ "$new_watch_id" == "$old_watch_id" ]]; then
        echo "warning: Watch app bundle id is not under $old_root_id: $old_watch_id" >&2
      else
        plist_set_string "$watch_app_path/Info.plist" CFBundleIdentifier "$new_watch_id"
      fi
      plist_set_string "$watch_app_path/Info.plist" WKCompanionAppBundleIdentifier "$new_root_id"

      if [[ -d "$watch_app_path/PlugIns" ]]; then
        while IFS= read -r -d '' watch_extension_path; do
          rewrite_bundle_identifier_with_prefix "$watch_extension_path" "$old_watch_id" "$new_watch_id" "Watch extension"
        done < <(find "$watch_app_path/PlugIns" -maxdepth 1 -type d -name '*.appex' -print0)
      fi
    done < <(find "$payload_app/Watch" -maxdepth 1 -type d -name '*.app' -print0)
  fi
}

if [[ "${CLEAN_DERIVED_DATA:-0}" == "1" ]]; then
  rm -rf "$derived_data"
fi

mkdir -p "$artifacts_dir" "$swiftpm_cache"

if [[ "${SKIP_PACKAGE_RESOLVE:-0}" != "1" ]]; then
  "$xcodebuild_bin" -resolvePackageDependencies \
    -project "$project_path" \
    -scheme "$scheme" \
    -clonedSourcePackagesDirPath "$swiftpm_cache"
fi

"$xcodebuild_bin" build \
  -project "$project_path" \
  -scheme "$scheme" \
  -configuration "$configuration" \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$derived_data" \
  -clonedSourcePackagesDirPath "$swiftpm_cache" \
  MARKETING_VERSION="$APP_MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$APP_BUILD_VERSION" \
  CODE_SIGNING_ALLOWED=NO

app_path="$derived_data/Build/Products/$configuration-iphoneos/KeiBA.app"
payload_root="$artifacts_dir/iphoneos"
payload_dir="$payload_root/Payload"
ipa_path="$artifacts_dir/$ipa_basename"

if [[ ! -d "$app_path" ]]; then
  echo "error: expected app bundle was not produced: $app_path" >&2
  exit 1
fi

rm -rf "$payload_root" "$ipa_path"
mkdir -p "$payload_dir"
ditto "$app_path" "$payload_dir/KeiBA.app"

if [[ -n "$sideload_bundle_id" ]]; then
  rewrite_payload_for_sideload "$payload_dir/KeiBA.app" "$sideload_bundle_id"
fi

(
  cd "$payload_root"
  COPYFILE_DISABLE=1 zip -qry "$ipa_path" Payload
)

if [[ ! -f "$ipa_path" ]]; then
  echo "error: IPA was not produced: $ipa_path" >&2
  exit 1
fi

du -h "$ipa_path"
printf 'ipa_path=%s\n' "$ipa_path"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'ipa_path=%s\n' "$ipa_path" >> "$GITHUB_OUTPUT"
fi
