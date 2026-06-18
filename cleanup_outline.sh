#!/bin/bash
# Manually trigger Outline's daily cron (cleans expired sessions, orphan api
# keys, etc). Reads URL + UTILS_SECRET from env.outline (rendered by
# `make install`); override via OUTLINE_URL / OUTLINE_UTILS_SECRET env vars.
#
# Kept token-less on purpose: baking OUTLINE_UTILS_SECRET into this script
# would leak the cron token to anyone who can read the file.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$REPO_ROOT/env.outline"

URL="${OUTLINE_URL:-}"
TOKEN="${OUTLINE_UTILS_SECRET:-}"

if [ -z "$URL" ] || [ -z "$TOKEN" ]; then
    if [ ! -f "$ENV_FILE" ]; then
        echo "Need URL and UTILS_SECRET. Either run 'make install' first (which renders $ENV_FILE), or set OUTLINE_URL + OUTLINE_UTILS_SECRET env vars." >&2
        exit 1
    fi
    [ -z "$URL" ]   && URL="$(grep -E '^URL='          "$ENV_FILE" | head -1 | cut -d= -f2-)"
    [ -z "$TOKEN" ] && TOKEN="$(grep -E '^UTILS_SECRET=' "$ENV_FILE" | head -1 | cut -d= -f2-)"
fi

if [ -z "$URL" ] || [ -z "$TOKEN" ]; then
    echo "URL or UTILS_SECRET is empty in $ENV_FILE." >&2
    exit 1
fi

curl -X 'POST' \
    "${URL}/api/cron.daily?token=${TOKEN}" \
    -H "content-type: application/json" \
    -H "accept: application/json" \
    -v