#!/bin/sh
# Checks that can be run without a device. Needs `lua` and `luac` (5.4+).
#
#   cd spec && ./run.sh
#
# The specs load the real main.lua under a stubbed KOReader environment and
# drive collectSessions to exhaustion, so they exercise the shipping code rather
# than a model of it.
set -e
cd "$(dirname "$0")"

echo "== syntax =="
luac -p ../main.lua ../_meta.lua
echo "ok"

echo
echo "== forward references =="
# The bug that once made this plugin a silent no-op: a `local function` used
# above its own declaration compiles to a global lookup, returns nil and throws
# inside a pcall. Every _ENV read should be a stdlib name — anything else is
# either a genuine global (there should be none) or that bug.
luac -p -l -l ../main.lua \
  | sed -n 's/.*GETTABUP.*_ENV "\([A-Za-z_][A-Za-z0-9_]*\)".*/\1/p' \
  | sort -u > /tmp/storylines_globals.txt
cat /tmp/storylines_globals.txt
if grep -qvE '^(require|pcall|ipairs|pairs|type|tostring|tonumber|os|table|string|math|error|select|next|setmetatable)$' /tmp/storylines_globals.txt; then
  echo "FAIL: unexpected global read above — check for a local declared after use"
  exit 1
fi
echo "ok"

echo
echo "== session watermark =="
lua verify.lua

echo
echo "== deferred sitting is delivered =="
lua deferred.lua
