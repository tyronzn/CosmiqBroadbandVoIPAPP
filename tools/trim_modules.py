"""Trim baresip's module list to the ones a mobile softphone needs.

baresip ships every module it supports, including desktop-only video and audio
backends. Two reasons to cut the list down:

  * `cmake/FindV4L2.cmake` calls `find_package(PkgConfig REQUIRED)`, and
    pkg-config does not exist on a stock Windows box, so configuring the full
    list hard-fails before it reaches anything we care about.
  * We ship a voice softphone. Pulling in SDL, ffmpeg and friends would bloat
    the binary with code no call will ever execute.

The list is hard-set in cmake/modules.cmake rather than being a cache variable,
so -DMODULES= cannot override it; it has to be rewritten in place. Run from
tools/fetch_native.sh after cloning.
"""
import re
import sys
from pathlib import Path

WANTED = [
    "account",    # account/config handling
    "auconv",     # sample format conversion
    "auresamp",   # resampling
    "g711",       # PCMA/PCMU - what PortaSIP actually negotiates
    "stun", "turn", "ice",   # NAT traversal
    "srtp",       # available if the carrier ever enables it
    "uuid",
    # Android audio: opensles only. The aaudio module calls
    # AAudioStreamBuilder_setSessionId/setUsage, which are API 28, while the
    # app ships minSdk 26 - building it would fail, or crash on 26/27 devices.
    # Revisit if minSdk ever moves to 28, since AAudio has lower latency.
    "opensles",
    "audiounit",             # iOS/macOS audio
]

path = Path(sys.argv[1] if len(sys.argv) > 1 else "native/baresip/cmake/modules.cmake")
text = path.read_text(encoding="utf-8")

match = re.search(r"set\(MODULES\b.*?\n\)", text, re.S)
if not match:
    sys.exit(f"could not find the MODULES block in {path}")

block = "set(MODULES\n" + "".join(f"  {m}\n" for m in WANTED) + ")"
path.write_text(text[: match.start()] + block + text[match.end() :], encoding="utf-8")
print(f"trimmed {path} to {len(WANTED)} mobile modules")
