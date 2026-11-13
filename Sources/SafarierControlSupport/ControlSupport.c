#include "SafarierControlSupport.h"
#include "BinderIdentity.h"
#include <Security/Security.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <bsm/libbsm.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <poll.h>
#include <time.h>
#include <string.h>
#include <unistd.h>
#include <os/log.h>
#include <uuid/uuid.h>

static int peer_token(int fd, audit_token_t *token, pid_t *pid) {
    int type = 0; socklen_t size = sizeof(type);
    struct sockaddr_un local = {0}, remote = {0};
    if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &size) || size != sizeof(type) || type != SOCK_STREAM) return 0;
    size = sizeof(local); if (getsockname(fd, (struct sockaddr *)&local, &size) || local.sun_family != AF_UNIX) return 0;
    size = sizeof(remote); if (getpeername(fd, (struct sockaddr *)&remote, &size) || remote.sun_family != AF_UNIX) return 0;
    struct pollfd poller = { .fd = fd };
    if (poll(&poller, 1, 0) < 0 || (poller.revents & (POLLHUP | POLLERR | POLLNVAL))) return 0;
    uid_t uid; gid_t gid;
    if (getpeereid(fd, &uid, &gid) || uid != geteuid()) return 0;
    size = sizeof(*pid); if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, pid, &size) || size != sizeof(*pid) || *pid <= 0) return 0;
    size = sizeof(*token); if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, token, &size) || size != sizeof(*token)) return 0;
    return audit_token_to_pid(*token) == *pid && audit_token_to_euid(*token) == uid && audit_token_to_ruid(*token) == getuid();
}

static int process_sample(pid_t pid, struct proc_bsdinfo *info, char path[PROC_PIDPATHINFO_MAXSIZE]) {
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, info, sizeof(*info)) != sizeof(*info)) return 0;
    if (info->pbi_pid != (uint32_t)pid || info->pbi_uid != geteuid() || info->pbi_ruid != getuid() ||
        (info->pbi_status != 2 && info->pbi_status != 3) || (info->pbi_flags & (2U | 4U | 0x2000U)) || info->pbi_start_tvusec >= 1000000) return 0;
    int n = proc_pidpath(pid, path, PROC_PIDPATHINFO_MAXSIZE);
    return n > 0 && n < PROC_PIDPATHINFO_MAXSIZE && path[0] == '/' && memchr(path, '\0', PROC_PIDPATHINFO_MAXSIZE);
}

static int peer_code(const audit_token_t *token, uint8_t out[64], uint32_t *length) {
    int ok = 0; SecCodeRef code = NULL; CFDictionaryRef attrs = NULL, info = NULL; CFDataRef data = NULL;
    data = CFDataCreate(NULL, (const UInt8 *)token, sizeof(*token)); if (!data) goto done;
    const void *keys[] = { kSecGuestAttributeAudit }, *values[] = { data };
    attrs = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks); if (!attrs) goto done;
    if (SecCodeCopyGuestWithAttributes(NULL, attrs, kSecCSDefaultFlags, &code) != errSecSuccess || !code) goto done;
    if (SecCodeCheckValidity(code, kSecCSDefaultFlags, NULL) != errSecSuccess) goto done;
    if (SecCodeCopySigningInformation(code, kSecCSSigningInformation | kSecCSDynamicInformation, &info) != errSecSuccess || !info) goto done;
    CFTypeRef value = CFDictionaryGetValue(info, kSecCodeInfoUnique);
    if (!value || CFGetTypeID(value) != CFDataGetTypeID()) goto done;
    CFIndex n = CFDataGetLength((CFDataRef)value); if (n <= 0 || n > 64) goto done;
    CFDataGetBytes((CFDataRef)value, CFRangeMake(0, n), out); *length = (uint32_t)n; ok = 1;
done:
    if (info) CFRelease(info); if (code) CFRelease(code); if (attrs) CFRelease(attrs); if (data) CFRelease(data);
    return ok;
}

typedef struct {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    BIImagePin pin;
    BIEvidence evidence;
} ControlSelf;

static int control_self_begin(uint64_t deadline, ControlSelf *self) {
    int length = proc_pidpath(getpid(), self->path, sizeof(self->path));
    if (length <= 0 || length >= sizeof(self->path) || self->path[0] != '/') return 0;
    return bi_static_pin(self->path, deadline, &self->pin) == BI_OK &&
        bi_capture_self(&self->pin, deadline, &self->evidence) == BI_OK;
}

static int control_self_finish(uint64_t deadline, const ControlSelf *self) {
    BIImagePin again = {0};
    return bi_static_pin(self->path, deadline, &again) == BI_OK &&
        bi_fixture_file_equal(&self->pin.file, &again.file) &&
        self->pin.code_hash_len == again.code_hash_len &&
        !memcmp(self->pin.code_hash, again.code_hash, self->pin.code_hash_len) &&
        bi_fixture_deadline_valid(deadline);
}

int cs_control_verify_self(void) {
    uint64_t deadline = bi_deadline_after_ms(5000);
    ControlSelf self = {0};
    return deadline && control_self_begin(deadline, &self) && control_self_finish(deadline, &self);
}

int cs_control_verify_peer(int fd, CSControlPeer *out) {
    if (!out || fd < 0) return 0;
    uint64_t deadline = bi_deadline_after_ms(5000); if (!deadline) return 0;
    audit_token_t first = {0}, second = {0}; pid_t p = 0, q = 0;
    struct proc_bsdinfo a = {0}, b = {0}; char pathA[PROC_PIDPATHINFO_MAXSIZE] = {0}, pathB[PROC_PIDPATHINFO_MAXSIZE] = {0};
    ControlSelf self = {0}; uint8_t hashA[64] = {0}, hashB[64] = {0}; uint32_t lenA = 0, lenB = 0;
    if (!control_self_begin(deadline, &self)) return 0;
    if (!peer_token(fd, &first, &p) || !process_sample(p, &a, pathA) || strcmp(pathA, self.path)) return 0;
    if (!peer_code(&first, hashA, &lenA) || !peer_code(&first, hashB, &lenB)) return 0;
    if (lenA != self.evidence.code_hash_len || lenA != lenB || memcmp(hashA, self.evidence.code_hash, lenA) || memcmp(hashA, hashB, lenA)) return 0;
    if (!process_sample(p, &b, pathB) || !peer_token(fd, &second, &q) || p != q || memcmp(&first, &second, sizeof(first))) return 0;
    if (a.pbi_pid != b.pbi_pid || a.pbi_uid != b.pbi_uid || a.pbi_ruid != b.pbi_ruid || a.pbi_start_tvsec != b.pbi_start_tvsec || a.pbi_start_tvusec != b.pbi_start_tvusec || strcmp(pathA, pathB)) return 0;
    if (!control_self_finish(deadline, &self)) return 0;
    CSControlPeer result = { .pid = p, .uid = a.pbi_uid, .pidversion = audit_token_to_pidversion(first), .birth_sec = a.pbi_start_tvsec, .birth_usec = a.pbi_start_tvusec };
    CC_SHA256(&first, sizeof(first), result.audit_digest); *out = result;
    memset(&first, 0, sizeof(first)); memset(&second, 0, sizeof(second));
    return 1;
}

int cs_control_peer_equal(const CSControlPeer *a, const CSControlPeer *b) {
    return a && b && a->pid == b->pid && a->uid == b->uid && a->pidversion == b->pidversion && a->birth_sec == b->birth_sec && a->birth_usec == b->birth_usec && !memcmp(a->audit_digest, b->audit_digest, sizeof(a->audit_digest));
}

static int code_for_pid(pid_t pid, uint8_t out[64], uint32_t *length) {
    int ok = 0; SecCodeRef code = NULL; CFDictionaryRef attrs = NULL, info = NULL; CFNumberRef number = NULL;
    int32_t value = pid;
    number = CFNumberCreate(NULL, kCFNumberSInt32Type, &value); if (!number) goto done;
    const void *keys[] = { kSecGuestAttributePid }, *values[] = { number };
    attrs = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks); if (!attrs) goto done;
    if (SecCodeCopyGuestWithAttributes(NULL, attrs, kSecCSDefaultFlags, &code) != errSecSuccess || !code) goto done;
    if (SecCodeCheckValidity(code, kSecCSDefaultFlags, NULL) != errSecSuccess) goto done;
    if (SecCodeCopySigningInformation(code, kSecCSSigningInformation | kSecCSDynamicInformation, &info) != errSecSuccess || !info) goto done;
    CFTypeRef hash = CFDictionaryGetValue(info, kSecCodeInfoUnique);
    if (!hash || CFGetTypeID(hash) != CFDataGetTypeID()) goto done;
    CFIndex n = CFDataGetLength((CFDataRef)hash); if (n <= 0 || n > 64) goto done;
    CFDataGetBytes((CFDataRef)hash, CFRangeMake(0, n), out); *length = (uint32_t)n; ok = 1;
done:
    if (info) CFRelease(info); if (code) CFRelease(code); if (attrs) CFRelease(attrs); if (number) CFRelease(number);
    return ok;
}

int cs_control_capture_manager(int32_t pid, const char *expected, CSControlManager *out) {
    if (pid <= 0 || !expected || expected[0] != '/' || !out) return 0;
    uint64_t deadline = bi_deadline_after_ms(5000); if (!deadline) return 0;
    struct proc_bsdinfo a = {0}, b = {0}; char pathA[PROC_PIDPATHINFO_MAXSIZE] = {0}, pathB[PROC_PIDPATHINFO_MAXSIZE] = {0};
    BIImagePin pin = {0}, again = {0}; uint8_t first[64] = {0}, second[64] = {0}; uint32_t n = 0, m = 0;
    if (!process_sample(pid, &a, pathA) || strcmp(pathA, expected)) return 0;
    if (bi_static_pin(expected, deadline, &pin) != BI_OK || !code_for_pid(pid, first, &n) || !code_for_pid(pid, second, &m)) return 0;
    if (n != m || n != pin.code_hash_len || memcmp(first, second, n) || memcmp(first, pin.code_hash, n)) return 0;
    if (!process_sample(pid, &b, pathB) || strcmp(pathA, pathB) || a.pbi_pid != b.pbi_pid || a.pbi_uid != b.pbi_uid || a.pbi_ruid != b.pbi_ruid || a.pbi_start_tvsec != b.pbi_start_tvsec || a.pbi_start_tvusec != b.pbi_start_tvusec) return 0;
    if (bi_static_pin(expected, deadline, &again) != BI_OK || !bi_fixture_file_equal(&pin.file, &again.file) || pin.code_hash_len != again.code_hash_len || memcmp(pin.code_hash, again.code_hash, pin.code_hash_len) || !bi_fixture_deadline_valid(deadline)) return 0;
    CSControlManager value = { .pid = pid, .uid = a.pbi_uid, .birth_sec = a.pbi_start_tvsec, .birth_usec = a.pbi_start_tvusec, .code_hash_len = n };
    memcpy(value.code_hash, first, n); *out = value; return 1;
}

int cs_control_manager_equal(const CSControlManager *a, const CSControlManager *b) {
    return a && b && a->pid == b->pid && a->uid == b->uid && a->birth_sec == b->birth_sec && a->birth_usec == b->birth_usec && a->code_hash_len > 0 && a->code_hash_len <= 64 && a->code_hash_len == b->code_hash_len && !memcmp(a->code_hash, b->code_hash, a->code_hash_len);
}

int cs_control_reply_sender_matches(const void *bytes, unsigned long length, const CSControlManager *manager) {
    if (!bytes || length != sizeof(audit_token_t) || !manager || manager->pid <= 0 || !manager->code_hash_len || manager->code_hash_len > 64) return 0;
    audit_token_t token = {0}; memcpy(&token, bytes, sizeof(token));
    if (audit_token_to_pid(token) != manager->pid || audit_token_to_euid(token) != manager->uid || audit_token_to_ruid(token) != getuid()) return 0;
    struct proc_bsdinfo info = {0}; char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (!process_sample(manager->pid, &info, path) || info.pbi_start_tvsec != manager->birth_sec || info.pbi_start_tvusec != manager->birth_usec) return 0;
    uint8_t hash[64] = {0}; uint32_t n = 0;
    return peer_code(&token, hash, &n) && n == manager->code_hash_len && !memcmp(hash, manager->code_hash, n);
}

#include <Carbon/Carbon.h>
static uint64_t control_now_ns(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now)) return 0;
    return (uint64_t)now.tv_sec * 1000000000ULL + (uint64_t)now.tv_nsec;
}
static int control_before(uint64_t deadline) { uint64_t now = control_now_ns(); return now && now < deadline; }
static int manager_still_matches(const CSControlManager *expected, const char *path) {
    CSControlManager current = {0};
    return cs_control_capture_manager(expected->pid, path, &current) && cs_control_manager_equal(expected, &current);
}
int32_t cs_control_send_apple_event(const char *bundle_id, const uint8_t *request, unsigned long request_len,
                                    uint32_t timeout_seconds, const CSControlManager *manager, const char *expected_executable,
                                    uint8_t *reply_bytes, unsigned long capacity, unsigned long *reply_len,
                                    int *sent, int *sender_audit, uint32_t *phase, const uint8_t request_id[16]) {
    if (!bundle_id || !request || !request_len || request_len > 65536 || !manager || !expected_executable || !reply_bytes || !capacity || capacity > 65536 || !reply_len || !sent || !sender_audit || !phase || !request_id || !timeout_seconds || timeout_seconds > 70) return paramErr;
    uuid_string_t trace_id; uuid_unparse_upper(request_id, trace_id);
    os_log_t trace = os_log_create("sh.safarier.testing", "navigation-trace");
#define TRACE(stage) os_log_with_type(trace, OS_LOG_TYPE_DEFAULT, "request=%{public}s phase=sender.native.%{public}s", trace_id, stage)
    TRACE("enter");
    size_t bid_len = strnlen(bundle_id, 256);
    if (!bid_len || bid_len >= 256) { os_release(trace); return paramErr; }
    *sent = 0; *sender_audit = 0; *reply_len = 0; *phase = 1;
    uint64_t start = control_now_ns();
    if (!start) { os_release(trace); return errAETimeout; }
    uint64_t deadline = start + (uint64_t)timeout_seconds * 1000000000ULL;
    AEAddressDesc address = { typeNull, NULL }; AppleEvent event = { typeNull, NULL }, reply = { typeNull, NULL }; AEDesc direct = { typeNull, NULL };
    TRACE("preIdentity.before");
    if (!manager_still_matches(manager, expected_executable) || !control_before(deadline)) { TRACE("preIdentity.rejected"); os_release(trace); return errAEEventNotPermitted; }
    TRACE("preIdentity.after");
    *phase = 2;
    TRACE("address.before");
    OSStatus status = AECreateDesc(typeApplicationBundleID, bundle_id, (Size)bid_len, &address);
    TRACE("address.after");
    if (status != noErr) goto done;
    *phase = 3;
    TRACE("permission.before");
    status = AEDeterminePermissionToAutomateTarget(&address, 'SFAu', 'requ', false);
    TRACE("permission.after");
    if (status != noErr) goto done;
    *phase = 4;
    TRACE("postPermissionIdentity.before");
    if (!manager_still_matches(manager, expected_executable) || !control_before(deadline)) { status = errAEEventNotPermitted; goto done; }
    TRACE("postPermissionIdentity.after");
    *phase = 5;
    TRACE("createEvent.before");
    status = AECreateAppleEvent('SFAu', 'requ', &address, kAutoGenerateReturnID, kAnyTransactionID, &event);
    TRACE("createEvent.after");
    if (status != noErr) goto done;
    *phase = 6;
    TRACE("parameter.before");
    status = AEPutParamPtr(&event, keyDirectObject, typeUTF8Text, request, (Size)request_len);
    TRACE("parameter.after");
    if (status != noErr) goto done;
    *phase = 7;
    TRACE("preSendIdentity.before");
    if (!manager_still_matches(manager, expected_executable)) { status = errAEEventNotPermitted; goto done; }
    TRACE("preSendIdentity.after");
    uint64_t now = control_now_ns();
    if (!now || now >= deadline) { status = errAETimeout; goto done; }
    uint64_t ticks = (deadline - now) * 60ULL / 1000000000ULL;
    if (!ticks) { status = errAETimeout; goto done; }
    *sent = 1;
    *phase = 8;
    TRACE("send.before");
    status = AESendMessage(&event, &reply, kAEWaitReply | kAENeverInteract | kAEDontRecord | kAEDoNotPromptForUserConsent | kAEDontReconnect, (long)ticks);
    TRACE("send.after");
    if (status != noErr) goto done;
    *phase = 9;
    TRACE("postReplyIdentity.before");
    if (!manager_still_matches(manager, expected_executable) || !control_before(deadline)) { status = errAEEventNotPermitted; goto done; }
    TRACE("postReplyIdentity.after");
    audit_token_t token = {0}; DescType actual = typeNull; Size actual_size = 0;
    *phase = 10;
    TRACE("replyAudit.before");
    OSStatus audit_status = AEGetAttributePtr(&reply, keySenderAuditTokenAttr, typeAuditToken, &actual, &token, sizeof(token), &actual_size);
    if (audit_status != noErr) { status = audit_status; goto done; }
    if (actual != typeAuditToken || actual_size != sizeof(token) || !cs_control_reply_sender_matches(&token, sizeof(token), manager)) { status = errAEEventNotPermitted; goto done; }
    TRACE("replyAudit.after");
    *sender_audit = 1;
    *phase = 11;
    TRACE("replyError.before");
    SInt32 error_number = 0; actual = typeNull; actual_size = 0;
    OSStatus error_status = AEGetParamPtr(&reply, keyErrorNumber, typeSInt32, &actual, &error_number, sizeof(error_number), &actual_size);
    if (error_status == noErr && (actual != typeSInt32 || actual_size != sizeof(error_number) || error_number != 0)) { status = error_number ? error_number : errAEEventFailed; goto done; }
    if (error_status != noErr && error_status != errAEDescNotFound) { status = error_status; goto done; }
    TRACE("replyError.after");
    *phase = 12;
    TRACE("replyObject.before");
    status = AEGetParamDesc(&reply, keyDirectObject, typeUTF8Text, &direct);
    if (status != noErr) goto done;
    Size n = AEGetDescDataSize(&direct);
    if (n <= 0 || (unsigned long)n > capacity) { status = errAEBufferTooSmall; goto done; }
    status = AEGetDescData(&direct, reply_bytes, n);
    if (status == noErr && !control_before(deadline)) status = errAETimeout;
    TRACE("replyObject.after");
    if (status == noErr) { *reply_len = (unsigned long)n; *phase = 13; }
done:
    TRACE("dispose.before");
    AEDisposeDesc(&direct); AEDisposeDesc(&reply); AEDisposeDesc(&event); AEDisposeDesc(&address);
    TRACE("return");
    os_release(trace);
#undef TRACE
    return status;
}
