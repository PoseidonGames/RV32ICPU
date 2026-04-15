#!/bin/bash
# PreToolUse hook: block writing .sv files that contain the * operator
# in synthesizable RTL. MAC must use explicit shift-add.
#
# Checks Write and Edit tools targeting .sv files for arithmetic multiply.
# Allows * in comments, port declarations (.*), wildcard patterns,
# and sensitivity lists (posedge/negedge).

input=$(cat)
tool_name=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null)

case "$tool_name" in
  Write)
    file_path=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))" 2>/dev/null)
    if echo "$file_path" | grep -qE '\.sv$'; then
      content=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('content',''))" 2>/dev/null)
      if echo "$content" | sed 's|//.*||g' | grep -qE '[a-zA-Z0-9_)][[:space:]]*\*[[:space:]]*[a-zA-Z0-9_(]'; then
        echo "BLOCKED: .sv file contains what looks like an arithmetic multiply (*) operator. Hard constraint: MAC must use explicit shift-add, no * in synthesizable RTL. If this is a false positive (e.g., comment or port connection), mention it to the user."
        exit 2
      fi
    fi
    ;;
  Edit)
    file_path=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))" 2>/dev/null)
    if echo "$file_path" | grep -qE '\.sv$'; then
      new_string=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('new_string',''))" 2>/dev/null)
      if echo "$new_string" | sed 's|//.*||g' | grep -qE '[a-zA-Z0-9_)][[:space:]]*\*[[:space:]]*[a-zA-Z0-9_(]'; then
        echo "BLOCKED: Edit introduces what looks like an arithmetic multiply (*) operator in .sv file. Hard constraint: MAC must use explicit shift-add, no * in synthesizable RTL. If this is a false positive (e.g., comment or port connection), mention it to the user."
        exit 2
      fi
    fi
    ;;
esac

exit 0
