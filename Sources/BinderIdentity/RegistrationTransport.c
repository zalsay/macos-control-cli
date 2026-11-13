#include "RegistrationTransport.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static uint64_t registration_now(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t) != 0) return 0;
    return (uint64_t)t.tv_sec * 1000000000ULL + (uint64_t)t.tv_nsec;
}
static int registration_ready(int fd, short events, uint64_t deadline) {
    for (;;) {
        uint64_t now = registration_now();
        if (!now || deadline <= now || deadline - now > 5000000000ULL) return -1;
        int ms = (int)((deadline - now + 999999ULL) / 1000000ULL);
        struct pollfd item = { .fd = fd, .events = events };
        int result = poll(&item, 1, ms);
        if (result < 0 && errno == EINTR) continue;
        if (result != 1 || (item.revents & (POLLERR | POLLHUP | POLLNVAL)) || !(item.revents & events)) return -1;
        now = registration_now();
        return now && now < deadline ? 0 : -1;
    }
}
int sfr_registration_send_fd(int stream, int descriptor, uint64_t deadline) {
    if (stream < 0 || descriptor < 0 || registration_ready(stream, POLLOUT, deadline)) return -1;
    int no_sigpipe = 1;
    if (setsockopt(stream, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof no_sigpipe) != 0) return -1;
    char byte = 'G';
    union { struct cmsghdr alignment; unsigned char bytes[CMSG_SPACE(sizeof(int))]; } control = {0};
    struct iovec iov = { .iov_base = &byte, .iov_len = 1 };
    struct msghdr msg = { .msg_iov = &iov, .msg_iovlen = 1, .msg_control = control.bytes, .msg_controllen = sizeof(control.bytes) };
    struct cmsghdr *header = CMSG_FIRSTHDR(&msg);
    if (!header) return -1;
    header->cmsg_level = SOL_SOCKET; header->cmsg_type = SCM_RIGHTS; header->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(header), &descriptor, sizeof descriptor);
    if (sendmsg(stream, &msg, MSG_DONTWAIT) != 1) return -1;
    uint64_t now = registration_now();
    return now && now < deadline ? 0 : -1;
}
int sfr_registration_receive_fd(int stream, int *descriptor, uint64_t deadline) {
    if (stream < 0 || !descriptor || registration_ready(stream, POLLIN, deadline)) return -1;
    *descriptor = -1;
    char byte = 0;
    /* Space for multiple descriptors permits closing them even on rejection. */
    union { struct cmsghdr alignment; unsigned char bytes[CMSG_SPACE(sizeof(int) * 16)]; } control = {0};
    struct iovec iov = { .iov_base = &byte, .iov_len = 1 };
    struct msghdr msg = { .msg_iov = &iov, .msg_iovlen = 1, .msg_control = control.bytes, .msg_controllen = sizeof(control.bytes) };
    ssize_t count = recvmsg(stream, &msg, MSG_DONTWAIT);
    int selected = -1, seen = 0, valid = count == 1 && byte == 'G' && !(msg.msg_flags & (MSG_CTRUNC | MSG_TRUNC));
    if (count >= 0) for (struct cmsghdr *h = CMSG_FIRSTHDR(&msg); h; h = CMSG_NXTHDR(&msg, h)) {
        if (h->cmsg_level != SOL_SOCKET || h->cmsg_type != SCM_RIGHTS || h->cmsg_len < CMSG_LEN(0)) { valid = 0; continue; }
        size_t bytes = h->cmsg_len - CMSG_LEN(0);
        if (bytes % sizeof(int)) valid = 0;
        for (size_t i = 0; i < bytes / sizeof(int); i++) {
            int fd; memcpy(&fd, (unsigned char *)CMSG_DATA(h) + i * sizeof(int), sizeof fd);
            if (++seen == 1) selected = fd; else close(fd);
        }
    }
    uint64_t now = registration_now();
    if (!valid || seen != 1 || selected < 0 || !now || now >= deadline || fcntl(selected, F_SETFD, FD_CLOEXEC) != 0) {
        if (selected >= 0) close(selected);
        return -1;
    }
    *descriptor = selected;
    return 0;
}
