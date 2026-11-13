#if defined(SAFARIER_WHEEL_OBSERVER_PROBE)
#import "SafarierObjCSupport.h"
#import "../../scripts/bound-control-candidate/observer/BoundWheelObserverABI.h"
#import "../../scripts/bound-control-candidate/observer/BoundWheelObserverState.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <stdio.h>
#import <string.h>
#import <time.h>

typedef struct { int version; const void *clientInfo; } WOPageClientBase;
typedef void (*WOPageMessage)(WOPageRef,WOStringRef,WOTypeRef,const void *);
typedef void (*WOPageSyncMessage)(WOPageRef,WOStringRef,WOTypeRef,WOTypeRef *,const void *);
typedef struct { WOPageClientBase base; WOPageMessage didReceiveMessage; WOPageSyncMessage didReceiveSynchronousMessage; } WOPageClientV0;
_Static_assert(offsetof(WOPageClientV0,didReceiveMessage)==16 && sizeof(WOPageClientV0)==32,"unsupported WebKit page client ABI");
typedef void (*WOSetPageClient)(WOPageRef,const WOPageClientBase *);
typedef void (*WOPostPage)(WOPageRef,WOStringRef,WOTypeRef);
static const char *const kWOOrigin="/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit";
static WOSetPageClient gSetPageClient; static WOPostPage gPostPage;
static WOStringCreate gCreate; static WOStringGetUTF8 gUTF8; static WOStringLength gLength;
static WOGetTypeID gType; static WOStringTypeID gStringType, gPageType; static WORelease gRelease;
/* Never recycled: a stale callback can only address this bounded static state. */
static WOState gState; static WOPageRef gPage; static __weak id gView;
static void (^gCallback)(NSInteger); static BOOL gUsed, gActive; static char gPayload[50];
static WOPageClientV0 gClient;

static void *WOSymbol(const char *name) {
    void *symbol=dlsym(RTLD_DEFAULT,name); Dl_info info={0};
    return symbol && dladdr(symbol,&info) && info.dli_fname && strcmp(info.dli_fname,kWOOrigin)==0 ? symbol : NULL;
}
static uint64_t WONow(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static BOOL WOReadString(WOTypeRef value,char *buffer,size_t capacity) {
    if (!value || !gType || !gStringType || gType(value)!=gStringType()) return NO;
    size_t length=gLength((WOStringRef)value); if (length>=capacity) return NO;
    size_t bytes=gUTF8((WOStringRef)value,buffer,capacity);
    return wo_ascii_exact(buffer,capacity,length,bytes);
}
static BOOL WOPageForView(id view,WOPageRef *result) {
    if (!view || !result || ![view isKindOfClass:NSClassFromString(@"WKWebView")]) return NO;
    SEL selector=NSSelectorFromString(@"_pageRefForTransitionToWKWebView");
    Method method=class_getInstanceMethod(object_getClass(view),selector); Dl_info info={0};
    if (!method || !dladdr((void *)method_getImplementation(method),&info) || !info.dli_fname || strcmp(info.dli_fname,kWOOrigin)) return NO;
    NSMethodSignature *signature=[view methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments!=2 || signature.methodReturnLength!=sizeof(void *) || strcmp(signature.methodReturnType,"^{OpaqueWKPage=}")) return NO;
    *result=((WOPageRef (*)(id,SEL))objc_msgSend)(view,selector);
    return *result && gType && gPageType && gType((WOTypeRef)*result)==gPageType();
}
static BOOL WOPost(const char *command) {
    if (!gActive || !gPage) return NO;
    WOStringRef key=gCreate(command),body=gCreate(gPayload);
    if (!key || !body) { if (key) gRelease(key); if (body) gRelease(body); return NO; }
    gPostPage(gPage,key,(WOTypeRef)body); gRelease((WOTypeRef)key); gRelease((WOTypeRef)body); return YES;
}
static void WOReceivePageMessage(WOPageRef page,WOStringRef name,WOTypeRef body,const void *info) {
    if (!pthread_main_np() || info!=&gState) return;
    @try {
        if (!gActive) { fputs("WHEEL_OBSERVER_UI phase=late_ignored\n",stderr); return; }
        if (!gView || page!=gPage) { gState.phase=WO_FAILED; if (gCallback) gCallback(4); return; }
        char command[16]={0},payload[50]={0},nonce[33]={0}; uint64_t epoch=0,now=WONow();
        if (!WOReadString((WOTypeRef)name,command,sizeof(command)) || !WOReadString(body,payload,sizeof(payload)) || !wo_parse_payload(payload,nonce,&epoch) || !now) {
            gState.phase=WO_FAILED; if (gCallback) gCallback(4); return;
        }
        WOMessage message;
        if (!strcmp(command,"armed")) message=WO_MSG_ARMED;
        else if (!strcmp(command,"observed")) message=WO_MSG_OBSERVED;
        else if (!strcmp(command,"cancelled")) message=WO_MSG_CANCELLED;
        else { gState.phase=WO_FAILED; if (gCallback) gCallback(4); return; }
        WOResult result=wo_receive(&gState,message,nonce,epoch,now);
        if (result==WO_LATE) { fputs("WHEEL_OBSERVER_UI phase=late_ignored\n",stderr); return; }
        if (result==WO_REJECT) { if (gCallback) gCallback(4); return; }
        if (result==WO_OBSERVATION) { fputs("WHEEL_OBSERVER_UI phase=observed_not_ack\n",stderr); if (gCallback) gCallback(2); return; }
        if (gCallback) gCallback(message==WO_MSG_ARMED?1:3);
    } @catch (NSException *exception) { (void)exception; gState.phase=WO_FAILED; if (gCallback) gCallback(4); }
}

SFRCallStatus SFRWheelObserverConfigure(id configuration,NSURL *bundleURL) {
    if (!pthread_main_np() || !configuration || !bundleURL) return SFRCallStatusSignatureMismatch;
    @try {
        Class webViewClass=NSClassFromString(@"WKWebView");
        NSString *version=webViewClass ? [[NSBundle bundleForClass:webViewClass] objectForInfoDictionaryKey:@"CFBundleVersion"] : nil;
        if (![version isEqualToString:@"21624.5.1.11.3"]) return SFRCallStatusMissingSymbol;
        NSURL *plugins=[bundleURL URLByDeletingLastPathComponent];
        NSURL *contents=[plugins URLByDeletingLastPathComponent];
        NSURL *runner=[contents URLByDeletingLastPathComponent];
        if (!bundleURL.isFileURL || ![bundleURL.lastPathComponent isEqualToString:@"SafarierWheelObserver.bundle"] ||
            ![plugins.lastPathComponent isEqualToString:@"PlugIns"] || ![contents.lastPathComponent isEqualToString:@"Contents"] ||
            ![runner.lastPathComponent isEqualToString:@"SafarierRunner.app"] ||
            ![bundleURL.path isEqualToString:bundleURL.URLByStandardizingPath.path]) return SFRCallStatusSignatureMismatch;
        id options=nil,pool=nil; SFRCallStatus status=SFRNewInstance(@"_WKProcessPoolConfiguration",&options,NULL);
        if (status!=SFRCallStatusOK) return status;
        status=SFRSetObject(options,@"setInjectedBundleURL:",bundleURL,NULL); if (status!=SFRCallStatusOK) return status;
        status=SFRAllocInitWithObject(@"WKProcessPool",@"_initWithConfiguration:",options,&pool,NULL); if (status!=SFRCallStatusOK) return status;
        return SFRSetObject(configuration,@"setProcessPool:",pool,NULL);
    } @catch (NSException *exception) { (void)exception; return SFRCallStatusException; }
}
SFRCallStatus SFRWheelObserverBegin(id webView,NSString *payload,void (^callback)(NSInteger)) {
    if (!pthread_main_np() || gUsed || !callback) return SFRCallStatusSignatureMismatch;
    @try {
        char nonce[33]={0}; uint64_t epoch=0,now=WONow(); const char *bytes=payload.UTF8String;
        if (!bytes || payload.length!=49 || strlen(bytes)!=49 || !wo_parse_payload(bytes,nonce,&epoch) || !now || now>UINT64_MAX-UINT64_C(2000000000)) return SFRCallStatusSignatureMismatch;
        gSetPageClient=(WOSetPageClient)WOSymbol("WKPageSetPageInjectedBundleClient"); gPostPage=(WOPostPage)WOSymbol("WKPagePostMessageToInjectedBundle");
        gCreate=(WOStringCreate)WOSymbol("WKStringCreateWithUTF8CString"); gUTF8=(WOStringGetUTF8)WOSymbol("WKStringGetUTF8CString"); gLength=(WOStringLength)WOSymbol("WKStringGetLength");
        gType=(WOGetTypeID)WOSymbol("WKGetTypeID"); gStringType=(WOStringTypeID)WOSymbol("WKStringGetTypeID"); gPageType=(WOStringTypeID)WOSymbol("WKPageGetTypeID"); gRelease=(WORelease)WOSymbol("WKRelease");
        if (!gSetPageClient || !gPostPage || !gCreate || !gUTF8 || !gLength || !gType || !gStringType || !gPageType || !gRelease) return SFRCallStatusMissingSymbol;
        WOPageRef page=NULL; if (!WOPageForView(webView,&page)) return SFRCallStatusSignatureMismatch;
        if (!wo_begin(&gState,nonce,epoch,now+UINT64_C(2000000000),now)) return SFRCallStatusSignatureMismatch;
        gUsed=YES; gPage=page; gView=webView; gCallback=[callback copy]; gActive=YES; memcpy(gPayload,bytes,sizeof(gPayload));
        gClient=(WOPageClientV0){.base={0,&gState},.didReceiveMessage=WOReceivePageMessage,.didReceiveSynchronousMessage=NULL};
        gSetPageClient(page,&gClient.base);
        if (!WOPost("arm")) { gSetPageClient(page,NULL); SFRWheelObserverAbandon(); return SFRCallStatusException; }
        fputs("WHEEL_OBSERVER_UI phase=arm_sent\n",stderr); return SFRCallStatusOK;
    } @catch (NSException *exception) { (void)exception; return SFRCallStatusException; }
}
SFRCallStatus SFRWheelObserverCancel(id webView) {
    if (!pthread_main_np()) return SFRCallStatusSignatureMismatch;
    @try {
        WOPageRef page=NULL; if (!gActive || webView!=gView || !WOPageForView(webView,&page) || page!=gPage || !wo_cancel(&gState,WONow())) return SFRCallStatusSignatureMismatch;
        if (!WOPost("cancel")) return SFRCallStatusException;
        fputs("WHEEL_OBSERVER_UI phase=cancel_sent\n",stderr); return SFRCallStatusOK;
    } @catch (NSException *exception) { (void)exception; return SFRCallStatusException; }
}
SFRCallStatus SFRWheelObserverDetach(id webView) {
    if (!pthread_main_np()) return SFRCallStatusSignatureMismatch;
    @try {
        WOPageRef page=NULL; if (!gActive || webView!=gView || !WOPageForView(webView,&page) || page!=gPage) { SFRWheelObserverAbandon(); return SFRCallStatusSignatureMismatch; }
        gSetPageClient(page,NULL); SFRWheelObserverAbandon();
        fputs("WHEEL_OBSERVER_UI phase=client_detached monitor_unregister_unconfirmed=true\n",stderr); return SFRCallStatusOK;
    } @catch (NSException *exception) { (void)exception; SFRWheelObserverAbandon(); return SFRCallStatusException; }
}
void SFRWheelObserverAbandon(void) {
    if (!pthread_main_np()) return;
    @try { gActive=NO; gCallback=nil; gView=nil; gPage=NULL; }
    @catch (NSException *exception) { (void)exception; }
}
#endif
