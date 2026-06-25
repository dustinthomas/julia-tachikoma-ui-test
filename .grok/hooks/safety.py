#!/usr/bin/env python3
"""Simple PreToolUse safety hook for Grok (native .grok version).

Blocks:
- Dangerous rm -rf on / ~ .
- Direct access to .env* files

Mirrors the logic from the original .claude/hooks/pre_tool_use.py
"""

import json
import re
import sys

DANGEROUS_RM = [
    r"rm\s+.*-[a-zA-Z]*r[a-zA-Z]*f[a-zA-Z]*\s+/\s*$",
    r"rm\s+.*-[a-zA-Z]*r[a-zA-Z]*f[a-zA-Z]*\s+~",
    r"rm\s+.*-[a-zA-Z]*r[a-zA-Z]*f[a-zA-Z]*\s+\.\s*$",
]

ENV_PATTERN = r"(^|/)\.env($|\.local$|\.production$|\.staging$)"

def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        data = {}

    tool_name = data.get("toolName") or data.get("tool_name", "")
    tool_input = data.get("toolInput") or data.get("tool_input", {})

    reason = None

    if tool_name in ("run_terminal_command", "Bash"):
        cmd = tool_input.get("command", "")
        for pat in DANGEROUS_RM:
            if re.search(pat, cmd):
                reason = f"Blocked dangerous rm: {cmd}"
                break
        if not reason and re.search(ENV_PATTERN, cmd):
            reason = f"Blocked .env access in command: {cmd}"

    elif tool_name in ("read_file", "Read", "search_replace", "Write", "Edit"):
        path = tool_input.get("file_path") or tool_input.get("path", "")
        if re.search(ENV_PATTERN, path):
            reason = f"Blocked direct .env file access: {path}"

    if reason:
        print(json.dumps({"decision": "deny", "reason": reason}))
        sys.exit(2)

    # allow
    print(json.dumps({"decision": "allow"}))
    sys.exit(0)

if __name__ == "__main__":
    main()
