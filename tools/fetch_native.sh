#!/usr/bin/env bash
# Fetch the native SIP engine sources (BSD-3). They are NOT vendored into this
# repository: they are large, and keeping them out means the app repo carries
# only our own code. Run this once before building the native engine.
set -e
# Resolve this script directory once, absolutely, BEFORE changing
# directory. Re-deriving it after the cd resolved it relative to
# native/, so the helpers below were looked for at native/tools/ and
# only ever worked when this script was invoked by absolute path.
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/../native"

clone() {
  if [ -d "$2" ]; then echo "$2 already present, skipping"; return; fi
  git clone --depth 1 "$1" "$2"
  rm -rf "$2/.git"   # avoid a nested repo inside this one
}

clone https://github.com/baresip/re.git re
clone https://github.com/baresip/baresip.git baresip

# macOS ships no "python", only "python3", while Windows ships a "python3"
# App Execution Alias that resolves on PATH and then refuses to run. Testing
# that the interpreter actually executes is the only check that holds on both.
if python3 -c "" >/dev/null 2>&1; then
  PY=python3
elif python -c "" >/dev/null 2>&1; then
  PY=python
else
  echo "error: no working python found (need python3 on macOS/Linux)." >&2
  exit 1
fi

echo
echo "Fetched. Both are 3-clause BSD - see each LICENSE file."
echo "Android additionally needs mbedTLS; see native/README.md."

# baresip ships every module it supports; trim to the mobile set. See the
# docstring in trim_modules.py for why this cannot be done with -DMODULES.
"$PY" "$HERE/trim_modules.py" "$HERE/../native/baresip/cmake/modules.cmake"

# libre's generic HMAC backend only does SHA-1, which breaks SIP registration
# on an mbedTLS build. See the docstring for the full story.
"$PY" "$HERE/patch_libre_hmac.py" "$HERE/../native/re/src/hmac/hmac.c"
