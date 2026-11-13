#ifndef BOUND_WHEEL_OBSERVER_STATE_H
#define BOUND_WHEEL_OBSERVER_STATE_H
#include <stdint.h>
#include <string.h>
typedef enum { WO_IDLE, WO_WAIT_ARMED, WO_ARMED, WO_WAIT_CANCELLED, WO_DONE, WO_FAILED } WOPhase;
typedef enum { WO_MSG_ARMED, WO_MSG_OBSERVED, WO_MSG_CANCELLED } WOMessage;
typedef enum { WO_REJECT=-1, WO_LATE=0, WO_ACCEPT=1, WO_OBSERVATION=2 } WOResult;
typedef struct { WOPhase phase; char nonce[33]; uint64_t epoch, deadline; int sawObservation; } WOState;
/* Correlation and ordering only; this state grants no page or process identity. */
static inline int wo_begin(WOState *s,const char *nonce,uint64_t epoch,uint64_t deadline,uint64_t now) {
    if (!s || s->phase != WO_IDLE || !nonce || strlen(nonce) != 32 || !epoch || now >= deadline) return 0;
    int nonzero=0;
    for (unsigned i=0;i<32;i++) { char c=nonce[i]; if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return 0; if (c != '0') nonzero=1; }
    if (!nonzero) return 0;
    memcpy(s->nonce,nonce,33); s->epoch=epoch; s->deadline=deadline; s->sawObservation=0; s->phase=WO_WAIT_ARMED; return 1;
}
static inline WOResult wo_receive(WOState *s,WOMessage m,const char *nonce,uint64_t epoch,uint64_t now) {
    if (!s) return WO_REJECT;
    if (s->phase == WO_DONE || s->phase == WO_FAILED) return WO_LATE;
    if (now >= s->deadline || !nonce || strlen(nonce) != 32 || strcmp(s->nonce,nonce) || epoch != s->epoch) { s->phase=WO_FAILED; return WO_REJECT; }
    if (s->phase == WO_WAIT_ARMED && m == WO_MSG_ARMED) { s->phase=WO_ARMED; return WO_ACCEPT; }
    if (s->phase == WO_ARMED && m == WO_MSG_OBSERVED && !s->sawObservation) { s->sawObservation=1; return WO_OBSERVATION; }
    if (s->phase == WO_WAIT_CANCELLED && m == WO_MSG_CANCELLED) { s->phase=WO_DONE; return WO_ACCEPT; }
    s->phase=WO_FAILED; return WO_REJECT;
}
static inline int wo_cancel(WOState *s,uint64_t now) {
    if (!s || s->phase != WO_ARMED || now >= s->deadline) { if (s && s->phase != WO_DONE) s->phase=WO_FAILED; return 0; }
    s->phase=WO_WAIT_CANCELLED; return 1;
}
/* Exactly 32 lowercase hex nonce, colon, 16 lowercase hex epoch. */
static inline int wo_parse_payload(const char *payload,char nonce[33],uint64_t *epoch) {
    if (!payload || !nonce || !epoch || strlen(payload) != 49 || payload[32] != ':') return 0;
    int nonzero=0; uint64_t number=0;
    for (unsigned i=0;i<32;i++) { char c=payload[i]; if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return 0; if (c != '0') nonzero=1; }
    if (!nonzero) return 0;
    for (unsigned i=33;i<49;i++) { char c=payload[i]; unsigned digit; if (c >= '0' && c <= '9') digit=(unsigned)(c-'0'); else if (c >= 'a' && c <= 'f') digit=(unsigned)(c-'a'+10); else return 0; number=(number<<4)|digit; }
    if (!number) return 0;
    memcpy(nonce,payload,32); nonce[32]='\0'; *epoch=number; return 1;
}
static inline int wo_ascii_exact(const char *buffer,size_t capacity,size_t utf16Length,size_t utf8Bytes) {
    if (!buffer || utf16Length >= capacity || utf8Bytes != utf16Length+1 || buffer[utf16Length] != '\0') return 0;
    for (size_t i=0;i<utf16Length;i++) { unsigned char c=(unsigned char)buffer[i]; if (!c || c>0x7f) return 0; }
    return strlen(buffer)==utf16Length;
}
#endif
