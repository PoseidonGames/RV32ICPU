#!/bin/bash
# PreToolUse hook: block reading NDA-protected PDK files (.lib, .lef, .spf, .tf)
# into any agent context.
#
# Receives tool input JSON on stdin. Checks the file_path field for Read tool
# and the command field for Bash (cat/head/tail/less/more).

input=$(cat)
tool_name=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null)

NDA_PATTERN='\.(lib|lef|spf|tf)$'

case "$tool_name" in
  Read)
    file_path=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))" 2>/dev/null)
    if echo "$file_path" | grep -qiE "$NDA_PATTERN"; then
      echo "BLOCKED: $file_path is an NDA-protected PDK file (.lib/.lef/.spf/.tf). Never read these into AI context."
      exit 2
    fi
    ;;
  Bash)
    command=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null)
    # Check if a bash command references NDA file extensions (cat, head, tail, less, more, grep on .lib/.lef/.spf/.tf)
    if echo "$command" | grep -qiE "(cat|head|tail|less|more|sed|awk)\s.*$NDA_PATTERN"; then
      echo "BLOCKED: Command reads an NDA-protected PDK file (.lib/.lef/.spf/.tf). Never read these into AI context."
      exit 2
    fi
    ;;
esac

exit 0
