#!/bin/bash
# Dumps the shipped prompts and examples (FormatStyles.swift) to JSON for run.py.
# usage: bash scripts/formatter-bench/dump_styles.sh > styles.json
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
cp "$HERE/../../Sources/OpenWisprLib/FormatStyles.swift" "$HERE/dump_styles.swift" "$TMP/"
mv "$TMP/dump_styles.swift" "$TMP/main.swift"
swiftc -Onone -suppress-warnings "$TMP/FormatStyles.swift" "$TMP/main.swift" -o "$TMP/dump"
"$TMP/dump" | python3 -c "import json,sys; d=json.load(sys.stdin); d['_tag']='dictation'; print(json.dumps(d, indent=1, ensure_ascii=False))"
rm -rf "$TMP"
