#ifndef BINDER_IDENTITY_H
#define BINDER_IDENTITY_H
#include <stdint.h>
#include "RegistrationTransport.h"
/* Headless identity observations only. No GUI object, permission, human grant,
 * Hardened Runtime or defense against malicious same-UID debugging is proven.
 * Peer credentials reflect socket last use, NOT per-message authentication;
 * deliberate FD transfer is not prevented. Keep the peer alive until ACK.
 * Only the original retained owned child confers cleanup rights; observation of
 * self or actual parent never grants termination or cleanup authority.
 *
 * File/resource snapshots are not AppBundle-resource validation. Static Security
 * APIs accept a path, not an FD: the held FD and ancestor rechecks do not make
 * path validation atomic with exec or eliminate transient TOCTOU. Dynamic audit
 * guest and code pin are additional checks; failures never fall back to file hash.
 * Deadlines are absolute CLOCK_MONOTONIC nanoseconds, at most 5 seconds ahead;
 * checks reject late results but cannot interrupt a blocking OS call. Caller owns
 * the separate maximum 45-second connection lifetime. On failure outputs are
 * unspecified and must not be used. No token bytes are exported. */
typedef enum { BI_OK = 0, BI_INVALID = 1, BI_EXPIRED = 2, BI_IO = 3, BI_CHANGED = 4 } BIError;
typedef struct { uint64_t size, dev, ino, nlink; uint32_t uid, gid, mode; int64_t mtime_sec, mtime_nsec, ctime_sec, ctime_nsec; uint8_t sha256[32]; } BIFileSnapshot;
typedef struct { BIFileSnapshot file; uint8_t code_hash[64]; uint32_t code_hash_len; char path[4096]; } BIImagePin;
typedef struct {
    int32_t pid, ppid;
    uint32_t ruid, euid, status, flags;
    uint64_t birth_sec, birth_usec;
    char path[4096];
} BIProcess;
typedef struct { BIProcess process; BIFileSnapshot file; uint8_t code_hash[64]; uint32_t code_hash_len, pidversion; } BIEvidence;
/* Observational only, never authority; exports no identity values. Diagnostic
 * contents are meaningful for BI_CHANGED and, only in bi_capture_peer_diagnostic,
 * populated BI_INVALID peer stages below. Other return values must not
 * be interpreted from the diagnostic record. The original evidence/output
 * failure contract above is unchanged. fields describes safe categories of
 * the first failed original comparison, not values or a causal attribution.
 * For snapshot path comparisons depth is root-to-leaf: 0 denotes / and the
 * maximum is 127. BI_DEPTH_NA denotes depth not applicable. */
typedef enum { BI_STAGE_NONE=0, BI_STAGE_READ_LIMIT, BI_STAGE_READ_SIZE,
 BI_STAGE_FSTAT, BI_STAGE_FSTATAT, BI_STAGE_REOPEN, BI_STAGE_REOPEN_FSTAT,
 BI_STAGE_PROCESS, BI_STAGE_PIN, BI_STAGE_PEER, BI_STAGE_SELF,
 /* Appended observational peer rejection stages; existing values stay fixed. */
 BI_STAGE_PEER_INPUT, BI_STAGE_PEER_FD, BI_STAGE_PEER_SOCKET_TYPE,
 BI_STAGE_PEER_LOCAL_ADDRESS, BI_STAGE_PEER_LOCAL_NAME,
 BI_STAGE_PEER_REMOTE_ADDRESS, BI_STAGE_PEER_REMOTE_NAME,
 BI_STAGE_PEER_POLL, BI_STAGE_PEER_PID, BI_STAGE_PEER_TOKEN,
 BI_STAGE_PEER_CREDENTIALS, BI_STAGE_PEER_PROCESS_CAPTURE,
 BI_STAGE_PEER_PROCESS_IDENTITY, BI_STAGE_PEER_MATCH } BIStage;
enum { BI_F_UNAVAILABLE=1ULL<<0, BI_F_SIZE=1ULL<<1, BI_F_DEV=1ULL<<2,
 BI_F_INO=1ULL<<3, BI_F_MODE=1ULL<<4, BI_F_UID=1ULL<<5,
 BI_F_GID=1ULL<<6, BI_F_NLINK=1ULL<<7, BI_F_MTIME=1ULL<<8,
 BI_F_CTIME=1ULL<<9, BI_F_PID=1ULL<<10, BI_F_PPID=1ULL<<11,
 BI_F_RUID=1ULL<<12, BI_F_EUID=1ULL<<13, BI_F_BIRTH=1ULL<<14,
 BI_F_STATUS=1ULL<<15, BI_F_FLAGS=1ULL<<16, BI_F_PATH=1ULL<<17,
 BI_F_TOKEN=1ULL<<18, BI_F_HASH_LENGTH=1ULL<<19, BI_F_HASH=1ULL<<20,
 BI_F_CONTENT=1ULL<<21 };
#define BI_DEPTH_NA UINT32_MAX
typedef struct { BIStage stage; uint64_t fields; uint32_t depth; } BIDiagnostic;
BIError bi_snapshot_diagnostic(const char *, uint64_t, BIFileSnapshot *, BIDiagnostic *);
BIError bi_static_pin_diagnostic(const char *, uint64_t, BIImagePin *, BIDiagnostic *);
BIError bi_process_metadata_diagnostic(int32_t, uint64_t, BIProcess *, BIDiagnostic *);
BIError bi_capture_self_diagnostic(const BIImagePin *, uint64_t, BIEvidence *, BIDiagnostic *);
BIError bi_capture_peer_diagnostic(int, const BIProcess *, const BIImagePin *, uint64_t, BIEvidence *, BIDiagnostic *);
/* 0 indicates invalid duration or failure. */
uint64_t bi_deadline_after_ms(uint32_t milliseconds);
/* Trusted absolute path; secure root/euid-owned ancestors, same-euid leaf. */
BIError bi_snapshot(const char *absolute_path, uint64_t deadline_ns, BIFileSnapshot *out);
BIError bi_static_pin(const char *absolute_path, uint64_t deadline_ns, BIImagePin *out);
/* Caller may observe only self, its original retained owned child, or its
 * actual getppid() parent. For actual parent, caller must sample getppid() both
 * before and after capture, ensure it remains unchanged, and verify same EUID,
 * same reviewed pinned image, and a stable parent birth identity. Never use a
 * PID from IPC or scanning. This call only captures metadata; it does not
 * enforce those caller obligations or grant authentication/cleanup rights. */
BIError bi_process_metadata(int32_t observed_pid, uint64_t deadline_ns, BIProcess *out);
/* Self uses SecCodeCopySelf; pidversion is zero, not a synthetic audit token. */
BIError bi_capture_self(const BIImagePin *pin, uint64_t deadline_ns, BIEvidence *out);
/* Connected anonymous AF_UNIX stream; call after peer sends, before its ACK.
 * expected must derive from the actual parent validated as above, or the
 * original retained owned child, never from IPC or scanning. Caller enforces
 * the getppid() relationship for the parent before and after capture. Existing
 * audit, UID, process birth, path and pinned code checks remain mandatory. */
BIError bi_capture_peer(int fd, const BIProcess *expected, const BIImagePin *pin, uint64_t deadline_ns, BIEvidence *out);
/* Compare each later peer observation with the initial observation, including
 * pidversion; neither function is an ownership or liveness guarantee. */
int bi_evidence_same(const BIEvidence *first, const BIEvidence *later);
int bi_match(const BIImagePin *pin, const BIProcess *expected, const BIEvidence *evidence);
int bi_fixture_file_equal(const BIFileSnapshot *, const BIFileSnapshot *);
BIError bi_snapshot_limited(const char *, uint64_t, uint64_t, BIFileSnapshot *);
int bi_fixture_deadline_valid(uint64_t);
#endif
