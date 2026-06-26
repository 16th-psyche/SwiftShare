#!/bin/zsh
#
# SwiftShare — Feature 2: Temporary Object/Directory Cloud Staging (PRD §3.2, §6.2)
#
# Takes a Finder file/folder path, zips folders to /tmp/<name>.zip, uploads the
# payload to a public, zero-credential ephemeral host, writes the share URL to the
# clipboard, and fires a notification. Folders are packaged before upload.
#
# Upload uses a fallback chain over the §4 service matrix:
#   litterbox.catbox.moe (72h) -> 0x0.st (30d) -> transfer.sh (14d)
# The first host that returns a usable URL wins. litterbox leads because it is the
# most reliable in practice; the others remain as recovery fallbacks. (transfer.sh
# is frequently offline; 0x0.st rate-limits aggressively.)
#
# Zero-dependency: relies only on pre-installed macOS toolchain
# (zsh, curl, zip, pbcopy, osascript) per PRD §7.

emulate -L zsh
set -u

TITLE_OK="SwiftShare Storage Engine"
TITLE_FAIL="SwiftShare Error"

notify() {
  # $1 = message, $2 = title
  osascript -e "display notification \"${1//\"/\\\"}\" with title \"${2//\"/\\\"}\""
}

# --- Capture input ---------------------------------------------------------
TARGET_NODE="${1:-}"
if [[ -z "$TARGET_NODE" ]]; then
  notify "No file target or storage path could be resolved." "$TITLE_FAIL"
  exit 1
fi
if [[ ! -e "$TARGET_NODE" ]]; then
  notify "Target path does not exist: $TARGET_NODE" "$TITLE_FAIL"
  exit 1
fi

NODE_NAME="$(basename "$TARGET_NODE")"

# --- Dynamic directory packaging (PRD §3.2) --------------------------------
# Folders are zipped into a transient /tmp wrapper before upload.
CLEANUP_ZIP=""
if [[ -d "$TARGET_NODE" ]]; then
  UPLOAD_PAYLOAD="/tmp/${NODE_NAME}.zip"
  rm -f "$UPLOAD_PAYLOAD"
  if ! ( cd "$(dirname "$TARGET_NODE")" && zip -r -q "$UPLOAD_PAYLOAD" "$NODE_NAME" ); then
    notify "Failed to package directory for upload." "$TITLE_FAIL"
    exit 1
  fi
  CLEANUP_ZIP="$UPLOAD_PAYLOAD"
else
  UPLOAD_PAYLOAD="$TARGET_NODE"
fi

PAYLOAD_NAME="$(basename "$UPLOAD_PAYLOAD")"

cleanup() {
  [[ -n "$CLEANUP_ZIP" ]] && rm -f "$CLEANUP_ZIP"
}

# --- Upload helpers (each echoes a URL on success, non-zero on failure) -----
upload_litterbox() {
  # Ephemeral catbox; max retention 72h, 200 MB cap. Returns a bare URL.
  curl -fsS \
    -F "reqtype=fileupload" \
    -F "time=72h" \
    -F "fileToUpload=@${UPLOAD_PAYLOAD}" \
    "https://litterbox.catbox.moe/resources/internals/api.php" 2>/dev/null
}

upload_0x0_st() {
  # 0x0.st rejects the default curl User-Agent; send a custom one.
  curl -fsS -A "SwiftShare/1.0" -F "file=@${UPLOAD_PAYLOAD}" "https://0x0.st" 2>/dev/null
}

upload_transfer_sh() {
  curl -fsS --upload-file "$UPLOAD_PAYLOAD" \
    "https://transfer.sh/${PAYLOAD_NAME}" 2>/dev/null
}

# host label | retention | function
HOSTS=(
  "litterbox.catbox.moe|72 Hours|upload_litterbox"
  "0x0.st|30 Days|upload_0x0_st"
  "transfer.sh|14 Days|upload_transfer_sh"
)

# --- Upload with fallback (PRD §4) -----------------------------------------
REMOTE_LINK=""
HOST_USED=""
RETENTION=""
for entry in "${HOSTS[@]}"; do
  label="${entry%%|*}"
  rest="${entry#*|}"
  retention="${rest%%|*}"
  fn="${rest#*|}"

  result="$("$fn")"
  if [[ $? -eq 0 && "$result" =~ ^https?:// ]]; then
    REMOTE_LINK="${result%%$'\n'*}"   # first URL line only
    HOST_USED="$label"
    RETENTION="$retention"
    break
  fi
done

# --- Network resilience fault intercept (PRD §7) ---------------------------
if [[ -z "$REMOTE_LINK" ]]; then
  cleanup
  notify "Network offline or all upload hosts unavailable. Transaction deferred." "$TITLE_FAIL"
  exit 1
fi

# --- Output ----------------------------------------------------------------
printf '%s' "$REMOTE_LINK" | pbcopy
cleanup
notify "Upload complete via ${HOST_USED}. Share URL copied to clipboard. Lifespan: ${RETENTION}." "$TITLE_OK"
exit 0
