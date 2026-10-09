#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo 'Нужен Mac с Apple Silicon; этот скрипт готовит rclone для macOS arm64.' >&2
    exit 1
fi
VERSION=1.75.1
ARCHIVE="rclone-v${VERSION}-osx-arm64.zip"
EXPECTED=c61d7a371c62bcbbe882c3423aa4b8bf63485c248dd0f692997b8f0c3f6d0c6f
TASK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sb-dependencies.XXXXXX")"
trap 'rm -rf "$TASK_DIR"' EXIT
curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
    "https://downloads.rclone.org/v${VERSION}/${ARCHIVE}" -o "$TASK_DIR/$ARCHIVE"
ACTUAL="$(shasum -a 256 "$TASK_DIR/$ARCHIVE" | awk '{print $1}')"
if [[ "$ACTUAL" != "$EXPECTED" ]]; then
    echo 'SHA-256 архива rclone не совпадает. Бинарник не установлен.' >&2
    exit 1
fi
unzip -p "$TASK_DIR/$ARCHIVE" "rclone-v${VERSION}-osx-arm64/rclone" > "$TASK_DIR/rclone"
test -s "$TASK_DIR/rclone"
chmod 755 "$TASK_DIR/rclone"
mkdir -p vendor/rclone
mv "$TASK_DIR/rclone" vendor/rclone/rclone
echo "rclone $VERSION подготовлен, SHA-256 архива проверен."
