#include "SafarierControlSupport.h"
#include <Carbon/Carbon.h>
#include <mach/mach.h>
#include <mach/task_info.h>
#include <uuid/uuid.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static ProcessSerialNumber expected;
static const char *scenario;
static int queries, sends, wrong_target, wrong_scope;
static const char payload[] = "{\"action\":\"launchInteractive\",\"parameters\":{}}";

static int is_manager(const AEDesc *address) {
    ProcessSerialNumber actual = {0};
    return address->descriptorType == typeProcessSerialNumber &&
        AEGetDescDataSize(address) == sizeof(actual) &&
        AEGetDescData(address, &actual, sizeof(actual)) == noErr &&
        actual.highLongOfPSN == expected.highLongOfPSN && actual.lowLongOfPSN == expected.lowLongOfPSN;
}

// Replace only OS permission and transport boundaries. The real descriptor,
// signed-process capture, deadline, sender audit and reply parsing still run.
OSStatus fixture_permission(const AEAddressDesc *address, AEEventClass event_class, AEEventID event_id, Boolean ask) {
    queries++;
    wrong_scope |= event_class != 'SFAu' || event_id != 'requ' || ask != !strcmp(scenario, "authorize-request");
    if (!is_manager(address)) { wrong_target++; return errAETimeout; }
    if (!strcmp(scenario, "deny-query")) return errAEEventNotPermitted;
    if (!strcmp(scenario, "timeout-query")) return errAETimeout;
    return noErr;
}

OSStatus fixture_send(const AppleEvent *event, AppleEvent *reply, AESendMode mode, long ticks) {
    sends++;
    AEDesc address = {typeNull, NULL};
    OSStatus status = AEGetAttributeDesc(event, keyAddressAttr, typeWildCard, &address);
    int correct = status == noErr && is_manager(&address);
    AEDisposeDesc(&address);
    if (!correct) { wrong_target++; return errAETimeout; }
    wrong_scope |= !(mode & kAEDoNotPromptForUserConsent) || !(mode & kAENeverInteract) || ticks <= 0;
    char data[sizeof(payload)] = {0}; DescType type = typeNull; Size size = 0;
    status = AEGetParamPtr(event, keyDirectObject, typeUTF8Text, &type, data, sizeof(data), &size);
    wrong_scope |= status != noErr || type != typeUTF8Text || size != strlen(payload) || memcmp(data, payload, strlen(payload));
    if (!strcmp(scenario, "deny-send")) return errAEEventNotPermitted;
    if (!strcmp(scenario, "timeout-send")) return errAETimeout;
    AEAddressDesc destination = {typeNull, NULL};
    status = AECreateDesc(typeProcessSerialNumber, &expected, sizeof(expected), &destination);
    if (status == noErr) status = AECreateAppleEvent(kCoreEventClass, kAEAnswer, &destination, kAutoGenerateReturnID, kAnyTransactionID, reply);
    AEDisposeDesc(&destination);
    if (status == noErr) status = AEPutParamPtr(reply, keyDirectObject, typeUTF8Text, "{}", 2);
    return status;
}

// The OS supplies this read-only attribute on a delivered reply; synthetic
// replies cannot mint it with AEPutAttributePtr. Still use the real kernel token
// and the production signed-code/audit comparison after this boundary.
OSErr fixture_get_attribute(const AppleEvent *event, AEKeyword keyword, DescType desired,
                              DescType *actual, void *bytes, Size capacity, Size *length) {
    (void)event;
    if (keyword != keySenderAuditTokenAttr || desired != typeAuditToken || capacity < sizeof(audit_token_t)) return paramErr;
    mach_msg_type_number_t count = TASK_AUDIT_TOKEN_COUNT;
    if (task_info(mach_task_self(), TASK_AUDIT_TOKEN, bytes, &count) != KERN_SUCCESS) return errAEEventFailed;
    *actual = typeAuditToken; *length = sizeof(audit_token_t);
    return noErr;
}

int main(int argc, char **argv) {
    if (argc != 2) return 64;
    scenario = argv[1];
    if (GetCurrentProcess(&expected) != noErr) return 65;
    CSControlManager manager = {0};
    if (!cs_control_capture_manager(getpid(), argv[0], &manager)) { fprintf(stderr, "signed fixture capture failed\n"); return 66; }
    int32_t status; int sent = 0, audit = 0, changed = 0; uint32_t phase = 0;
    unsigned long length = 0; uint8_t reply[64] = {0}; uuid_t request_id; uuid_generate(request_id);
    int authorize = !strncmp(scenario, "authorize", 9);
    if (!strcmp(scenario, "changed-manager")) manager.birth_usec++;
    if (!strcmp(scenario, "changed-serial")) manager.psn_low++;
    if (authorize) {
        status = cs_control_authorization("sh.safarier.fixture.shared", !strcmp(scenario, "authorize-request"), &manager, argv[0], &changed);
    } else {
        status = cs_control_send_apple_event("sh.safarier.fixture.shared", (const uint8_t *)payload, strlen(payload), 10,
            &manager, argv[0], reply, sizeof(reply), &length, &sent, &audit, &phase, request_id);
    }
    printf("scenario=%s status=%d queries=%d sends=%d wrongTarget=%d wrongScope=%d sent=%d audit=%d changed=%d phase=%u\n",
        scenario, status, queries, sends, wrong_target, wrong_scope, sent, audit, changed, phase);
    if (wrong_target || wrong_scope || queries > 1 || sends > 1) return 1;
    if (authorize) return status == noErr && !changed && queries == 1 && sends == 0 ? 0 : 1;
    if (!strcmp(scenario, "changed-manager") || !strcmp(scenario, "changed-serial")) return status != noErr && sends == 0 && queries == 0 && !sent ? 0 : 1;
    if (!strcmp(scenario, "deny-query")) return status == errAEEventNotPermitted && queries == 1 && sends == 0 && !sent ? 0 : 1;
    if (!strcmp(scenario, "timeout-query")) return status == errAETimeout && queries == 1 && sends == 0 && !sent ? 0 : 1;
    if (!strcmp(scenario, "deny-send")) return status == errAEEventNotPermitted && sends == 1 && sent && !audit ? 0 : 1;
    if (!strcmp(scenario, "timeout-send")) return status == errAETimeout && sends == 1 && sent && !audit ? 0 : 1;
    return status == noErr && sends == 1 && sent && audit && length == 2 && !memcmp(reply, "{}", 2) ? 0 : 1;
}
