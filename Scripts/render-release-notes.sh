#!/usr/bin/env bash
set -euo pipefail

signing_available="${1:?usage: render-release-notes.sh <true|false>}"
case "$signing_available" in
  true|false) ;;
  *)
    printf '%s\n' "signing availability must be true or false" >&2
    exit 1
    ;;
esac

existing_notes="$(</dev/stdin)"
cleaned_notes="$(printf '%s\n' "$existing_notes" | awk '
  /<!-- unsigned-install:start -->/ && !skipping {
    skipping = 1
    buffered = $0 ORS
    next
  }
  skipping {
    buffered = buffered $0 ORS
    if ($0 ~ /<!-- unsigned-install:end -->/) {
      skipping = 0
      buffered = ""
    }
    next
  }
  { print }
  END {
    if (skipping) {
      printf "%s", buffered
    }
  }
' | awk '
  /^[[:space:]]*$/ {
    if (content_started) {
      pending_blank = pending_blank $0 ORS
    }
    next
  }
  {
    if (content_started) {
      printf "%s", pending_blank
    }
    pending_blank = ""
    content_started = 1
    print
  }
')"

if [ "$signing_available" = "true" ]; then
  printf '%s' "$cleaned_notes"
  exit 0
fi

warning_notes="$(printf '%s\n' \
  '<!-- unsigned-install:start -->' \
  '> [!IMPORTANT]' \
  '> This release contains an ad-hoc signed, unnotarized app. macOS may report it as damaged until download quarantine is removed.' \
  '> Only use the DMG from this repository'\''s official Releases page. After copying the app to Applications, run:' \
  '>' \
  "> \`xattr -r -d com.apple.quarantine \"/Applications/Workshop Wallpaper Bridge.app\"\`" \
  '<!-- unsigned-install:end -->')"

printf '%s' "$warning_notes"
if [ -n "$cleaned_notes" ]; then
  printf '\n\n%s' "$cleaned_notes"
fi
