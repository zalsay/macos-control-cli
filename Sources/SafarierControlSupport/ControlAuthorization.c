#include "SafarierControlSupport.h"
#include <Carbon/Carbon.h>
#include <string.h>

static int permission_manager_matches(const CSControlManager *expected, const char *path) {
    CSControlManager current = {0};
    /* Each capture uses its own original bounded identity deadline. No deadline
     * is carried across the potentially unbounded human consent dialog. */
    return cs_control_capture_manager(expected->pid, path, &current) &&
        cs_control_manager_equal(expected, &current);
}

int32_t cs_control_authorization(const char *bundle_id, int request_consent,
                                 const CSControlManager *manager, const char *expected_executable,
                                 int *target_changed) {
    if (!target_changed) return paramErr;
    *target_changed = 0;
    if (!bundle_id || !manager || !expected_executable ||
        (request_consent != 0 && request_consent != 1) ||
        !strnlen(bundle_id, 256) || strnlen(bundle_id, 256) >= 256) return paramErr;
    if (!permission_manager_matches(manager, expected_executable)) {
        *target_changed = 1;
        return errAEEventNotPermitted;
    }
    AEAddressDesc address = {typeNull, NULL};
    OSStatus status = AECreateDesc(typeApplicationBundleID, bundle_id, (Size)strlen(bundle_id), &address);
    if (status == noErr) {
        // Permission API only: exact existing event scope, never a wildcard or business send.
        status = AEDeterminePermissionToAutomateTarget(&address, 'SFAu', 'requ', request_consent == 1);
    }
    AEDisposeDesc(&address);
    if (!permission_manager_matches(manager, expected_executable)) *target_changed = 1;
    return status;
}
