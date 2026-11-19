/* Real kernel socket and Security.framework boundary, no app or web processes. */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include "BinderIdentity.h"

static void prove(int fd, pid_t pid, const char *image, const char *path, int accepted) {
    BIImagePin pin;
    BIProcess expected;
    BIEvidence observed;
    BIDiagnostic diag;
    uint64_t deadline = bi_deadline_after_ms(4000);
    assert(bi_static_pin_diagnostic(image, deadline, &pin, &diag) == BI_OK);
    assert(bi_process_metadata(pid, deadline, &expected) == BI_OK);
    /* The unnamed channel API must not silently start accepting named peers. */
    assert(bi_capture_peer_diagnostic(fd, &expected, &pin, deadline, &observed, &diag) == BI_INVALID);
    assert(diag.stage == (accepted ? BI_STAGE_PEER_LOCAL_NAME : BI_STAGE_PEER_REMOTE_NAME));
    assert(bi_capture_registration_peer(fd, &expected, &pin, deadline, &observed, &diag, "/wrong", accepted) == BI_INVALID);
    assert(bi_capture_registration_peer(fd, &expected, &pin, deadline, &observed, &diag, path, !accepted) == BI_INVALID);
    BIProcess wrong = expected;
    ++wrong.birth_usec;
    assert(bi_capture_registration_peer(fd, &wrong, &pin, deadline, &observed, &diag, path, accepted) == BI_INVALID);
    BIError result = bi_capture_registration_peer(fd, &expected, &pin, deadline, &observed, &diag, path, accepted);
    if (result != BI_OK) fprintf(stderr, "Named proof: role=%d result=%d stage=%d\n", accepted, result, diag.stage);
    assert(result == BI_OK && bi_match(&pin, &expected, &observed));
}

int main(int argc, char **argv) {
    assert(argc >= 3);
    struct sockaddr_un address = { .sun_family = AF_UNIX, .sun_len = sizeof(address) };
    assert(strlen(argv[2]) < sizeof(address.sun_path));
    strcpy(address.sun_path, argv[2]);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    assert(fd >= 0);
    if (!strcmp(argv[1], "serve")) {
        assert(bind(fd, (struct sockaddr *)&address, sizeof(address)) == 0 && listen(fd, 2) == 0);
        puts("ready"); fflush(stdout);
        pid_t previous = 0;
        for (int i = 0; i < 2; i++) {
            int conn = accept(fd, NULL, NULL);
            assert(conn >= 0);
            pid_t peer = 0;
            socklen_t n = sizeof(peer);
            assert(getsockopt(conn, SOL_LOCAL, LOCAL_PEERPID, &peer, &n) == 0 && peer > 1 && peer != previous);
            char marker;
            assert(read(conn, &marker, 1) == 1 && marker == 'c');
            prove(conn, peer, argv[0], argv[2], 1);
            assert(write(conn, "s", 1) == 1 && read(conn, &marker, 1) == 1 && marker == 'a');
            previous = peer;
            close(conn);
        }
        close(fd);
        unlink(argv[2]);
        puts("same listener authenticated both process generations");
        return 0;
    }
    assert(argc == 4 && connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0);
    assert(write(fd, "c", 1) == 1);
    char marker;
    assert(read(fd, &marker, 1) == 1 && marker == 's');
    prove(fd, (pid_t)atoi(argv[3]), argv[0], argv[2], 0);
    assert(write(fd, "a", 1) == 1);
    close(fd);
    return 0;
}
