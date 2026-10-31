#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Start Tempo Timer
# @raycast.mode silent

# Optional parameters:
# @raycast.icon ⏱️
# @raycast.packageName Tempo
# @raycast.argument1 { "type": "text", "placeholder": "Activity Name" }
# @raycast.argument2 { "type": "text", "placeholder": "Comment (optional)", "optional": true }

ACTIVITY=$(echo "$1" | sed 's/ /%20/g')
COMMENT=$(echo "$2" | sed 's/ /%20/g')

if [ -n "$COMMENT" ]; then
  open "tempo://start?activity=$ACTIVITY&comment=$COMMENT"
else
  open "tempo://start?activity=$ACTIVITY"
fi
