#include "SafarierControlSupport.h"
#include <libproc.h>
#include <mach/mach.h>
#include <bsm/libbsm.h>
#include <signal.h>
#include <unistd.h>

/* Full-exit UI only. Signals target a kernel audit token, never a recycled PID. */
static int exit_token(pid_t pid, audit_token_t *token) {
    mach_port_name_t task = MACH_PORT_NULL;
    if (pid <= 1 || pid == getpid() || task_name_for_pid(mach_task_self(), pid, &task) != KERN_SUCCESS) return 0;
    mach_msg_type_number_t count = TASK_AUDIT_TOKEN_COUNT;
    kern_return_t rc = task_info(task, TASK_AUDIT_TOKEN, (task_info_t)token, &count);
    mach_port_deallocate(mach_task_self(), task);
    return rc == KERN_SUCCESS && count == TASK_AUDIT_TOKEN_COUNT && audit_token_to_pid(*token) == pid &&
        audit_token_to_ruid(*token) == getuid() && audit_token_to_euid(*token) == geteuid();
}
uint32_t cs_exit_pidversion(int32_t pid) {
    audit_token_t token; return exit_token(pid,&token) ? audit_token_to_pidversion(token) : 0;
}
int cs_exit_signal(int32_t pid, uint32_t version, int sig) {
    audit_token_t token;
    return version && (sig == SIGTERM || sig == SIGKILL) && exit_token(pid,&token) &&
        (uint32_t)audit_token_to_pidversion(token) == version && proc_signal_with_audittoken(&token,sig) == 0;
}
