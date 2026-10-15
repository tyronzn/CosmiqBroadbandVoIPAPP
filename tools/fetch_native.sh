#!/usr/bin/env bash
# Fetch the native SIP engine sources (BSD-3). They are NOT vendored into this
# repository: they are large, and keeping them out means the app repo carries
# only our own code. Run this once before building the native engine.
set -e
cd "$(dirname "$0")/../native"

clone() {
  if [ -d "$2" ]; then echo "$2 already present, skipping"; return; fi
  git clone --depth 1 "$1" "$2"
  rm -rf "$2/.git"   # avoid a nested repo inside this one
}

clone https://github.com/baresip/re.git re
clone https://github.com/baresip/baresip.git baresip

echo
echo "Fetched. Both are 3-clause BSD - see each LICENSE file."
echo "Android additionally needs mbedTLS; see native/README.md."

# baresip ships every module it supports; trim to the mobile set. See the
# docstring in trim_modules.py for why this cannot be done with -DMODULES.
python "$(dirname "$0")/trim_modules.py" "$(dirname "$0")/../native/baresip/cmake/modules.cmake"

# libre's generic HMAC backend only does SHA-1, which breaks SIP registration
# on an mbedTLS build. See the docstring for the full story.
python "$(dirname "$0")/patch_libre_hmac.py" "$(dirname "$0")/../native/re/src/hmac/hmac.c"
