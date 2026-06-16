#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Inspect a KeiBA unsigned IPA.

Usage:
  scripts/inspect_unsigned_ipa.sh [--impactor-team-id TEAM_ID] PATH_TO_IPA [PATH_TO_IPA ...]

Checks that the IPA has a Payload/*.app root, prints bundle metadata, lists
embedded extensions/watch content, verifies nested bundle identifier prefixes,
and reports whether _CodeSignature folders are present.

Options:
  --impactor-team-id TEAM_ID  Also verify the package shape expected after
                              Impactor appends TEAM_ID to the root app id.
EOF
}

impactor_team_id=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --impactor-team-id)
      impactor_team_id="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 64
fi

validate_team_identifier() {
  local team_id="$1"
  if [[ ! "$team_id" =~ ^[A-Za-z0-9]+$ ]]; then
    echo "error: invalid team identifier: $team_id" >&2
    exit 64
  fi
}

if [[ -n "$impactor_team_id" ]]; then
  validate_team_identifier "$impactor_team_id"
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

  plist_value_from() {
    local plist_path="$1"
    local key="$2"
    /usr/libexec/PlistBuddy -c "Print :$key" "$plist_path" 2>/dev/null || true
  }

  bundle_id_for_path() {
    local bundle_path="$1"
    plist_value_from "$bundle_path/Info.plist" CFBundleIdentifier
  }

  relative_bundle_path() {
    local bundle_path="$1"
    printf 'KeiBA.app%s\n' "${bundle_path#"$app_path"}"
  }

  local bundle_id short_version build_version display_name executable sha256
  bundle_id="$(plist_value_from "$plist" CFBundleIdentifier)"
  short_version="$(plist_value_from "$plist" CFBundleShortVersionString)"
  build_version="$(plist_value_from "$plist" CFBundleVersion)"
  display_name="$(plist_value_from "$plist" CFBundleDisplayName)"
  executable="$(plist_value_from "$plist" CFBundleExecutable)"
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
  while IFS= read -r -d '' embedded_bundle_path; do
    local embedded_id
    embedded_id="$(bundle_id_for_path "$embedded_bundle_path")"
    if [[ -n "$embedded_id" ]]; then
      printf '%s -> %s\n' "$(relative_bundle_path "$embedded_bundle_path")" "$embedded_id"
    else
      relative_bundle_path "$embedded_bundle_path"
    fi
  done < <(find "$app_path" -maxdepth 5 \
    \( -path "$app_path" -o -name '*.appex' -o -name '*.app' \) \
    -type d -print0)

  local nesting_errors=()
  add_nesting_error() {
    nesting_errors+=("$1")
  }

  check_bundle_prefix() {
    local bundle_path="$1"
    local parent_id="$2"
    local current_id
    local expected_prefix
    current_id="$(bundle_id_for_path "$bundle_path")"
    expected_prefix="$parent_id."

    if [[ -z "$current_id" ]]; then
      add_nesting_error "$(relative_bundle_path "$bundle_path") has no CFBundleIdentifier"
    elif [[ "$current_id" != "$expected_prefix"* ]]; then
      add_nesting_error "$(relative_bundle_path "$bundle_path") -> $current_id; expected prefix $expected_prefix"
    fi
  }

  check_watch_companion() {
    local watch_app_path="$1"
    local companion_id
    companion_id="$(plist_value_from "$watch_app_path/Info.plist" WKCompanionAppBundleIdentifier)"
    if [[ "$companion_id" != "$bundle_id" ]]; then
      add_nesting_error "$(relative_bundle_path "$watch_app_path") WKCompanionAppBundleIdentifier -> ${companion_id:-missing}; expected $bundle_id"
    fi
  }

  if [[ -z "$bundle_id" ]]; then
    add_nesting_error "KeiBA.app has no CFBundleIdentifier"
  else
    if [[ -d "$app_path/PlugIns" ]]; then
      while IFS= read -r -d '' app_extension_path; do
        check_bundle_prefix "$app_extension_path" "$bundle_id"
      done < <(find "$app_path/PlugIns" -maxdepth 1 -type d -name '*.appex' -print0)
    fi

    if [[ -d "$app_path/Watch" ]]; then
      while IFS= read -r -d '' watch_app_path; do
        local watch_bundle_id
        check_bundle_prefix "$watch_app_path" "$bundle_id"
        check_watch_companion "$watch_app_path"

        watch_bundle_id="$(bundle_id_for_path "$watch_app_path")"
        if [[ -n "$watch_bundle_id" && -d "$watch_app_path/PlugIns" ]]; then
          while IFS= read -r -d '' watch_extension_path; do
            check_bundle_prefix "$watch_extension_path" "$watch_bundle_id"
          done < <(find "$watch_app_path/PlugIns" -maxdepth 1 -type d -name '*.appex' -print0)
        fi
      done < <(find "$app_path/Watch" -maxdepth 1 -type d -name '*.app' -print0)
    fi
  fi

  echo
  if [[ "${#nesting_errors[@]}" -eq 0 ]]; then
    echo "Direct bundle nesting: ok"
  else
    echo "Direct bundle nesting: invalid"
    printf '  %s\n' "${nesting_errors[@]}"
  fi

  local impactor_errors=()
  add_impactor_error() {
    impactor_errors+=("$1")
  }

  check_impactor_rewritable_prefix() {
    local bundle_path="$1"
    local parent_id="$2"
    local current_id
    local expected_prefix
    current_id="$(bundle_id_for_path "$bundle_path")"
    expected_prefix="$parent_id."

    if [[ -z "$current_id" ]]; then
      add_impactor_error "$(relative_bundle_path "$bundle_path") has no CFBundleIdentifier"
    elif [[ "$current_id" != "$expected_prefix"* ]]; then
      add_impactor_error "$(relative_bundle_path "$bundle_path") -> $current_id; expected pre-Impactor prefix $expected_prefix"
    fi
  }

  check_impactor_prepared_prefix() {
    local bundle_path="$1"
    local future_parent_id="$2"
    local current_id
    local expected_prefix
    current_id="$(bundle_id_for_path "$bundle_path")"
    expected_prefix="$future_parent_id."

    if [[ -z "$current_id" ]]; then
      add_impactor_error "$(relative_bundle_path "$bundle_path") has no CFBundleIdentifier"
    elif [[ "$current_id" != "$expected_prefix"* ]]; then
      add_impactor_error "$(relative_bundle_path "$bundle_path") -> $current_id; expected prefix $expected_prefix"
    fi
  }

  if [[ -n "$impactor_team_id" ]]; then
    local impactor_root_id
    impactor_root_id="$bundle_id.$impactor_team_id"
    echo
    echo "Impactor predicted root: $impactor_root_id"

    if [[ -z "$bundle_id" ]]; then
      add_impactor_error "KeiBA.app has no CFBundleIdentifier"
    else
      if [[ -d "$app_path/PlugIns" ]]; then
        while IFS= read -r -d '' app_extension_path; do
          check_impactor_rewritable_prefix "$app_extension_path" "$bundle_id"
        done < <(find "$app_path/PlugIns" -maxdepth 1 -type d -name '*.appex' -print0)
      fi

      if [[ -d "$app_path/Watch" ]]; then
        while IFS= read -r -d '' watch_app_path; do
          local watch_bundle_id
          local impactor_watch_id
          watch_bundle_id="$(bundle_id_for_path "$watch_app_path")"
          check_impactor_rewritable_prefix "$watch_app_path" "$bundle_id"

          if [[ -n "$watch_bundle_id" ]]; then
            impactor_watch_id="${watch_bundle_id//$bundle_id/$impactor_root_id}"
            if [[ -d "$watch_app_path/PlugIns" ]]; then
              while IFS= read -r -d '' watch_extension_path; do
                check_impactor_prepared_prefix "$watch_extension_path" "$impactor_watch_id"
              done < <(find "$watch_app_path/PlugIns" -maxdepth 1 -type d -name '*.appex' -print0)
            fi
          fi
        done < <(find "$app_path/Watch" -maxdepth 1 -type d -name '*.app' -print0)
      fi
    fi

    if [[ "${#impactor_errors[@]}" -eq 0 ]]; then
      echo "Impactor bundle nesting: ok"
    else
      echo "Impactor bundle nesting: invalid"
      printf '  %s\n' "${impactor_errors[@]}"
    fi
  fi

  echo
  if find "$app_path" -type d -name '_CodeSignature' -print -quit | grep -q .; then
    echo "Code signatures: _CodeSignature folders are present"
  else
    echo "Code signatures: none found"
  fi

  if [[ -n "$impactor_team_id" ]]; then
    [[ "${#impactor_errors[@]}" -eq 0 ]]
  else
    [[ "${#nesting_errors[@]}" -eq 0 ]]
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
