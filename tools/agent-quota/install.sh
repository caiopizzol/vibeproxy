#!/bin/sh
set -eu
quota_source=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$HOME/.local/share/agent-quota" "$HOME/.local/bin"
cp "$quota_source/cli.ts" "$quota_source/quota.ts" "$HOME/.local/share/agent-quota/"
cp "$quota_source/bin/agent-quota" "$HOME/.local/bin/agent-quota"
chmod +x "$HOME/.local/bin/agent-quota"
