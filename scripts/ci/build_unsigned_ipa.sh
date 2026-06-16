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

if [[ "$ipa_basename" == */* ]]; then
  echo "error: IPA_BASENAME must be a filename, not a path: $ipa_basename" >&2
  exit 64
fi

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
