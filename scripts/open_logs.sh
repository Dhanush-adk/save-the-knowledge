#!/usr/bin/env bash
# Open KnowledgeCache app logs for debugging.
# Usage: ./scripts/open_logs.sh [tail]
#   no args: open the logs folder in Finder
#   tail:    tail -f the log file in terminal

# Sandboxed app writes to container
LOG_DIR="$HOME/Library/Containers/com.knowledgecache.app/Data/Library/Application Support/KnowledgeCache/logs"
LOG_FILE="$LOG_DIR/KnowledgeCache.log"

if [ "$1" = "tail" ]; then
  if [ -f "$LOG_FILE" ]; then
    tail -f "$LOG_FILE"
  else
    echo "Log file not found. Run the app once to create it: $LOG_FILE"
    exit 1
  fi
else
  mkdir -p "$LOG_DIR"
  open "$LOG_DIR"
fi
