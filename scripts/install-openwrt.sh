#!/bin/sh

set -u

VERSION="v1.12.17-mlkem.1"
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

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

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
    echo "RECOVERY: restoring sing-box from verified local archive..."

    rm -f "$NEW"

    [ -s "$ARCHIVE_FILE" ] || {
        echo "RECOVERY FAILED: archive is missing"
        return 1
    }

    gzip -dc "$ARCHIVE_FILE" > "$NEW" || {
        rm -f "$NEW"
        echo "RECOVERY FAILED: decompression failed"
        return 1
    }

    RECOVERY_SHA="$(sha256sum "$NEW" | awk '{print $1}')"

    [ "$RECOVERY_SHA" = "$EXPECTED_BINARY" ] || {
        rm -f "$NEW"
        echo "RECOVERY FAILED: checksum mismatch"
        return 1
    }

    chmod 755 "$NEW" || {
        rm -f "$NEW"
        echo "RECOVERY FAILED: chmod failed"
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

    if pgrep sing-box >/dev/null 2>&1; then
        echo "RECOVERY: sing-box restored and Forkop started"
        return 0
    fi

    echo "RECOVERY FAILED: sing-box did not start"
    return 1
}

fail_after_removal() {
    echo
    echo "ERROR: $1"
    recover_from_archive || true
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

ARCHIVE_SIZE=14477514

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

# Allow a small filesystem/metadata safety margin.
SAFETY_KB=512

POTENTIAL_KB=$((OVERLAY_AVAILABLE_KB + OLD_SIZE_KB))
REQUIRED_KB=$((NEW_SIZE_KB + SAFETY_KB))

echo "Currently free:       ${OVERLAY_AVAILABLE_KB} KB"
echo "Old sing-box:         ${OLD_SIZE_KB} KB"
echo "Available after rm:   ~${POTENTIAL_KB} KB"
echo "New + safety margin:  ${REQUIRED_KB} KB"

[ "$POTENTIAL_KB" -ge "$REQUIRED_KB" ] ||
    fail "not enough overlay capacity to replace sing-box"

echo
echo "All non-destructive checks passed."
echo

echo "[6/10] Stopping Forkop"

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
    echo "WARNING: NetBird PID changed."
fi

echo
echo "[7/10] Replacing sing-box"

rm -f "$NEW"

rm -f "$INSTALL" || {
    restart_forkop_after_failure
    fail "could not remove old sing-box"
}

sync

ACTUAL_FREE_KB="$(df -k / | awk 'NR==2 {print $4}')"

echo "Free overlay after removal: ${ACTUAL_FREE_KB} KB"

if [ "$ACTUAL_FREE_KB" -lt "$REQUIRED_KB" ]; then
    fail_after_removal "not enough space after removing old sing-box"
fi

if ! gzip -dc "$ARCHIVE_FILE" > "$NEW"; then
    rm -f "$NEW"
    fail_after_removal "could not decompress new sing-box"
fi

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

"$NEW" version ||
    fail_after_removal "new sing-box cannot execute"

echo
echo "[8/10] Validating configuration"

if [ -f /etc/sing-box/config.json ]; then
    "$NEW" check -c /etc/sing-box/config.json ||
        fail_after_removal "new sing-box rejected /etc/sing-box/config.json"
else
    echo "/etc/sing-box/config.json not present; Forkop manages runtime configuration."
fi

echo
echo "[9/10] Installing and starting"

mv "$NEW" "$INSTALL" ||
    fail_after_removal "could not move new binary into place"

chmod 755 "$INSTALL"
sync

/etc/init.d/forkop start
sleep 5

echo
echo "[10/10] Final checks"

FORKOP_STATUS="$(/etc/init.d/forkop status 2>/dev/null || true)"

echo "Forkop status: $FORKOP_STATUS"

echo "$FORKOP_STATUS" | grep -q "running" ||
    fail "Forkop is not running; archive retained in /tmp"

pgrep sing-box >/dev/null 2>&1 ||
    fail "sing-box is not running; archive retained in /tmp"

pgrep netbird >/dev/null 2>&1 ||
    fail "NetBird is not running"

FINAL_SHA="$(
    sha256sum "$INSTALL" | awk '{print $1}'
)"

[ "$FINAL_SHA" = "$EXPECTED_BINARY" ] ||
    fail "installed binary checksum mismatch"

FINAL_PID="$(pgrep -o sing-box 2>/dev/null || true)"
FINAL_NETBIRD_PID="$(pgrep -o netbird 2>/dev/null || true)"

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

cleanup_tmp

echo
echo "========================================"
echo " Update completed successfully"
echo " ${VERSION}"
echo "========================================"
echo
