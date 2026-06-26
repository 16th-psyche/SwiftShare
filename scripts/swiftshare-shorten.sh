#!/bin/zsh
#
# SwiftShare — Feature 1: Explicit Contextual URL Shortener (PRD §3.1, §6.1)
#
# Translates a selected HTTP(S) URL into a minimized TinyURL string and writes
# the result into the system pasteboard. Designed to be driven from a macOS
# "Quick Action" that passes the highlighted text as $1 (or via stdin).
#
# Zero-dependency: relies only on pre-installed macOS toolchain
# (zsh, curl, pbcopy, osascript) per PRD §7.

emulate -L zsh
setopt extended_glob
set -u

TITLE_OK="SwiftShare Shortener"
TITLE_FAIL="SwiftShare Failure"

notify() {
  # $1 = message, $2 = title
  osascript -e "display notification \"${1//\"/\\\"}\" with title \"${2//\"/\\\"}\""
}

# --- Capture input ---------------------------------------------------------
# Accept the URL as the first argument, falling back to stdin so the script
# works both from Automator (arguments) and from a piped selection.
INPUT_RAW_URL="${1:-}"
if [[ -z "$INPUT_RAW_URL" && ! -t 0 ]]; then
  INPUT_RAW_URL="$(cat)"
fi

# Trim surrounding whitespace/newlines that often ride along with selections.
INPUT_RAW_URL="${INPUT_RAW_URL//$'\n'/}"
INPUT_RAW_URL="${INPUT_RAW_URL//$'\r'/}"
INPUT_RAW_URL="${INPUT_RAW_URL##[[:space:]]##}"
INPUT_RAW_URL="${INPUT_RAW_URL%%[[:space:]]##}"

# --- Validate --------------------------------------------------------------
# Require an absolute http:// or https:// schema.
if [[ ! "$INPUT_RAW_URL" =~ ^https?://.+ ]]; then
  notify "Invalid string formatting. Action requires an absolute HTTP(S) URL schema." "$TITLE_FAIL"
  exit 1
fi

# --- Shorten ---------------------------------------------------------------
# is.gd plain-text API. Unlike TinyURL, is.gd performs a DIRECT redirect with
# no interstitial/preview page (preview is opt-in only). da.gd is the fallback.
# --get + --data-urlencode safely encodes the target URL; --fail surfaces HTTP
# errors as exit codes.
SHORT_OUTPUT="$(curl -fsS --get \
  --data-urlencode "url=${INPUT_RAW_URL}" \
  "https://is.gd/create.php?format=simple" 2>/dev/null)"
CURL_STATUS=$?

# Fallback to da.gd (also a direct-redirect, no-auth shortener).
if [[ $CURL_STATUS -ne 0 || ! "$SHORT_OUTPUT" =~ ^https?:// ]]; then
  SHORT_OUTPUT="$(curl -fsS --get \
    --data-urlencode "url=${INPUT_RAW_URL}" \
    "https://da.gd/s" 2>/dev/null)"
  CURL_STATUS=$?
fi

# Network resilience fault intercept (PRD §7).
if [[ $CURL_STATUS -ne 0 || -z "$SHORT_OUTPUT" ]]; then
  notify "Network offline or service unavailable. Transaction deferred." "$TITLE_FAIL"
  exit 1
fi

# TinyURL returns an error string rather than a URL on bad input.
if [[ ! "$SHORT_OUTPUT" =~ ^https?:// ]]; then
  notify "Shortening service rejected the URL: ${SHORT_OUTPUT}" "$TITLE_FAIL"
  exit 1
fi

# --- Output ----------------------------------------------------------------
printf '%s' "$SHORT_OUTPUT" | pbcopy
notify "Shortened URL successfully added to your clipboard." "$TITLE_OK"
exit 0
