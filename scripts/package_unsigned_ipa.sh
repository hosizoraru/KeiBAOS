#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

usage() {
  cat <<'EOF'
Build KeiBA as an unsigned iOS IPA for local sideload smoke testing.

Usage:
  scripts/package_unsigned_ipa.sh [options]

Options:
  --output-dir PATH          Directory for the IPA. Default: .build/artifacts
  --derived-data PATH        DerivedData path. Default: .build/DerivedData/unsigned-ipa
  --spm-cache PATH           SwiftPM cache path. Default: .build/xcode-sourcepackages
  --configuration NAME       Xcode configuration. Default: Release
  --marketing-version X.Y.Z  Override MARKETING_VERSION
  --build-version NUMBER     Override CURRENT_PROJECT_VERSION
  --artifact-slug SLUG       Override IPA version slug
  --sideload-bundle-id ID    Rewrite the IPA payload root bundle id for sideload
  --developer-dir PATH       Export DEVELOPER_DIR for this invocation
  --clean                    Remove the script DerivedData before building
  --skip-package-resolve     Skip explicit Swift package resolution
  -h, --help                 Show this help

The default version values come from scripts/ci/resolve_app_version.sh, matching
GitHub Actions artifact naming. The generated IPA is unsigned and not
TestFlight/App Store ready.
EOF
}

output_dir="$repo_root/.build/artifacts"
derived_data="$repo_root/.build/DerivedData/unsigned-ipa"
spm_cache="$repo_root/.build/xcode-sourcepackages"
configuration="Release"
marketing_version=""
build_version=""
artifact_slug=""
sideload_bundle_id=""
clean=0
skip_package_resolve=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      output_dir="$2"
      shift 2
      ;;
    --derived-data)
      derived_data="$2"
      shift 2
      ;;
    --spm-cache)
      spm_cache="$2"
      shift 2
      ;;
    --configuration)
      configuration="$2"
      shift 2
      ;;
    --marketing-version)
      marketing_version="$2"
      shift 2
      ;;
    --build-version)
      build_version="$2"
      shift 2
      ;;
    --artifact-slug)
      artifact_slug="$2"
      shift 2
      ;;
    --sideload-bundle-id)
      sideload_bundle_id="$2"
      shift 2
      ;;
    --developer-dir)
      export DEVELOPER_DIR="$2"
      shift 2
      ;;
    --clean)
      clean=1
      shift
      ;;
    --skip-package-resolve)
      skip_package_resolve=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

resolve_value() {
  local key="$1"
  printf '%s\n' "$version_output" | awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2); exit }'
}

version_output="$("$repo_root/scripts/ci/resolve_app_version.sh")"
marketing_version="${marketing_version:-$(resolve_value marketing_version)}"
build_version="${build_version:-$(resolve_value build_version)}"
artifact_slug="${artifact_slug:-$(resolve_value artifact_slug)}"

if [[ -z "$marketing_version" || -z "$build_version" || -z "$artifact_slug" ]]; then
  echo "error: failed to resolve version metadata" >&2
  printf '%s\n' "$version_output" >&2
  exit 1
fi

echo "KeiBA unsigned IPA"
echo "  marketing version: $marketing_version"
echo "  build version:     $build_version"
echo "  artifact slug:     $artifact_slug"
echo "  output dir:        $output_dir"
echo "  derived data:      $derived_data"
echo "  SwiftPM cache:     $spm_cache"
if [[ -n "$sideload_bundle_id" ]]; then
  echo "  sideload bundle:   $sideload_bundle_id"
fi
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  echo "  DEVELOPER_DIR:     $DEVELOPER_DIR"
fi

export APP_MARKETING_VERSION="$marketing_version"
export APP_BUILD_VERSION="$build_version"
export ARTIFACT_SLUG="$artifact_slug"
export ARTIFACTS_DIR="$output_dir"
export DERIVED_DATA_PATH="$derived_data"
export SWIFTPM_CACHE_PATH="$spm_cache"
export CONFIGURATION="$configuration"
export CLEAN_DERIVED_DATA="$clean"
export SKIP_PACKAGE_RESOLVE="$skip_package_resolve"
export SIDELOAD_BUNDLE_ID="$sideload_bundle_id"

"$repo_root/scripts/ci/build_unsigned_ipa.sh"
