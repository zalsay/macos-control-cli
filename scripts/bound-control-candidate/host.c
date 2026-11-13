#include "host.h"
#include <Carbon/Carbon.h>
#include <string.h>
#if defined(SAFARIER_INTERNAL_TEST_APP) && defined(SAFARIER_BOUND_LOCAL_CANDIDATE)
#define SAFARIER_TARGET_BID "sh.safarier.testing"
#else
#define SAFARIER_TARGET_BID "sh.safarier.boundcandidate"
#endif
/* Identical preflight to the old Sender.c, except the candidate BID. No sender. */
static OSStatus target_bid(AEAddressDesc *address) {
    static const char bid[] = SAFARIER_TARGET_BID;
    return AECreateDesc(typeApplicationBundleID, bid, sizeof(bid) - 1, address);
}
int32_t g1_permission_bid(void) {
    AEAddressDesc address = {typeNull, NULL};
    OSStatus status = target_bid(&address);
    if (status == noErr) status = AEDeterminePermissionToAutomateTarget(&address, 'SFAu', 'requ', false);
    AEDisposeDesc(&address);
    return status;
}
int32_t g1_request_permission_bid(void) {
    AEAddressDesc address = {typeNull, NULL};
    OSStatus status = target_bid(&address);
    if (status == noErr) status = AEDeterminePermissionToAutomateTarget(&address, 'SFAu', 'requ', true);
    AEDisposeDesc(&address);
    return status;
}
int host_capture(pid_t pid, BIProcess *out) {
    BIDiagnostic diagnostic = {0};
    return bi_process_metadata_diagnostic(pid, bi_deadline_after_ms(1000), out, &diagnostic) == BI_OK;
}
int host_equal(const BIProcess *a, const BIProcess *b) {
    return a->pid == b->pid && a->ppid == b->ppid && a->ruid == b->ruid && a->euid == b->euid &&
        a->birth_sec == b->birth_sec && a->birth_usec == b->birth_usec && !strcmp(a->path, b->path);
}
int host_expected(const BIProcess *p, pid_t parent, uid_t uid, const char *path) {
    return p->ppid == parent && p->ruid == uid && p->euid == uid && !strcmp(p->path, path);
}
#include <Carbon/Carbon.h>
#include <time.h>
#include <limits.h>

/* No identity authorization is supplied by this callback: it is an additional
 * target/mode guard around the same-host OSA component's actual sends. */
typedef struct {
    BIProcess expected; uint64_t deadline; unsigned sends;
    uint32_t rejected_class, rejected_id; int32_t rejected_status;
} SendContext;
static uint64_t monotonic_ns(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t)) return 0;
    return (uint64_t)t.tv_sec * 1000000000ULL + (uint64_t)t.tv_nsec;
}
static OSErr deadline_active(SRefCon refcon) {
    SendContext *ctx = (SendContext *)(intptr_t)refcon;
    uint64_t now = monotonic_ns();
    return ctx && now && now < ctx->deadline ? noErr : errAETimeout;
}
static int address_matches(const AppleEvent *event, pid_t expected) {
    AEDesc addr = {typeNull, NULL};
    int matches = 0;
    if (AEGetAttributeDesc(event, keyAddressAttr, typeWildCard, &addr) != noErr) return 0;
    Size n = AEGetDescDataSize(&addr);
    if (addr.descriptorType == typeApplicationBundleID) {
        static const char bid[] = SAFARIER_TARGET_BID;
        char value[sizeof bid] = {0};
        matches = n == (Size)(sizeof bid - 1) && AEGetDescData(&addr, value, n) == noErr && !memcmp(value, bid, (size_t)n);
    } else if (addr.descriptorType == typeKernelProcessID) {
        pid_t pid = 0;
        matches = n == sizeof pid && AEGetDescData(&addr, &pid, sizeof pid) == noErr && pid == expected;
    } else if (addr.descriptorType == typeProcessSerialNumber) {
        ProcessSerialNumber psn = {0, 0}; pid_t pid = 0;
        matches = n == sizeof psn && AEGetDescData(&addr, &psn, sizeof psn) == noErr && GetProcessPID(&psn, &pid) == noErr && pid == expected;
    }
    AEDisposeDesc(&addr);
    return matches;
}
static int event_code(const AppleEvent *event, AEKeyword key, OSType *code) {
    DescType actual = typeNull; Size size = 0;
    return AEGetAttributePtr(event, key, typeType, &actual, code, sizeof(*code), &size) == noErr &&
        actual == typeType && size == sizeof(*code);
}
static OSErr safe_send(const AppleEvent *event, AppleEvent *reply, AESendMode mode,
                       AESendPriority priority, SInt32 ticks, AEIdleUPP idle,
                       AEFilterUPP filter, SRefCon refcon) {
    (void)priority; (void)idle; (void)filter;
    SendContext *ctx = (SendContext *)(intptr_t)refcon;
    uint64_t now = monotonic_ns();
    if (!ctx || !now || now >= ctx->deadline) return errAETimeout;
    BIProcess fresh = {0};
    if (!host_capture(ctx->expected.pid, &fresh) || !host_equal(&ctx->expected, &fresh)) return errAEEventNotPermitted;
    if (!address_matches(event, ctx->expected.pid)) return errAEEventNotPermitted;
    OSType event_class = 0, event_id = 0;
    int got_class = event_code(event, keyEventClassAttr, &event_class);
    int got_id = event_code(event, keyEventIDAttr, &event_id);
    if (!got_class || !got_id ||
        !((event_class == 'SFAu' && event_id == 'requ') || (event_class == 'ascr' && event_id == 'gsdf'))) {
        ctx->rejected_class = got_class ? event_class : 0;
        ctx->rejected_id = got_id ? event_id : 0;
        ctx->rejected_status = errAEEventNotPermitted;
        return errAEEventNotPermitted;
    }
    now = monotonic_ns();
    if (!now || now >= ctx->deadline) return errAETimeout;
    // Floor to ticks: never extend an existing deadline. Sub-tick remainder fails.
    uint64_t remaining = (ctx->deadline - now) * 60ULL / 1000000000ULL;
    if (!remaining) return errAETimeout;
    if (remaining > INT32_MAX) remaining = INT32_MAX;
    SInt32 limited = (SInt32)remaining;
    if (ticks > 0 && ticks < limited) limited = ticks;
    mode &= ~(kAEAlwaysInteract | kAECanSwitchLayer);
    mode |= kAENeverInteract | kAEDontRecord | kAEDoNotPromptForUserConsent;
    ctx->sends++;
    return (OSErr)AESendMessage(event, reply, mode, limited);
}
int32_t host_osa_script(const uint8_t *source, size_t source_len, const BIProcess *expected, uint32_t timeout_seconds,
                        uint8_t *output, size_t capacity, size_t *written, int32_t *script_error,
                        uint32_t *rejected_class, uint32_t *rejected_id, int32_t *rejected_status) {
    if (!source || !expected || !output || !written || !script_error || !rejected_class || !rejected_id || !rejected_status || source_len > INT_MAX || capacity > INT_MAX) return paramErr;
    *written = 0; *script_error = 0;
    *rejected_class = 0; *rejected_id = 0; *rejected_status = 0;
#if defined(SAFARIER_INTERNAL_TEST_APP) && defined(SAFARIER_BOUND_LOCAL_CANDIDATE)
    if (timeout_seconds != 10 && timeout_seconds != 35) return paramErr;
#else
    if (timeout_seconds != 10) return paramErr;
#endif
    uint64_t now = monotonic_ns();
    uint64_t duration = (uint64_t)timeout_seconds * 1000000000ULL;
    if (!now || now > UINT64_MAX - duration) return errAETimeout;
    SendContext ctx = { .expected = *expected, .deadline = now + duration, .sends = 0 };
    AEDesc src = {typeNull, NULL}, result = {typeNull, NULL}, error = {typeNull, NULL};
    ComponentInstance osa = NULL;
    OSAID script_id = kOSANullScript, value_id = kOSANullScript;
    OSASendUPP hook = NULL, installed = NULL;
    OSAActiveUPP active = NULL, installed_active = NULL;
    SRefCon active_ref = 0;
    SRefCon installed_ref = 0;
    OSStatus status = AECreateDesc(typeUTF8Text, source, (Size)source_len, &src);
    if (status != noErr) goto done;
    osa = OpenDefaultComponent(kOSAComponentType, typeAppleScript);
    if (!osa) { status = badComponentInstance; goto done; }
    hook = NewOSASendUPP(safe_send);
    if (!hook) { status = memFullErr; goto done; }
    status = OSASetSendProc(osa, hook, (SRefCon)(intptr_t)&ctx);
    if (status != noErr) goto done;
    status = OSAGetSendProc(osa, &installed, &installed_ref);
    if (status != noErr || installed != hook || installed_ref != (SRefCon)(intptr_t)&ctx) { status = errAEEventNotPermitted; goto done; }
    active = NewOSAActiveUPP(deadline_active);
    if (!active) { status = memFullErr; goto done; }
    status = OSASetActiveProc(osa, active, (SRefCon)(intptr_t)&ctx);
    if (status != noErr) goto done;
    status = OSAGetActiveProc(osa, &installed_active, &active_ref);
    if (status != noErr || installed_active != active || active_ref != (SRefCon)(intptr_t)&ctx) { status = errAEEventNotPermitted; goto done; }
    status = OSACompile(osa, &src, kOSAModeNull, &script_id);
    if (status != noErr) goto osa_error;
    now = monotonic_ns();
    if (!now || now >= ctx.deadline) { status = errAETimeout; goto done; }
    status = OSAExecute(osa, script_id, kOSANullScript, kOSAModeNeverInteract, &value_id);
    if (status != noErr) goto osa_error;
    now = monotonic_ns();
    if (!now || now >= ctx.deadline) { status = errAETimeout; goto done; }
    status = OSACoerceToDesc(osa, value_id, typeUTF8Text, kOSAModeNull, &result);
    if (status != noErr) goto osa_error;
    if (ctx.rejected_status) { status = ctx.rejected_status; goto done; }
    now = monotonic_ns();
    if (!now || now >= ctx.deadline) { status = errAETimeout; goto done; }
    if (!ctx.sends || result.descriptorType != typeUTF8Text) { status = errAEWrongDataType; goto done; }
    Size n = AEGetDescDataSize(&result);
    if (n < 0 || (size_t)n > capacity) { status = errAEBufferTooSmall; goto done; }
    status = AEGetDescData(&result, output, n);
    if (status == noErr) *written = (size_t)n;
    goto done;
osa_error:
    if (OSAScriptError(osa, kOSAErrorNumber, typeSInt32, &error) == noErr && AEGetDescDataSize(&error) == sizeof(SInt32))
        (void)AEGetDescData(&error, script_error, sizeof(SInt32));
done:
    *rejected_class = ctx.rejected_class; *rejected_id = ctx.rejected_id; *rejected_status = ctx.rejected_status;
    AEDisposeDesc(&error); AEDisposeDesc(&result); AEDisposeDesc(&src);
    if (osa && value_id != kOSANullScript) OSADispose(osa, value_id);
    if (osa && script_id != kOSANullScript && script_id != value_id) OSADispose(osa, script_id);
    if (osa) CloseComponent(osa);
    if (hook) DisposeOSASendUPP(hook);
    if (active) DisposeOSAActiveUPP(active);
    return status;
}
#include <sys/stat.h>
#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>

static int private_directory(int fd) {
    struct stat s;
    return fstat(fd, &s) == 0 && S_ISDIR(s.st_mode) && s.st_uid == geteuid() && (s.st_mode & 07777) == 0700;
}
static int uuid_name(const char *s, size_t n) {
    if (n != 36) return 0;
    for (size_t i = 0; i < n; i++) {
        if (i == 8 || i == 13 || i == 18 || i == 23) { if (s[i] != '-') return 0; }
        else if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f'))) return 0;
    }
    return 1;
}
static int same_snapshot(const struct stat *a, const struct stat *b) {
    return a->st_dev == b->st_dev && a->st_ino == b->st_ino && a->st_uid == b->st_uid &&
        a->st_mode == b->st_mode && a->st_nlink == b->st_nlink && a->st_size == b->st_size &&
        a->st_mtimespec.tv_sec == b->st_mtimespec.tv_sec && a->st_mtimespec.tv_nsec == b->st_mtimespec.tv_nsec &&
        a->st_ctimespec.tv_sec == b->st_ctimespec.tv_sec && a->st_ctimespec.tv_nsec == b->st_ctimespec.tv_nsec;
}
static int host_copy_png(const char *workspace, const char *returned_path, const char *results, const char *destination) {
    static const char middle[] = "/automation-artifacts/";
    static const unsigned char signature[] = {137,80,78,71,13,10,26,10};
    int root=-1, base=-1, dir=-1, src=-1, outdir=-1, out=-1, ok=0;
    unsigned char *data=NULL;
    if (!workspace || !returned_path || !results) return 0;
    size_t w = strlen(workspace), m = sizeof middle - 1;
    if (strncmp(returned_path, workspace, w) || strncmp(returned_path+w, middle, m)) return 0;
    const char *relative = returned_path+w+m;
    if (strlen(relative) != 36 + 1 + 36 + 4 || relative[36] != '/' ||
        !uuid_name(relative, 36) || !uuid_name(relative+37, 36) || strcmp(relative+73, ".png")) return 0;
    char dirname[37], filename[41];
    memcpy(dirname, relative, 36); dirname[36] = 0;
    memcpy(filename, relative+37, 40); filename[40] = 0;
    root = open(workspace, O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (root < 0 || !private_directory(root)) goto done_copy;
    base = openat(root, "automation-artifacts", O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (base < 0 || !private_directory(base)) goto done_copy;
    dir = openat(base, dirname, O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (dir < 0 || !private_directory(dir)) goto done_copy;
    src = openat(dir, filename, O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
    struct stat before, after, named;
    if (src < 0 || fstat(src,&before) || !S_ISREG(before.st_mode) || before.st_uid != geteuid() ||
        (before.st_mode & 07777) != 0600 || before.st_nlink != 1 || before.st_size < 33 || before.st_size > 33554432) goto done_copy;
    size_t size=(size_t)before.st_size, read_bytes=0;
    data=malloc(size); if (!data) goto done_copy;
    while (read_bytes < size) {
        ssize_t n=read(src,data+read_bytes,size-read_bytes);
        if (n<0 && errno==EINTR) continue;
        if (n<=0) goto done_copy;
        read_bytes+=(size_t)n;
    }
    if (memcmp(data,signature,sizeof signature) || fstat(src,&after) || fstatat(dir,filename,&named,AT_SYMLINK_NOFOLLOW) ||
        !same_snapshot(&before,&after) || !same_snapshot(&before,&named)) goto done_copy;
    outdir=open(results,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (outdir<0 || !private_directory(outdir)) goto done_copy;
    out=openat(outdir,destination,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if (out<0) goto done_copy;
    size_t written=0;
    while (written<size) {
        ssize_t n=write(out,data+written,size-written);
        if (n<0 && errno==EINTR) continue;
        if (n<=0) goto done_copy;
        written+=(size_t)n;
    }
    struct stat output;
    if (fstat(out,&output) || !S_ISREG(output.st_mode) || output.st_uid!=geteuid() || output.st_nlink!=1 ||
        (output.st_mode & 07777)!=0600 || output.st_size!=(off_t)size) goto done_copy;
    ok=1;
done_copy:
    free(data);
    if(out>=0) close(out); if(outdir>=0) close(outdir); if(src>=0) close(src);
    if(dir>=0) close(dir); if(base>=0) close(base); if(root>=0) close(root);
    return ok;
}

int host_copy_hover_png(const char *workspace, const char *returned_path, const char *results) {
    return host_copy_png(workspace, returned_path, results, "hover.png");
}
int host_copy_form_png(const char *workspace, const char *returned_path, const char *results) {
    return host_copy_png(workspace, returned_path, results, "form.png");
}
