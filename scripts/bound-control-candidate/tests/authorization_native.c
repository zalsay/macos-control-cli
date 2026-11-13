/* Link the real ControlAuthorization.c against these test-only dependencies.
 * No AppKit process, TCC call, AppleEvent send or running Manager is involved. */
#include "SafarierControlSupport.h"
#include <Carbon/Carbon.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
static int captures, fail_capture, mismatch_capture, calls, creates, disposes, sends, ask;
static OSStatus permission_result, create_result;
static const char bid[] = "sh.safarier.testing";
static const char path[] = "/synthetic/Safarier AI.app/Contents/MacOS/Safarier AI";
static CSControlManager expected = {.pid=123, .uid=501, .birth_sec=100, .birth_usec=9, .code_hash_len=1, .code_hash={42}};
int cs_control_capture_manager(int32_t pid, const char *exe, CSControlManager *out) {
    assert(pid==expected.pid && !strcmp(exe,path)); captures++;
    if (captures==fail_capture) return 0;
    *out=expected;
    if (captures==mismatch_capture) out->birth_usec++;
    return 1;
}
int cs_control_manager_equal(const CSControlManager *a, const CSControlManager *b) {
    return !memcmp(a,b,sizeof(*a));
}
OSErr AECreateDesc(DescType type, const void *data, Size size, AEDesc *out) {
    assert(type==typeApplicationBundleID && size==strlen(bid) && !memcmp(data,bid,size)); creates++;
    out->descriptorType=type;out->dataHandle=NULL;return create_result;
}
OSErr AEDisposeDesc(AEDesc *desc) { (void)desc;disposes++;return noErr; }
OSStatus AEDeterminePermissionToAutomateTarget(const AEAddressDesc *target, AEEventClass cls, AEEventID event, Boolean request) {
    assert(target->descriptorType==typeApplicationBundleID && cls=='SFAu' && event=='requ');
    calls++; ask=request; return permission_result;
}
OSStatus AESendMessage(const AppleEvent *event, AppleEvent *reply, AESendMode mode, long timeout) {
    (void)event;(void)reply;(void)mode;(void)timeout;sends++;assert(!"business AE forbidden");return -1;
}
static void reset(void) { captures=fail_capture=mismatch_capture=calls=creates=disposes=sends=ask=0; permission_result=-1744;create_result=0; }
static OSStatus run(int request, int *changed) {
    OSStatus rc=cs_control_authorization(bid,request,&expected,path,changed);assert(sends==0);return rc;
}
int main(void) {
    int changed;
    reset();assert(run(0,&changed)==-1744 && !changed && calls==1 && ask==0 && captures==2 && disposes==1);
    reset();permission_result=0;assert(run(1,&changed)==0 && !changed && calls==1 && ask==1 && captures==2);
    reset();permission_result=-1743;assert(run(1,&changed)==-1743 && !changed && calls==1);
    reset();fail_capture=1;assert(run(1,&changed)==-1743 && changed && !calls && !creates);
    reset();fail_capture=2;permission_result=0;assert(run(1,&changed)==0 && changed && calls==1);
    reset();mismatch_capture=2;permission_result=0;assert(run(1,&changed)==0 && changed && calls==1);
    reset();create_result=-50;assert(run(1,&changed)==-50 && !changed && !calls && captures==2 && disposes==1);
    reset();assert(run(2,&changed)==-50 && !calls && !captures);
    puts("PASS: fixed scope/address; ask false/true; single call; pre/post capture failure and changed birth; no AESend; invalid flag rejected (8 cases)");
}
