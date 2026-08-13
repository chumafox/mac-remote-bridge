#!/usr/bin/env bash
# Local stand-in for CI. GitHub App tokens cannot push workflow files,
# so this repo ships the checks as a script instead of Actions YAML.
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "${root}"

ver=$(sed -n 's/^readonly VERSION="//p' bridge.sh | tr -d '"')

echo "==> bash -n"
bash -n bridge.sh

echo "==> __selftest"
bash bridge.sh __selftest

echo "==> CLI smoke"
test "$(bash bridge.sh -V)" = "${ver}"
bash bridge.sh --help | grep -q 'mac-remote-bridge'
bash bridge.sh start --help | grep -q 'Usage:'
bash bridge.sh doctor >/dev/null
bash bridge.sh status --json | grep -q '"version"'
if bash bridge.sh --lang de status >/dev/null 2>&1; then
  echo "expected --lang de to fail" >&2
  exit 1
fi

echo "==> docs agree with the script"
grep -q "^## ${ver} " CHANGELOG.md
grep -q "Print \`${ver}\`" README.md
grep -q 'never silently re-downloads' README.md
grep -qi 'does not re-download' SECURITY.md
grep -q 'private GitHub security advisory' SECURITY.md
if grep -q 'pkill -f pinggy' README.md; then
  echo "README must not recommend pkill" >&2
  exit 1
fi
grep -q 'last resort' CHANGELOG.md
grep -q 'MIT License' LICENSE

echo "check.sh: ok (version ${ver})"
