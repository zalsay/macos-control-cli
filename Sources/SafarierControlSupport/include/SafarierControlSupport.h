#ifndef SAFARIER_CONTROL_SUPPORT_H
#define SAFARIER_CONTROL_SUPPORT_H
#include <stdint.h>

/* Observations of the actual connected AF_UNIX peer, never a routing target or
 * a grant to signal or terminate it. Recheck around each protocol phase. */
typedef struct {
    int32_t pid;
    uint32_t uid, pidversion;
    uint64_t birth_sec, birth_usec;
    uint8_t audit_digest[32];
} CSControlPeer;

/* Same signed image and exact executable path as this process, with live,
 * stable kernel socket audit credentials. Zero is failure; outputs unspecified. */
/* Verify this process's signed image and safe executable path before serving. */
int cs_control_verify_self(void);
int cs_control_verify_peer(int socket_fd, CSControlPeer *out);
int cs_control_peer_equal(const CSControlPeer *a, const CSControlPeer *b);

typedef struct {
    int32_t pid;
    uint32_t uid;
    uint64_t birth_sec, birth_usec;
    uint8_t code_hash[64];
    uint32_t code_hash_len;
} CSControlManager;

/* pid is metadata from the unique held NSRunningApplication, never a target
 * address. The actual Apple Event is always addressed to a bundle identifier. */
int cs_control_capture_manager(int32_t pid, const char *expected_executable, CSControlManager *out);
int cs_control_manager_equal(const CSControlManager *a, const CSControlManager *b);
int cs_control_reply_sender_matches(const void *audit_bytes, unsigned long length, const CSControlManager *manager);

/* Permission-only API, fixed SFAu/requ. request_consent must be 0 or 1.
 * May wait for human consent; call off the main thread. No business AE sent.
 * target_changed overrides any permission result; captures use fresh deadlines. */
int32_t cs_control_authorization(const char *bundle_id, int request_consent,
                                 const CSControlManager *manager, const char *expected_executable,
                                 int *target_changed);

/* TCC is checked with askUserIfNeeded=false. Address is a bundle identifier,
 * never a PID. The original manager proof is recaptured around preflight and
 * send. sent is set before AESendMessage: later errors are indeterminate.
 * A reply is usable only when its OS sender audit token was verified. */
int32_t cs_control_send_apple_event(const char *bundle_id, const uint8_t *request, unsigned long request_len,
                                    uint32_t timeout_seconds, const CSControlManager *manager, const char *expected_executable,
                                    uint8_t *reply, unsigned long capacity, unsigned long *reply_len,
                                    int *sent, int *sender_audit, uint32_t *phase, const uint8_t request_id[16]);
#endif
