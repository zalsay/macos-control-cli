#include "BinderIdentity.h"
#include <assert.h>
#include <stdio.h>
#include <sys/socket.h>
#include <unistd.h>

/* Real sockets and real original collector; invalid cases never claim identity. */
static BIProcess expected;
static BIImagePin pin;
static void check(int fd, BIStage stage) {
    BIEvidence out = {0}; BIDiagnostic diag = {0};
    BIError rc = bi_capture_peer_diagnostic(fd, &expected, &pin, bi_deadline_after_ms(1000), &out, &diag);
    printf("observed rc=%d stage=%d expected=%d\n", rc, diag.stage, stage); fflush(stdout);
    assert(rc == BI_INVALID && diag.stage == stage && diag.depth == BI_DEPTH_NA);
    assert(bi_capture_peer(fd, &expected, &pin, bi_deadline_after_ms(1000), &out) == BI_INVALID);
    printf("PASS invalid stage=%d fields=%llu\n", diag.stage, (unsigned long long)diag.fields);
}
int main(void) {
    expected.pid = getpid(); expected.euid = geteuid(); expected.ruid = getuid();
    check(-1, BI_STAGE_PEER_FD);
    int pipefd[2]; assert(pipe(pipefd) == 0); check(pipefd[0], BI_STAGE_PEER_SOCKET_TYPE); close(pipefd[0]); close(pipefd[1]);
    int pair[2]; assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
    assert(shutdown(pair[1], SHUT_RDWR) == 0);
    close(pair[1]);
    // Darwin rejects getpeername on this disconnected socket before reaching poll.
    check(pair[0], BI_STAGE_PEER_REMOTE_ADDRESS); close(pair[0]);
    BIEvidence out = {0}; BIDiagnostic diag = {0};
    assert(bi_capture_peer_diagnostic(-1, &expected, &pin, 0, &out, &diag) == BI_INVALID);
    int live[2]; assert(socketpair(AF_UNIX, SOCK_STREAM, 0, live) == 0);
    assert(bi_capture_peer_diagnostic(live[0], &expected, &pin, 0, &out, &diag) == BI_EXPIRED);
    assert(diag.stage == BI_STAGE_NONE); close(live[0]);close(live[1]);
    puts("PASS expired return and empty diagnostic preserved");
}
