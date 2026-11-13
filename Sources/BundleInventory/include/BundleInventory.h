#ifndef BUNDLE_INVENTORY_H
#define BUNDLE_INVENTORY_H
#include <stddef.h>
#include <stdint.h>
#include "BinderIdentity.h"
/* Untrusted observation, not an authority. Caller must compare independently
 * trusted namespace and file hashes before using it to construct a binding. */
typedef enum { BB_OK=0, BB_INVALID=1, BB_EXPIRED=2, BB_IO=3, BB_CHANGED=4 } BBError;
typedef struct BBInventory BBInventory;
typedef struct { uint8_t code_hash[64]; uint32_t code_hash_len; } BBCodeIdentity;
typedef struct { const char *path; int is_directory; uint64_t size; const uint8_t *sha256; } BBEntry;
typedef struct { const char *path; int is_directory; const uint8_t *sha256; } BBExpected;
BBError bb_inventory(const char *, uint64_t, BBInventory **);
void bb_free(BBInventory *);
size_t bb_count(const BBInventory *);
int bb_entry(const BBInventory *, size_t, BBEntry *);
BBError bb_expect_exact(const BBInventory *, const BBExpected *, size_t);
int bb_content_digest(const BBInventory *, uint8_t out[32]);
BBError bb_validate_signature(const char *, const char *, uint64_t, BBCodeIdentity *);
BBError bb_revalidate(BBInventory *, const char *, const char *, uint64_t);
#endif
