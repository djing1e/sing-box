#!/bin/sh

set -u

VERSION="v1.12.17-mlkem.2"
REPO="djing1e/sing-box"

BINARY="sing-box-linux-arm64"
ARCHIVE="${BINARY}.gz"

INSTALL="/usr/bin/sing-box"
NEW="/usr/bin/sing-box.new"

BASE_URL="https://github.com/${REPO}/releases/download/${VERSION}"
SUM_URL="${BASE_URL}/SHA256SUMS"
ARCHIVE_URL="${BASE_URL}/${ARCHIVE}"

SUM_FILE="/tmp/sing-box-SHA256SUMS"
ARCHIVE_FILE="/tmp/${ARCHIVE}"
ROLLBACK_FILE="/tmp/sing-box.rollback.gz"

FORCE=0
DRY_RUN=0

case "${1:-}" in
    "")
        ;;
    --force)
        FORCE=1
        ;;
    --dry-run)
        DRY_RUN=1
        FORCE=1
        ;;
    *)
        echo "Usage: $0 [--force|--dry-run]"
        exit 2
        ;;
esac

fail() {
    echo
    echo "ERROR: $1"
    echo
    exit 1
}

cleanup_tmp() {
    rm -f "$SUM_FILE" "$ARCHIVE_FILE"
}

restart_forkop_after_failure() {
    echo
    echo "Attempting to start Forkop..."
    /etc/init.d/forkop start >/dev/null 2>&1 || true
}

recover_from_archive() {
    echo
    echo "========================================"
    echo " RECOVERY: restoring previous sing-box"
    echo "========================================"

    # Recovery may be called either before or after the new binary
    # has been installed and started. Stop Forkop first so that no
    # sing-box process is using the binary we are about to replace.
    /etc/init.d/forkop stop >/dev/null 2>&1 || true
    sleep 3

    if pgrep sing-box >/dev/null 2>&1; then
        echo "RECOVERY FAILED: sing-box is still running after Forkop stop"
        return 1
    fi

    rm -f "$NEW"

    [ -s "$ROLLBACK_FILE" ] || {
        echo "RECOVERY FAILED: rollback archive is missing"
        return 1
    }

    gzip -t "$ROLLBACK_FILE" || {
        echo "RECOVERY FAILED: rollback archive is corrupt"
        return 1
    }

    gzip -dc "$ROLLBACK_FILE" > "$NEW" || {
        rm -f "$NEW"
        echo "RECOVERY FAILED: rollback decompression failed"
        return 1
    }

    RECOVERY_SHA="$(sha256sum "$NEW" | awk '{print $1}')"

    [ "$RECOVERY_SHA" = "$CURRENT_SHA" ] || {
        rm -f "$NEW"
        echo "RECOVERY FAILED: previous binary checksum mismatch"
        return 1
    }

    RECOVERY_SIZE="$(wc -c < "$NEW")"

    [ "$RECOVERY_SIZE" = "$CURRENT_SIZE" ] || {
        rm -f "$NEW"
        echo "RECOVERY FAILED: previous binary size mismatch"
        return 1
    }

    chmod 755 "$NEW" || {
        rm -f "$NEW"
        echo "RECOVERY FAILED: chmod failed"
        return 1
    }

    "$NEW" version >/dev/null 2>&1 || {
        rm -f "$NEW"
        echo "RECOVERY FAILED: previous binary cannot execute"
        return 1
    }

    mv "$NEW" "$INSTALL" || {
        rm -f "$NEW"
        echo "RECOVERY FAILED: install failed"
        return 1
    }

    sync

    /etc/init.d/forkop start >/dev/null 2>&1 || true
    sleep 3

    RESTORED_SHA="$(sha256sum "$INSTALL" | awk '{print $1}')"

    [ "$RESTORED_SHA" = "$CURRENT_SHA" ] || {
        echo "RECOVERY FAILED: installed binary checksum mismatch"
        return 1
    }

    if pgrep sing-box >/dev/null 2>&1; then
        echo "RECOVERY: previous sing-box restored"
        echo "RECOVERY: SHA256 $RESTORED_SHA"
        echo "RECOVERY: Forkop started successfully"
        return 0
    fi

    echo "RECOVERY FAILED: sing-box did not start"
    return 1
}

fail_after_removal() {
    echo
    echo "ERROR: $1"

    if recover_from_archive; then
        echo
        echo "Previous sing-box was restored successfully."
        echo "Rollback archive retained until updater exits."
    else
        echo
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo " CRITICAL: AUTOMATIC ROLLBACK FAILED"
        echo " DO NOT REBOOT"
        echo " Rollback archive:"
        echo " $ROLLBACK_FILE"
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    fi

    echo
    exit 1
}

echo
echo "========================================"
echo " sing-box ML-KEM updater"
echo " Release: ${VERSION}"
echo "========================================"
echo

echo "[1/10] Preflight"

[ "$(uname -m)" = "aarch64" ] ||
    fail "unsupported architecture: $(uname -m)"

for cmd in wget sha256sum gzip awk wc df pgrep; do
    command -v "$cmd" >/dev/null 2>&1 ||
        fail "$cmd not found"
done

[ -x "$INSTALL" ] ||
    fail "$INSTALL not found"

[ -x /etc/init.d/forkop ] ||
    fail "Forkop not found"

pgrep netbird >/dev/null 2>&1 ||
    fail "NetBird is not running"

CURRENT_NETBIRD_PID="$(pgrep -o netbird 2>/dev/null || true)"

echo "Architecture: aarch64"
echo "NetBird PID: $CURRENT_NETBIRD_PID"
echo

echo "[2/10] Downloading metadata"

rm -f "$SUM_FILE" "$ARCHIVE_FILE" "$NEW"

wget -T 30 -O "$SUM_FILE" "$SUM_URL" ||
    fail "could not download SHA256SUMS"

EXPECTED_BINARY="$(
    awk '$2 == "sing-box-linux-arm64" {print $1}' "$SUM_FILE"
)"

EXPECTED_ARCHIVE="$(
    awk '$2 == "sing-box-linux-arm64.gz" {print $1}' "$SUM_FILE"
)"

[ -n "$EXPECTED_BINARY" ] ||
    fail "binary checksum missing"

[ -n "$EXPECTED_ARCHIVE" ] ||
    fail "archive checksum missing"

CURRENT_SIZE="$(wc -c < "$INSTALL")"
CURRENT_SHA="$(sha256sum "$INSTALL" | awk '{print $1}')"

echo "Current binary:"
echo "  size:   $CURRENT_SIZE bytes"
echo "  SHA256: $CURRENT_SHA"
echo

if [ "$CURRENT_SHA" = "$EXPECTED_BINARY" ] && [ "$FORCE" -ne 1 ]; then
    echo "Already running ${VERSION}."
    echo "Use --force to reinstall it."
    rm -f "$SUM_FILE"
    exit 0
fi

echo "[3/10] Checking temporary storage"

ARCHIVE_SIZE=14478052

TMP_AVAILABLE_KB="$(df -k /tmp | awk 'NR==2 {print $4}')"
TMP_REQUIRED_KB=$(( (ARCHIVE_SIZE + 1048575) / 1024 ))

echo "Available /tmp: ${TMP_AVAILABLE_KB} KB"
echo "Required /tmp:  ${TMP_REQUIRED_KB} KB"

[ "$TMP_AVAILABLE_KB" -ge "$TMP_REQUIRED_KB" ] ||
    fail "not enough free space in /tmp"

echo
echo "[4/10] Staging archive"

wget -T 60 -O "$ARCHIVE_FILE" "$ARCHIVE_URL" ||
    fail "archive download failed"

ACTUAL_ARCHIVE="$(
    sha256sum "$ARCHIVE_FILE" | awk '{print $1}'
)"

echo "Expected archive SHA256: $EXPECTED_ARCHIVE"
echo "Actual archive SHA256:   $ACTUAL_ARCHIVE"

[ "$ACTUAL_ARCHIVE" = "$EXPECTED_ARCHIVE" ] ||
    fail "archive SHA256 verification failed"

gzip -t "$ARCHIVE_FILE" ||
    fail "gzip integrity test failed"

STREAM_SHA="$(
    gzip -dc "$ARCHIVE_FILE" | sha256sum | awk '{print $1}'
)"

STREAM_SIZE="$(
    gzip -dc "$ARCHIVE_FILE" | wc -c
)"

echo "Decompressed SHA256: $STREAM_SHA"
echo "Decompressed size:   $STREAM_SIZE bytes"

[ "$STREAM_SHA" = "$EXPECTED_BINARY" ] ||
    fail "decompressed binary SHA256 verification failed"

[ "$STREAM_SIZE" -eq 40632446 ] ||
    fail "unexpected decompressed binary size"

echo
echo "Archive staged and fully verified."
echo

echo "[5/10] Checking overlay capacity"

OVERLAY_AVAILABLE_KB="$(df -k / | awk 'NR==2 {print $4}')"
OLD_SIZE_KB=$(( (CURRENT_SIZE + 1023) / 1024 ))
NEW_SIZE_KB=$(( (STREAM_SIZE + 1023) / 1024 ))

SAFETY_KB=512

POTENTIAL_KB=$((OVERLAY_AVAILABLE_KB + OLD_SIZE_KB))

echo "Currently free:       ${OVERLAY_AVAILABLE_KB} KB"
echo "Old sing-box:         ${OLD_SIZE_KB} KB"
echo "New sing-box:         ${NEW_SIZE_KB} KB"
echo "Available after rm:   ~${POTENTIAL_KB} KB"

if [ "$NEW_SIZE_KB" -le "$OLD_SIZE_KB" ]; then
    # Replacement is same size or smaller. Do not require extra free
    # overlay before removal: the old binary itself provides the space.
    REQUIRED_KB="$NEW_SIZE_KB"

    echo "Replacement:          same size or smaller"
    echo "Required after rm:    ${REQUIRED_KB} KB"
else
    # New binary is larger. Require the new binary plus a small margin.
    REQUIRED_KB=$((NEW_SIZE_KB + SAFETY_KB))

    echo "Replacement:          larger binary"
    echo "Safety margin:        ${SAFETY_KB} KB"
    echo "Required after rm:    ${REQUIRED_KB} KB"
fi

[ "$POTENTIAL_KB" -ge "$REQUIRED_KB" ] ||
    fail "not enough overlay capacity to replace sing-box"

echo
echo "[6/11] Checking rollback capacity"

# Measure the current binary with the same gzip level that will be used
# for the real rollback archive. This creates no file and changes nothing.
ROLLBACK_ESTIMATE_BYTES="$(
    gzip -1 -c "$INSTALL" | wc -c
)"

ROLLBACK_ESTIMATE_KB=$(( (ROLLBACK_ESTIMATE_BYTES + 1023) / 1024 ))

TMP_AVAILABLE_BEFORE_ROLLBACK_KB="$(
    df -k /tmp | awk 'NR==2 {print $4}'
)"

MEM_AVAILABLE_KB="$(
    awk '/^MemAvailable:/ {print $2}' /proc/meminfo
)"

MEMORY_RESERVE_KB=16384
MEMORY_REQUIRED_KB=$((ROLLBACK_ESTIMATE_KB + MEMORY_RESERVE_KB))

echo "Rollback gzip estimate:         ${ROLLBACK_ESTIMATE_BYTES} bytes"
echo "Rollback estimate:              ${ROLLBACK_ESTIMATE_KB} KB"
echo "Available /tmp:                 ${TMP_AVAILABLE_BEFORE_ROLLBACK_KB} KB"
echo "Available memory:               ${MEM_AVAILABLE_KB} KB"
echo "Memory reserve after rollback:  ${MEMORY_RESERVE_KB} KB"
echo "Required available memory:      ${MEMORY_REQUIRED_KB} KB"

[ "$TMP_AVAILABLE_BEFORE_ROLLBACK_KB" -gt "$ROLLBACK_ESTIMATE_KB" ] ||
    fail "not enough /tmp space for rollback archive"

[ -n "$MEM_AVAILABLE_KB" ] ||
    fail "could not determine MemAvailable"

[ "$MEM_AVAILABLE_KB" -ge "$MEMORY_REQUIRED_KB" ] ||
    fail "not enough available memory to safely create rollback archive"

echo
echo "All non-destructive checks passed."
echo

if [ "$DRY_RUN" -eq 1 ]; then
    echo "========================================"
    echo " DRY RUN completed successfully"
    echo " No services were stopped or modified"
    echo "========================================"
    echo
    echo "Current sing-box remains installed."
    echo "Forkop remains running."
    echo "NetBird remains untouched."
    echo
    cleanup_tmp
    exit 0
fi

echo "[7/11] Creating rollback archive"

rm -f "$ROLLBACK_FILE"

gzip -1 -c "$INSTALL" > "$ROLLBACK_FILE" ||
    fail "failed to create rollback archive"
ROLLBACK_SIZE="$(wc -c < "$ROLLBACK_FILE")"

echo "Rollback archive size: ${ROLLBACK_SIZE} bytes"

gzip -t "$ROLLBACK_FILE" ||
    fail "rollback archive failed gzip integrity check"

ROLLBACK_SHA="$(
    gzip -dc "$ROLLBACK_FILE" | sha256sum | awk '{print $1}'
)"

ROLLBACK_UNCOMPRESSED_SIZE="$(
    gzip -dc "$ROLLBACK_FILE" | wc -c
)"

echo "Current SHA256:         $CURRENT_SHA"
echo "Rollback SHA256:        $ROLLBACK_SHA"
echo "Current size:           $CURRENT_SIZE bytes"
echo "Rollback restored size: $ROLLBACK_UNCOMPRESSED_SIZE bytes"

[ "$ROLLBACK_SHA" = "$CURRENT_SHA" ] ||
    fail "rollback archive SHA256 does not match current sing-box"

[ "$ROLLBACK_UNCOMPRESSED_SIZE" = "$CURRENT_SIZE" ] ||
    fail "rollback archive size does not match current sing-box"

echo "Rollback archive fully verified."
echo

echo "[8/11] Stopping Forkop"

/etc/init.d/forkop stop
sleep 3

if pgrep sing-box >/dev/null 2>&1; then
    restart_forkop_after_failure
    fail "sing-box is still running after Forkop stop"
fi

if ! pgrep netbird >/dev/null 2>&1; then
    restart_forkop_after_failure
    fail "NetBird stopped unexpectedly; old sing-box was not removed"
fi

NETBIRD_PID_AFTER_STOP="$(pgrep -o netbird 2>/dev/null || true)"

echo "Forkop stopped."
echo "NetBird PID: $NETBIRD_PID_AFTER_STOP"

if [ "$NETBIRD_PID_AFTER_STOP" != "$CURRENT_NETBIRD_PID" ]; then
    restart_forkop_after_failure
    fail "NetBird PID changed; old sing-box was not removed"
fi

echo
echo "[9/11] Replacing sing-box"

rm -f "$NEW"

rm -f "$INSTALL" || {
    restart_forkop_after_failure
    fail "could not remove old sing-box"
}

sync

ACTUAL_FREE_KB="$(df -k / | awk 'NR==2 {print $4}')"

echo "Free overlay after removal: ${ACTUAL_FREE_KB} KB"
echo "Writing new binary to compressed overlay..."

# Do not compare df free space with the logical binary size here.
# OpenWrt overlay may use transparent compression (for example UBIFS),
# so logical file size is not equal to physical flash consumption.
#
# The verified previous binary is already stored in RAM as rollback.gz.
# If the write fails (including ENOSPC), remove the partial file and
# immediately restore the previous binary.
if ! gzip -dc "$ARCHIVE_FILE" > "$NEW"; then
    rm -f "$NEW"
    sync
    fail_after_removal "could not write new sing-box to overlay"
fi

sync

ACTUAL_BINARY="$(
    sha256sum "$NEW" | awk '{print $1}'
)"

echo "Expected binary SHA256: $EXPECTED_BINARY"
echo "Actual binary SHA256:   $ACTUAL_BINARY"

if [ "$ACTUAL_BINARY" != "$EXPECTED_BINARY" ]; then
    rm -f "$NEW"
    fail_after_removal "new binary SHA256 verification failed"
fi

chmod 755 "$NEW" ||
    fail_after_removal "chmod failed"

NEW_VERSION="$(
    "$NEW" version 2>/dev/null | awk 'NR==1 {print $3}'
)" || fail_after_removal "new sing-box cannot execute"

echo "Expected sing-box version: 1.12.17-mlkem.2"
echo "Actual sing-box version:   ${NEW_VERSION}"

[ "$NEW_VERSION" = "1.12.17-mlkem.2" ] ||
    fail_after_removal "unexpected sing-box version: ${NEW_VERSION}"

echo
echo "[10/11] Validating configuration"

if [ -f /etc/sing-box/config.json ]; then
    "$NEW" check -c /etc/sing-box/config.json ||
        fail_after_removal "new sing-box rejected /etc/sing-box/config.json"
else
    echo "/etc/sing-box/config.json not present; Forkop manages runtime configuration."
fi

echo
echo "[11/11] Installing and starting"

mv "$NEW" "$INSTALL" ||
    fail_after_removal "could not move new binary into place"

chmod 755 "$INSTALL"
sync

/etc/init.d/forkop start
sleep 5

echo
echo "Final checks"

FORKOP_STATUS="$(/etc/init.d/forkop status 2>/dev/null || true)"

echo "Forkop status: $FORKOP_STATUS"

echo "$FORKOP_STATUS" | grep -q "running" ||
    fail_after_removal "Forkop is not running with new sing-box"

pgrep sing-box >/dev/null 2>&1 ||
    fail_after_removal "new sing-box is not running"

# NetBird is deliberately never stopped or restarted by this updater.
# If it disappeared during the update, restore the previous sing-box
# while local execution is still available.
pgrep netbird >/dev/null 2>&1 ||
    fail_after_removal "NetBird is not running after update"

FINAL_SHA="$(
    sha256sum "$INSTALL" | awk '{print $1}'
)"

[ "$FINAL_SHA" = "$EXPECTED_BINARY" ] ||
    fail_after_removal "installed binary checksum mismatch"

FINAL_PID="$(pgrep -o sing-box 2>/dev/null || true)"
FINAL_NETBIRD_PID="$(pgrep -o netbird 2>/dev/null || true)"

[ "$FINAL_NETBIRD_PID" = "$CURRENT_NETBIRD_PID" ] ||
    fail_after_removal "NetBird PID changed during update"

echo
echo "Forkop:      OK"
echo "sing-box:    OK (PID $FINAL_PID)"
echo "NetBird:     OK (PID $FINAL_NETBIRD_PID)"
echo "SHA256:      $FINAL_SHA"

echo
echo "Filesystem:"
df -h /

echo
echo "Recent errors for current sing-box PID:"

if [ -n "$FINAL_PID" ]; then
    logread |
        grep "sing-box\[$FINAL_PID\]" |
        grep -E 'ERROR|FATAL|initialize vision|encryption' |
        tail -n 30 || true
fi

rm -f "$ROLLBACK_FILE"
cleanup_tmp

echo
echo "========================================"
echo " Update completed successfully"
echo " ${VERSION}"
echo "========================================"
echo
