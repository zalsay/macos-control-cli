#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <pthread.h>
#import <stdio.h>
#import <string.h>
#import <time.h>
#import "BoundWheelObserverABI.h"
#import "BoundWheelObserverState.h"

/* One static context per WebProcess: never free a callback target whose
   cancellation/unregistration semantics have not been proven. */
typedef struct { WOBundlePageRef page; int pageSeen; WOState state; char payload[50]; } WOPluginContext;
static WOPluginContext gContext;
static WOStartMonitor gStart; static WORegisterMonitor gRegister; static WOPostBundlePage gPost;
static WOStringCreate gCreate; static WOStringGetUTF8 gUTF8; static WOStringLength gLength; static WOGetTypeID gType;
static WOStringTypeID gStringType; static WORelease gRelease;
static const char *const kOrigin="/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit";

static void *systemSymbol(const char *name) {
    void *symbol=dlsym(RTLD_DEFAULT,name); Dl_info info={0};
    return symbol && dladdr(symbol,&info) && info.dli_fname && strcmp(info.dli_fname,kOrigin)==0 ? symbol : NULL;
}
static uint64_t nowNS(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static void reject(WOPluginContext *context) {
    if (context) context->state.phase=WO_FAILED;
    fputs("WHEEL_OBSERVER_PLUGIN phase=reject\n",stderr);
}
static int readString(WOTypeRef value,char *buffer,size_t capacity) {
    if (!value || gType(value)!=gStringType()) return 0;
    size_t length=gLength((WOStringRef)value);
    if (length>=capacity) return 0;
    size_t n=gUTF8((WOStringRef)value,buffer,capacity);
    return wo_ascii_exact(buffer,capacity,length,n);
}
static int post(WOPluginContext *context,const char *name) {
    if (!context->page) return 0;
    WOStringRef key=gCreate(name), payload=gCreate(context->payload);
    if (!key || !payload) { if (key) gRelease(key); if (payload) gRelease(payload); return 0; }
    gPost(context->page,key,(WOTypeRef)payload); gRelease((WOTypeRef)key); gRelease((WOTypeRef)payload); return 1;
}
static void monitorObserved(void *opaque) {
    WOPluginContext *context=(WOPluginContext *)opaque;
    if (!pthread_main_np() || context!=&gContext) return;
    @try {
        if (!context->page || context->state.phase==WO_DONE || context->state.phase==WO_FAILED) {
            fputs("WHEEL_OBSERVER_PLUGIN phase=late_ignored\n",stderr); return;
        }
        WOResult result=wo_receive(&context->state,WO_MSG_OBSERVED,context->state.nonce,context->state.epoch,nowNS());
        if (result!=WO_OBSERVATION || !post(context,"observed")) { reject(context); return; }
        fputs("WHEEL_OBSERVER_PLUGIN phase=observed_not_ack\n",stderr);
    } @catch (NSException *exception) { (void)exception; reject(context); }
}
static void created(WOBundleRef bundle,WOBundlePageRef page,const void *info) {
    (void)bundle; WOPluginContext *context=(WOPluginContext *)info;
    if (!pthread_main_np() || context!=&gContext || !page) return;
    if (context->pageSeen) { reject(context); return; }
    context->pageSeen=1; context->page=page;
    fputs("WHEEL_OBSERVER_PLUGIN phase=page_created\n",stderr);
}
static void destroyed(WOBundleRef bundle,WOBundlePageRef page,const void *info) {
    (void)bundle; WOPluginContext *context=(WOPluginContext *)info;
    if (!pthread_main_np() || context!=&gContext) return;
    if (context->page==page) { context->page=NULL; context->state.phase=WO_FAILED; }
}
static void received(WOBundleRef bundle,WOBundlePageRef page,WOStringRef name,WOTypeRef body,const void *info) {
    (void)bundle; WOPluginContext *context=(WOPluginContext *)info;
    if (!pthread_main_np() || context!=&gContext || !page || page!=context->page) { reject(context==&gContext?context:NULL); return; }
    @try {
        char command[16]={0},payload[50]={0},nonce[33]={0}; uint64_t epoch=0,now=nowNS();
        if (!readString((WOTypeRef)name,command,sizeof(command)) || !readString(body,payload,sizeof(payload)) || !wo_parse_payload(payload,nonce,&epoch) || !now) { reject(context); return; }
        if (!strcmp(command,"arm")) {
            if (now>UINT64_MAX-UINT64_C(2000000000) || !wo_begin(&context->state,nonce,epoch,now+UINT64_C(2000000000),now)) { reject(context); return; }
            memcpy(context->payload,payload,sizeof(context->payload));
            gStart(page,false); /* Never clear the existing wheel latching state. */
            if (!gRegister(page,monitorObserved,false,false,context) || wo_receive(&context->state,WO_MSG_ARMED,nonce,epoch,nowNS())!=WO_ACCEPT || !post(context,"armed")) { reject(context); return; }
            fputs("WHEEL_OBSERVER_PLUGIN phase=armed registration_returned=true\n",stderr);
        } else if (!strcmp(command,"cancel")) {
            if (strcmp(payload,context->payload) || !wo_cancel(&context->state,now) || wo_receive(&context->state,WO_MSG_CANCELLED,nonce,epoch,nowNS())!=WO_ACCEPT || !post(context,"cancelled")) { reject(context); return; }
            fputs("WHEEL_OBSERVER_PLUGIN phase=cancelled logical_only=true\n",stderr);
        } else { reject(context); }
    } @catch (NSException *exception) { (void)exception; reject(context); }
}

__attribute__((visibility("default"))) void WKBundleInitialize(WOBundleRef bundle,WOTypeRef userData) {
    (void)userData;
    if (!pthread_main_np() || !bundle) return;
    @try {
        WOSetBundleClient setClient=(WOSetBundleClient)systemSymbol("WKBundleSetClient");
        gStart=(WOStartMonitor)systemSymbol("WKBundlePageStartMonitoringScrollOperations");
        gRegister=(WORegisterMonitor)systemSymbol("WKBundlePageRegisterScrollOperationCompletionCallback");
        gPost=(WOPostBundlePage)systemSymbol("WKBundlePagePostMessage");
        gCreate=(WOStringCreate)systemSymbol("WKStringCreateWithUTF8CString");
        gUTF8=(WOStringGetUTF8)systemSymbol("WKStringGetUTF8CString");
        gLength=(WOStringLength)systemSymbol("WKStringGetLength");
        gType=(WOGetTypeID)systemSymbol("WKGetTypeID");
        gStringType=(WOStringTypeID)systemSymbol("WKStringGetTypeID");
        gRelease=(WORelease)systemSymbol("WKRelease");
        if (!setClient || !gStart || !gRegister || !gPost || !gCreate || !gUTF8 || !gLength || !gType || !gStringType || !gRelease) { reject(&gContext); return; }
        static WOBundleClientV1 client;
        client=(WOBundleClientV1){.base={1,&gContext},.didCreatePage=created,.willDestroyPage=destroyed,.didInitializePageGroup=NULL,.didReceiveMessage=NULL,.didReceiveMessageToPage=received};
        setClient(bundle,&client.base);
        fputs("WHEEL_OBSERVER_PLUGIN phase=initialized\n",stderr);
    } @catch (NSException *exception) { (void)exception; reject(&gContext); }
}
