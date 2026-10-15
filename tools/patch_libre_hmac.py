"""Give libre's generic HMAC backend SHA-256 support.

Upstream picks an HMAC backend in the order OpenSSL, Apple, generic - and
mbedTLS is not in that chain. An mbedTLS build therefore gets src/hmac/hmac.c,
which hard-codes:

    if (hash != HMAC_HASH_SHA1)
            return ENOTSUP;

SIP registration asks for HMAC-SHA256, so every REGISTER failed with errno 95
(ENOTSUP == EOPNOTSUPP on bionic), surfacing as the thoroughly misleading
"Operation not supported on transport endpoint".

The fix is small because the free functions hmac_sha1() and hmac_sha256()
already have working mbedTLS implementations in hmac_sha1.c. Only the streaming
pair needed to learn to dispatch. Run from tools/fetch_native.sh after cloning.
"""
import sys
from pathlib import Path

NEW = '''/**
 * @file hmac/hmac.c  HMAC-SHA1 and HMAC-SHA256
 *
 * Copyright (C) 2010 Creytiv.com
 *
 * Patched for Cosmiq VoIP: see tools/patch_libre_hmac.py. Upstream only
 * supports SHA-1 here, which breaks SIP registration on an mbedTLS build.
 */
#include <string.h>
#include <re_types.h>
#include <re_mem.h>
#include <re_sha.h>
#include <re_hmac.h>


struct hmac {
\tenum hmac_hash hash;
\tuint8_t key[64];        /* SHA-256 block size; covers SHA-1 too */
\tsize_t key_len;
};


static void destructor(void *arg)
{
\tstruct hmac *hmac = arg;

\tmemset(hmac, 0, sizeof(*hmac));
}


int hmac_create(struct hmac **hmacp, enum hmac_hash hash,
\t\tconst uint8_t *key, size_t key_len)
{
\tstruct hmac *hmac;

\tif (!hmacp || !key || !key_len)
\t\treturn EINVAL;

\tif (hash != HMAC_HASH_SHA1 && hash != HMAC_HASH_SHA256)
\t\treturn ENOTSUP;

\thmac = mem_zalloc(sizeof(*hmac), destructor);
\tif (!hmac)
\t\treturn ENOMEM;

\tif (key_len > sizeof(hmac->key)) {
\t\t/* Longer keys are hashed down by the HMAC construction; the
\t\t * underlying helpers handle that, so just refuse to overflow. */
\t\tmem_deref(hmac);
\t\treturn EINVAL;
\t}

\thmac->hash = hash;
\tmemcpy(hmac->key, key, key_len);
\thmac->key_len = key_len;

\t*hmacp = hmac;

\treturn 0;
}


int hmac_digest(struct hmac *hmac, uint8_t *md, size_t md_len,
\t\tconst uint8_t *data, size_t data_len)
{
\tif (!hmac || !md || !md_len || !data || !data_len)
\t\treturn EINVAL;

\tif (hmac->hash == HMAC_HASH_SHA256)
\t\thmac_sha256(hmac->key, hmac->key_len, data, data_len,
\t\t\t    md, md_len);
\telse
\t\thmac_sha1(hmac->key, hmac->key_len, data, data_len,
\t\t\t  md, md_len);

\treturn 0;
}
'''

path = Path(sys.argv[1] if len(sys.argv) > 1 else "native/re/src/hmac/hmac.c")
if "Patched for Cosmiq VoIP" in path.read_text(encoding="utf-8"):
    print(f"{path} already patched")
else:
    path.write_text(NEW.replace("\t", "\t"), encoding="utf-8")
    print(f"patched {path} for HMAC-SHA256")
