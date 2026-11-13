#include <stdint.h>
#include <sys/types.h>
#include "BinderIdentity.h"
int32_t g1_permission_bid(void);
int32_t g1_request_permission_bid(void);
int host_capture(pid_t pid, BIProcess *out);
int host_equal(const BIProcess *a, const BIProcess *b);
int host_expected(const BIProcess *p, pid_t parent, uid_t uid, const char *path);
#include <stddef.h>
int32_t host_osa_script(const uint8_t *source, size_t source_len, const BIProcess *expected, uint32_t timeout_seconds,
                        uint8_t *output, size_t capacity, size_t *written, int32_t *script_error,
                        uint32_t *rejected_class, uint32_t *rejected_id, int32_t *rejected_status);
/* Copy a bounded private snapshot without treating its path as deletion authority. */
int host_copy_hover_png(const char *workspace, const char *returned_path, const char *results);
int host_copy_form_png(const char *workspace, const char *returned_path, const char *results);
