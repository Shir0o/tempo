#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Stop Tempo Timer
# @raycast.mode silent

# Optional parameters:
# @raycast.icon ⏹️
# @raycast.packageName Tempo
# @raycast.argument1 { "type": "text", "placeholder": "Comment (optional)", "optional": true }

COMMENT=$(echo "$1" | sed 's/ /%20/g')

if [ -n "$COMMENT" ]; then
  open "tempo://stop?comment=$COMMENT"
else
  open "tempo://stop"
fi
