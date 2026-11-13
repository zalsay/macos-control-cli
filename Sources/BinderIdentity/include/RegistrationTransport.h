#ifndef SAFARIER_REGISTRATION_TRANSPORT_H
#define SAFARIER_REGISTRATION_TRANSPORT_H
#include <stdint.h>

/* A single descriptor on a dedicated, already authenticated anonymous stream.
 * The deadline is an absolute CLOCK_MONOTONIC deadline, at most 5s ahead.
 * An error is terminal for the stream: callers must not retry the operation.
 * These functions do not authenticate either endpoint or grant authority. */
int sfr_registration_send_fd(int stream, int descriptor, uint64_t deadline);
int sfr_registration_receive_fd(int stream, int *descriptor, uint64_t deadline);
#endif
