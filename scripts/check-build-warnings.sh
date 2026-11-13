#!/usr/bin/env bash
# Fails (exit 1) when a result bundle records any build warning: compiler, linker, script phase or analyzer.
#
#   ./scripts/check-build-warnings.sh <result-bundle.xcresult>
#
# Reads `xcrun xcresulttool get build-results` and prints each warning as path:line: message, with paths relative to
# this repository. Part of ./scripts/test.sh: the app and its tests build with no warnings.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

bundle="${1:-}"
case "${bundle}" in
  -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
  "") sed -n '2,7p' "$0" >&2; exit 2 ;;
esac
if [[ ! -d "${bundle}" ]]; then
  echo "No result bundle at ${bundle}: the build did not run, so its warnings cannot be checked." >&2
  exit 1
fi

xcrun xcresulttool get build-results --path "${bundle}" --compact | python3 -I -c '
import json, sys, urllib.parse

root = sys.argv[1].rstrip("/") + "/"
data = json.load(sys.stdin)
issues = list(data.get("warnings") or []) + list(data.get("analyzerWarnings") or [])
count = max(int(data.get("warningCount") or 0) + int(data.get("analyzerWarningCount") or 0), len(issues))
if count == 0:
    print("No build warnings.")
    sys.exit(0)
print(f"{count} build warning(s):", file=sys.stderr)
for issue in issues:
    where = ""
    url = issue.get("sourceURL") or ""
    if url.startswith("file://"):
        path, _, fragment = url[len("file://"):].partition("#")
        path = urllib.parse.unquote(path)
        if path.startswith(root):
            path = path[len(root):]
        line = urllib.parse.parse_qs(fragment).get("StartingLineNumber", [""])[0]
        # Xcode records 0-based line numbers.
        where = f"{path}:{int(line) + 1}: " if line.isdigit() else f"{path}: "
    kind = issue.get("issueType") or "Warning"
    message = issue.get("message") or ""
    target_name = issue.get("targetName")
    target = f" [{target_name}]" if target_name else ""
    print(f"  {where}{kind}: {message}{target}", file=sys.stderr)
sys.exit(1)
' "${ROOT}"
