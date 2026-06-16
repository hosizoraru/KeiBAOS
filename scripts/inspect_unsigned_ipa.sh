#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Inspect a KeiBA unsigned IPA.

Usage:
  scripts/inspect_unsigned_ipa.sh PATH_TO_IPA [PATH_TO_IPA ...]

Checks that the IPA has a Payload/*.app root, prints bundle metadata, lists
embedded extensions/watch content, and reports whether _CodeSignature folders
are present.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 64
fi

inspect_ipa() {
  local ipa_path="$1"
  if [[ ! -f "$ipa_path" ]]; then
    echo "error: IPA not found: $ipa_path" >&2
    return 66
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/keiba-ipa.XXXXXX")"
  trap 'rm -rf "$tmp_dir"' RETURN

  ditto -xk "$ipa_path" "$tmp_dir"

  local app_path
  app_path="$(find "$tmp_dir/Payload" -maxdepth 1 -type d -name '*.app' -print | head -n 1 || true)"
  if [[ -z "$app_path" ]]; then
    echo "error: IPA does not contain Payload/*.app" >&2
    return 1
  fi

  local plist="$app_path/Info.plist"
  if [[ ! -f "$plist" ]]; then
    echo "error: app bundle does not contain Info.plist: $app_path" >&2
    return 1
  fi

  plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null || true
  }

  local bundle_id short_version build_version display_name executable sha256
  bundle_id="$(plist_value CFBundleIdentifier)"
  short_version="$(plist_value CFBundleShortVersionString)"
  build_version="$(plist_value CFBundleVersion)"
  display_name="$(plist_value CFBundleDisplayName)"
  executable="$(plist_value CFBundleExecutable)"
  sha256="$(shasum -a 256 "$ipa_path" | awk '{print $1}')"

  echo "IPA: $ipa_path"
  echo "Size: $(du -h "$ipa_path" | awk '{print $1}')"
  echo "SHA-256: $sha256"
  echo "App: $(basename "$app_path")"
  echo "Bundle ID: ${bundle_id:-unknown}"
  echo "Display name: ${display_name:-unknown}"
  echo "Executable: ${executable:-unknown}"
  echo "Version: ${short_version:-unknown} (${build_version:-unknown})"

  echo
  echo "Embedded bundles:"
  find "$app_path" -maxdepth 5 \
    \( -path "$app_path" -o -name '*.appex' -o -name '*.app' \) \
    -type d -print | sed "s#^$app_path#KeiBA.app#"

  echo
  if find "$app_path" -type d -name '_CodeSignature' -print -quit | grep -q .; then
    echo "Code signatures: _CodeSignature folders are present"
  else
    echo "Code signatures: none found"
  fi
}

for ipa_path in "$@"; do
  inspect_ipa "$ipa_path"
  if [[ "$ipa_path" != "${!#}" ]]; then
    echo
    echo "---"
    echo
  fi
done
