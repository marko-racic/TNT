#!/bin/bash
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMMAND_FILE="$APP_DIR/Resources/Launch TNT.command"

/usr/bin/open -a Terminal "$COMMAND_FILE"
exit 0
