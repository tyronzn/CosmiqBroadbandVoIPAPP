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
