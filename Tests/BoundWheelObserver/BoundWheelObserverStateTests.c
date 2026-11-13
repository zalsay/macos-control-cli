#include <stdio.h>
#include <string.h>
#include "../../scripts/bound-control-candidate/observer/BoundWheelObserverState.h"
#define REQUIRE(x) do { if (!(x)) { printf("FAIL line=%d\n",__LINE__); return 1; } } while(0)
int main(void) {
 const char *n="0123456789abcdef0123456789abcdef", *other="1123456789abcdef0123456789abcdef"; WOState s={0};
 REQUIRE(wo_begin(&s,n,7,100,1)); REQUIRE(wo_receive(&s,WO_MSG_ARMED,n,7,2)==WO_ACCEPT); REQUIRE(wo_cancel(&s,3)); REQUIRE(wo_receive(&s,WO_MSG_CANCELLED,n,7,4)==WO_ACCEPT); REQUIRE(wo_receive(&s,WO_MSG_OBSERVED,n,7,5)==WO_LATE);
 s=(WOState){0}; REQUIRE(wo_begin(&s,n,7,100,1)); REQUIRE(wo_receive(&s,WO_MSG_ARMED,other,7,2)==WO_REJECT && s.phase==WO_FAILED);
 s=(WOState){0}; REQUIRE(wo_begin(&s,n,7,100,1)); REQUIRE(wo_receive(&s,WO_MSG_ARMED,n,8,2)==WO_REJECT && s.phase==WO_FAILED);
 s=(WOState){0}; REQUIRE(wo_begin(&s,n,7,100,1)); REQUIRE(wo_receive(&s,WO_MSG_ARMED,n,7,2)==WO_ACCEPT); REQUIRE(wo_receive(&s,WO_MSG_ARMED,n,7,3)==WO_REJECT && s.phase==WO_FAILED);
 s=(WOState){0}; REQUIRE(wo_begin(&s,n,7,100,1)); REQUIRE(wo_receive(&s,WO_MSG_ARMED,n,7,100)==WO_REJECT && s.phase==WO_FAILED);
 s=(WOState){0}; REQUIRE(wo_begin(&s,n,7,100,1)); REQUIRE(wo_receive(&s,WO_MSG_ARMED,n,7,2)==WO_ACCEPT); REQUIRE(wo_receive(&s,WO_MSG_OBSERVED,n,7,3)==WO_OBSERVATION); REQUIRE(wo_receive(&s,WO_MSG_OBSERVED,n,7,4)==WO_REJECT && s.phase==WO_FAILED);
 s=(WOState){0}; REQUIRE(!wo_begin(&s,"bad",7,100,1)); REQUIRE(!wo_begin(&s,n,0,100,1)); REQUIRE(!wo_begin(&s,n,7,1,1));
 char parsed[33]; uint64_t epoch=0;
 REQUIRE(wo_parse_payload("0123456789abcdef0123456789abcdef:0000000000000007",parsed,&epoch)); REQUIRE(!strcmp(parsed,n) && epoch==7);
 REQUIRE(!wo_parse_payload("0123456789abcdef0123456789abcdef:0000000000000000",parsed,&epoch));
 REQUIRE(!wo_parse_payload("0123456789abcdef0123456789abcdeF:0000000000000007",parsed,&epoch));
 REQUIRE(!wo_parse_payload("0123456789abcdef0123456789abcdef:0000000000000007x",parsed,&epoch));
 char oversized[50]; memset(oversized,'a',49); oversized[49]=0;
 const char embedded[]={'a',0,'b',0}; const char nonascii[]={(char)0xc3,(char)0xa9,0};
 REQUIRE(wo_ascii_exact("arm",4,3,4));
 REQUIRE(!wo_ascii_exact(oversized,sizeof oversized,50,50));
 REQUIRE(!wo_ascii_exact(embedded,sizeof embedded,3,4));
 REQUIRE(!wo_ascii_exact(nonascii,sizeof nonascii,1,3));
 puts("PASS state nonce epoch duplicate late timeout observation wire ascii");return 0;
}
