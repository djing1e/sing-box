#!/bin/sh

set -u

VERSION="v1.12.17-mlkem.1"
REPO="djing1e/sing-box"

BINARY="sing-box-linux-arm64"
INSTALL="/usr/bin/sing-box"
NEW="/usr/bin/sing-box.new"

BASE_URL="https://github.com/${REPO}/releases/download/${VERSION}"
BINARY_URL="${BASE_URL}/${BINARY}"
SUM_URL="${BASE_URL}/SHA256SUMS"

SUM_FILE="/tmp/sing-box-SHA256SUMS"
TEST_FILE="/tmp/sing-box-download-test"

echo
echo "========================================"
echo " sing-box ML-KEM updater"
echo " Release: ${VERSION}"
echo "========================================"
echo

fail() {
    echo
    echo "ERROR: $1"
    echo
    exit 1
}

echo "[1/10] Preflight checks"

[ "$(uname -m)" = "aarch64" ] || fail "unsupported architecture: $(uname -m)"
command -v wget >/dev/null 2>&1 || fail "wget not found"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum not found"
[ -x "$INSTALL" ] || fail "$INSTALL not found"
[ -x /etc/init.d/forkop ] || fail "Forkop not found"

if ! pgrep netbird >/dev/null 2>&1; then
    fail "NetBird is not running"
fi

echo "NetBird: OK"
echo "Architecture: aarch64"
echo

echo "[2/10] Downloading checksum"

rm -f "$SUM_FILE" "$TEST_FILE" "$NEW"

wget -T 15 -O "$SUM_FILE" "$SUM_URL" ||
    fail "could not download SHA256SUMS"

EXPECTED="$(awk '$2 == "sing-box-linux-arm64" {print $1}' "$SUM_FILE")"

[ -n "$EXPECTED" ] ||
    fail "checksum for ${BINARY} not found"

echo "Expected SHA256:"
echo "$EXPECTED"
echo

echo "[3/10] Current installation"

CURRENT_SIZE="$(wc -c < "$INSTALL")"
CURRENT_SHA="$(sha256sum "$INSTALL" | awk '{print $1}')"

echo "Size:   $CURRENT_SIZE bytes"
echo "SHA256: $CURRENT_SHA"

if [ "$CURRENT_SHA" = "$EXPECTED" ]; then
    echo
    echo "Already running ${VERSION}."
    rm -f "$SUM_FILE"
    exit 0
fi

echo
echo "[4/10] Stopping Forkop"

/etc/init.d/forkop stop
sleep 3

if pgrep sing-box >/dev/null 2>&1; then
    echo "Forkop did not stop sing-box."
    /etc/init.d/forkop start >/dev/null 2>&1
    fail "sing-box is still running"
fi

if ! pgrep netbird >/dev/null 2>&1; then
    echo "NetBird stopped unexpectedly."
    /etc/init.d/forkop start >/dev/null 2>&1
    fail "update aborted before removing old sing-box"
fi

echo "Forkop stopped."
echo "NetBird: OK"
echo

echo "[5/10] Testing DNS and GitHub without Forkop"

rm -f "$TEST_FILE"

wget -T 15 -O "$TEST_FILE" "$SUM_URL"

if [ $? -ne 0 ]; then
    rm -f "$TEST_FILE"
    /etc/init.d/forkop start
    fail "GitHub is unavailable without Forkop; old sing-box was NOT removed"
fi

if [ ! -s "$TEST_FILE" ]; then
    rm -f "$TEST_FILE"
    /etc/init.d/forkop start
    fail "GitHub test returned an empty file; old sing-box was NOT removed"
fi

rm -f "$TEST_FILE"

echo "Direct GitHub download: OK"
echo "NetBird: OK"
echo

echo "[6/10] Removing old sing-box"

rm -f "$INSTALL" ||
    {
        /etc/init.d/forkop start
        fail "could not remove old sing-box"
    }

sync

AVAILABLE_KB="$(df -k / | awk 'NR==2 {print $4}')"

echo "Available overlay space: ${AVAILABLE_KB} KB"

# New binary is ~39.7 MB. Require some safety margin.
if [ "$AVAILABLE_KB" -lt 43000 ]; then
    fail "not enough free overlay space after removing old sing-box"
fi

echo

echo "[7/10] Downloading ${VERSION}"

rm -f "$NEW"

if ! wget -T 60 -O "$NEW" "$BINARY_URL"; then
    rm -f "$NEW"
    fail "binary download failed; Forkop cannot be restored until sing-box is installed"
fi

echo

echo "[8/10] Verifying binary"

ACTUAL="$(sha256sum "$NEW" | awk '{print $1}')"

echo "Expected: $EXPECTED"
echo "Actual:   $ACTUAL"

if [ "$ACTUAL" != "$EXPECTED" ]; then
    rm -f "$NEW"
    fail "SHA256 verification failed"
fi

chmod 755 "$NEW" ||
    fail "chmod failed"

"$NEW" version ||
    {
        rm -f "$NEW"
        fail "new sing-box cannot execute"
    }

if [ -f /etc/sing-box/config.json ]; then
    "$NEW" check -c /etc/sing-box/config.json ||
        {
            rm -f "$NEW"
            fail "new sing-box rejected current configuration"
        }
fi

echo
echo "Binary verification: OK"
echo

echo "[9/10] Installing"

mv "$NEW" "$INSTALL" ||
    fail "could not install new sing-box"

chmod 755 "$INSTALL"
sync

/etc/init.d/forkop start

sleep 5

echo
echo "[10/10] Final checks"

if ! /etc/init.d/forkop status 2>/dev/null | grep -q "running"; then
    fail "Forkop is not running"
fi

if ! pgrep sing-box >/dev/null 2>&1; then
    fail "sing-box is not running"
fi

if ! pgrep netbird >/dev/null 2>&1; then
    fail "NetBird is not running"
fi

FINAL_SHA="$(sha256sum "$INSTALL" | awk '{print $1}')"

if [ "$FINAL_SHA" != "$EXPECTED" ]; then
    fail "installed binary checksum changed"
fi

echo "Forkop:   OK"
echo "sing-box: OK"
echo "NetBird:  OK"
echo

echo "Installed SHA256:"
echo "$FINAL_SHA"

echo
echo "Filesystem:"
df -h /

echo
echo "Recent sing-box errors:"

PID="$(pgrep -o sing-box 2>/dev/null || true)"

if [ -n "$PID" ]; then
    logread |
        grep "sing-box\[$PID\]" |
        grep -E 'ERROR|FATAL|initialize vision|encryption' |
        tail -n 30 || true
fi

rm -f "$SUM_FILE" "$TEST_FILE"

echo
echo "========================================"
echo " Update completed successfully"
echo " ${VERSION}"
echo "========================================"
echo
