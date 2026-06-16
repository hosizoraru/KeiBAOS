#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/keiba-unsigned-ipa-test.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

plistbuddy=/usr/libexec/PlistBuddy

write_plist() {
  local plist_path="$1"
  local bundle_id="$2"
  local executable="${3:-KeiBA}"
  mkdir -p "$(dirname "$plist_path")"
  "$plistbuddy" -c 'Clear dict' "$plist_path" >/dev/null 2>&1
  "$plistbuddy" -c "Add :CFBundleIdentifier string $bundle_id" "$plist_path"
  "$plistbuddy" -c "Add :CFBundleExecutable string $executable" "$plist_path"
  "$plistbuddy" -c 'Add :CFBundleDisplayName string KeiBA' "$plist_path"
  "$plistbuddy" -c 'Add :CFBundleShortVersionString string 1.0.1' "$plist_path"
  "$plistbuddy" -c 'Add :CFBundleVersion string 1' "$plist_path"
}

set_plist_value() {
  local plist_path="$1"
  local key="$2"
  local value="$3"
  "$plistbuddy" -c "Set :$key $value" "$plist_path" 2>/dev/null \
    || "$plistbuddy" -c "Add :$key string $value" "$plist_path"
}

make_payload_tree() {
  local root="$1"
  local app_bundle_id="$2"
  local ios_widget_bundle_id="$3"
  local watch_bundle_id="$4"
  local watch_widget_bundle_id="$5"

  local app_path="$root/Payload/KeiBA.app"
  local ios_widget_path="$app_path/PlugIns/KeiBAiOSWidgetsExtension.appex"
  local watch_path="$app_path/Watch/KeiBAWatch.app"
  local watch_widget_path="$watch_path/PlugIns/KeiBAWatchWidgets.appex"

  write_plist "$app_path/Info.plist" "$app_bundle_id"
  write_plist "$ios_widget_path/Info.plist" "$ios_widget_bundle_id" KeiBAiOSWidgetsExtension
  write_plist "$watch_path/Info.plist" "$watch_bundle_id" KeiBAWatch
  set_plist_value "$watch_path/Info.plist" WKCompanionAppBundleIdentifier "$app_bundle_id"
  write_plist "$watch_widget_path/Info.plist" "$watch_widget_bundle_id" KeiBAWatchWidgets
}

make_ipa() {
  local payload_root="$1"
  local ipa_path="$2"
  (
    cd "$payload_root"
    COPYFILE_DISABLE=1 zip -qry "$ipa_path" Payload
  )
}

assert_contains() {
  local file_path="$1"
  local pattern="$2"
  if ! grep -Fq "$pattern" "$file_path"; then
    echo "expected output to contain: $pattern" >&2
    echo "--- output ---" >&2
    cat "$file_path" >&2
    exit 1
  fi
}

run_inspector() {
  local ipa_path="$1"
  local output_path="$2"
  set +e
  "$repo_root/scripts/inspect_unsigned_ipa.sh" "$ipa_path" >"$output_path" 2>&1
  local status=$?
  set -e
  return "$status"
}

test_inspector_rejects_mismatched_watch_extension_prefix() {
  local payload_root="$tmp_dir/invalid-watch-prefix"
  local ipa_path="$tmp_dir/invalid-watch-prefix.ipa"
  local output_path="$tmp_dir/invalid-watch-prefix.out"

  make_payload_tree \
    "$payload_root" \
    os.kei.KeiBA.3CKCL389SP \
    os.kei.KeiBA.3CKCL389SP.KeiBAiOSWidgets \
    os.kei.KeiBA.3CKCL389SP.watchkitapp \
    os.kei.KeiBA.watchkitapp.widgets
  make_ipa "$payload_root" "$ipa_path"

  if run_inspector "$ipa_path" "$output_path"; then
    echo "expected inspector to reject mismatched Watch widget bundle prefix" >&2
    cat "$output_path" >&2
    exit 1
  fi

  assert_contains "$output_path" "Bundle nesting: invalid"
  assert_contains "$output_path" "KeiBA.app/Watch/KeiBAWatch.app/PlugIns/KeiBAWatchWidgets.appex"
  assert_contains "$output_path" "expected prefix os.kei.KeiBA.3CKCL389SP.watchkitapp."
}

test_inspector_accepts_valid_nested_bundle_prefixes() {
  local payload_root="$tmp_dir/valid-prefixes"
  local ipa_path="$tmp_dir/valid-prefixes.ipa"
  local output_path="$tmp_dir/valid-prefixes.out"

  make_payload_tree \
    "$payload_root" \
    os.kei.KeiBA \
    os.kei.KeiBA.KeiBAiOSWidgets \
    os.kei.KeiBA.watchkitapp \
    os.kei.KeiBA.watchkitapp.widgets
  make_ipa "$payload_root" "$ipa_path"

  if ! run_inspector "$ipa_path" "$output_path"; then
    echo "expected inspector to accept valid nested bundle prefixes" >&2
    cat "$output_path" >&2
    exit 1
  fi

  assert_contains "$output_path" "Bundle nesting: ok"
}

test_packaging_rewrites_sideload_bundle_tree() {
  local derived_data="$tmp_dir/DerivedData"
  local artifacts="$tmp_dir/artifacts"
  local app_path="$derived_data/Build/Products/Release-iphoneos/KeiBA.app"
  local output_path="$tmp_dir/package-rewrite.out"
  local inspect_path="$tmp_dir/package-rewrite-inspect.out"
  local ipa_path="$artifacts/KeiBA-iOS-sideload-fixture-unsigned.ipa"

  make_payload_tree \
    "$derived_data/Build/Products/Release-iphoneos" \
    os.kei.KeiBA \
    os.kei.KeiBA.KeiBAiOSWidgets \
    os.kei.KeiBA.watchkitapp \
    os.kei.KeiBA.watchkitapp.widgets
  mv "$derived_data/Build/Products/Release-iphoneos/Payload/KeiBA.app" "$app_path"
  rmdir "$derived_data/Build/Products/Release-iphoneos/Payload"

  APP_MARKETING_VERSION=1.0.1 \
  APP_BUILD_VERSION=1 \
  ARTIFACT_SLUG=sideload-fixture \
  SIDELOAD_BUNDLE_ID=os.kei.KeiBA.3CKCL389SP \
  DERIVED_DATA_PATH="$derived_data" \
  ARTIFACTS_DIR="$artifacts" \
  SWIFTPM_CACHE_PATH="$tmp_dir/spm-cache" \
  SKIP_PACKAGE_RESOLVE=1 \
  XCODEBUILD=/usr/bin/true \
    "$repo_root/scripts/ci/build_unsigned_ipa.sh" >"$output_path" 2>&1

  "$repo_root/scripts/inspect_unsigned_ipa.sh" "$ipa_path" >"$inspect_path"

  assert_contains "$inspect_path" "Bundle ID: os.kei.KeiBA.3CKCL389SP"
  assert_contains "$inspect_path" "KeiBA.app/Watch/KeiBAWatch.app -> os.kei.KeiBA.3CKCL389SP.watchkitapp"
  assert_contains "$inspect_path" "KeiBA.app/Watch/KeiBAWatch.app/PlugIns/KeiBAWatchWidgets.appex -> os.kei.KeiBA.3CKCL389SP.watchkitapp.widgets"
  assert_contains "$inspect_path" "Bundle nesting: ok"
}

test_packaging_accepts_relative_artifacts_dir() {
  local work_dir="$tmp_dir/relative-output-work"
  local derived_data="$tmp_dir/relative-output-DerivedData"
  local app_path="$derived_data/Build/Products/Release-iphoneos/KeiBA.app"
  local output_path="$tmp_dir/relative-output.out"
  local ipa_path="$work_dir/relative-artifacts/KeiBA-iOS-relative-output-unsigned.ipa"

  mkdir -p "$work_dir"
  make_payload_tree \
    "$derived_data/Build/Products/Release-iphoneos" \
    os.kei.KeiBA \
    os.kei.KeiBA.KeiBAiOSWidgets \
    os.kei.KeiBA.watchkitapp \
    os.kei.KeiBA.watchkitapp.widgets
  mv "$derived_data/Build/Products/Release-iphoneos/Payload/KeiBA.app" "$app_path"
  rmdir "$derived_data/Build/Products/Release-iphoneos/Payload"

  set +e
  (
    cd "$work_dir"
    APP_MARKETING_VERSION=1.0.1 \
    APP_BUILD_VERSION=1 \
    ARTIFACT_SLUG=relative-output \
    DERIVED_DATA_PATH="$derived_data" \
    ARTIFACTS_DIR=relative-artifacts \
    SWIFTPM_CACHE_PATH="$tmp_dir/spm-cache-relative" \
    SKIP_PACKAGE_RESOLVE=1 \
    XCODEBUILD=/usr/bin/true \
      "$repo_root/scripts/ci/build_unsigned_ipa.sh" >"$output_path" 2>&1
  )
  local status=$?
  set -e

  if [[ "$status" -ne 0 ]]; then
    echo "expected packaging to accept relative ARTIFACTS_DIR" >&2
    cat "$output_path" >&2
    exit 1
  fi

  if [[ ! -f "$ipa_path" ]]; then
    echo "expected IPA to be written under relative ARTIFACTS_DIR: $ipa_path" >&2
    cat "$output_path" >&2
    exit 1
  fi
}

test_inspector_rejects_mismatched_watch_extension_prefix
test_inspector_accepts_valid_nested_bundle_prefixes
test_packaging_rewrites_sideload_bundle_tree
test_packaging_accepts_relative_artifacts_dir

echo "unsigned IPA fixture tests passed"
