"""Give libre's Apple build the TLS stub it is missing.

libre picks its crypto sources in the order OpenSSL -> Apple -> generic:

    if(USE_OPENSSL)        src/tls/openssl/*.c  src/aes/openssl  src/hmac/openssl
    elseif(APPLE)                               src/aes/apple    src/hmac/apple
    else()                 src/tls/stub.c       src/aes/stub.c   src/hmac/hmac.c

Note what the middle branch does not have. The generic branch gets
`src/tls/stub.c`; the Apple branch gets no TLS source whatsoever.

That is almost harmless, because `USE_TLS` is only defined under `USE_OPENSSL`
(cmake/re-config.cmake), so nearly every `tls_*` call in libre and baresip sits
inside an `#ifdef USE_TLS` and compiles out. Almost: baresip's `src/ua.c:1280`
calls `tls_add_certf()` with no guard at all - unlike the sibling call in
`src/uag.c:291`, which is guarded. So an Apple build of baresip links fine
right up to:

    Undefined symbol: _tls_add_certf

The generic branch's stub already defines that function, and 40-odd others
like it, each returning an error. Adding it to the Apple branch costs nothing
- these are stubs, and TLS is genuinely unavailable on this build either way,
which suits a deployment whose SIP host has 5061 closed.

Idempotent, and a no-op for the Android build, which takes the generic branch
and so already has the stub. Run from tools/fetch_native.sh after cloning.
"""
import re
import sys
from pathlib import Path

path = Path(sys.argv[1] if len(sys.argv) > 1 else "native/re/CMakeLists.txt")
text = path.read_text(encoding="utf-8")

STUB = "src/tls/stub.c"

# The Apple branch: from "elseif(APPLE)" up to the matching "else()".
match = re.search(r"elseif\(APPLE\)\s*\n\s*list\(APPEND SRCS\n(.*?)\n(\s*)\)",
                  text, re.S)
if not match:
    sys.exit(f"could not find the elseif(APPLE) SRCS block in {path}")

body, closing_indent = match.group(1), match.group(2)

if STUB in body:
    print(f"{path} already has {STUB} on the Apple branch")
    sys.exit(0)

# Match the indentation the existing entries use rather than assuming two
# spaces; libre is not consistent across its CMakeLists.
indent = re.match(r"\s*", body).group(0).replace("\n", "") or "    "
new_body = body + "\n" + indent + STUB

text = text[: match.start()] + (
    "elseif(APPLE)\n"
    + closing_indent
    + "list(APPEND SRCS\n"
    + new_body
    + "\n"
    + closing_indent
    + ")"
) + text[match.end():]

path.write_text(text, encoding="utf-8")
print(f"added {STUB} to the Apple branch of {path}")
