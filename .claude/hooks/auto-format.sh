#!/usr/bin/env bash

# PostToolUse hook for Edit|Write — runs terraform fmt on .tf files
# and shellcheck on .sh files, feeding results back to Claude.

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

if [[ -z "$FILE_PATH" ]] || [[ ! -f "$FILE_PATH" ]]; then
    exit 0
fi

case "$FILE_PATH" in
    *.tf)
        if command -v terraform >/dev/null 2>&1; then
            terraform fmt "$FILE_PATH" 2>&1
        fi
        ;;
    *.sh)
        if command -v shellcheck >/dev/null 2>&1; then
            OUTPUT=$(shellcheck "$FILE_PATH" 2>&1)
            RC=$?
            if [[ $RC -ne 0 ]] && [[ -n "$OUTPUT" ]]; then
                echo "shellcheck warnings for $FILE_PATH:"
                echo "$OUTPUT"
            fi
        fi
        ;;
esac

exit 0
