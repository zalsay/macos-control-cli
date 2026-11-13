#ifndef BOUND_WHEEL_OBSERVER_ABI_H
#define BOUND_WHEEL_OBSERVER_ABI_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
typedef const struct OpaqueWKBundle *WOBundleRef;
typedef const struct OpaqueWKBundlePage *WOBundlePageRef;
typedef const struct OpaqueWKBundlePageGroup *WOBundlePageGroupRef;
typedef const struct OpaqueWKPage *WOPageRef;
typedef const struct OpaqueWKString *WOStringRef;
typedef const void *WOTypeRef;
typedef uint32_t WOTypeID;
typedef struct { int version; const void *clientInfo; } WOBundleClientBase;
typedef void (*WODidCreatePage)(WOBundleRef,WOBundlePageRef,const void *);
typedef void (*WOWillDestroyPage)(WOBundleRef,WOBundlePageRef,const void *);
typedef void (*WODidInitializePageGroup)(WOBundleRef,WOBundlePageGroupRef,const void *);
typedef void (*WODidReceiveMessage)(WOBundleRef,WOStringRef,WOTypeRef,const void *);
typedef void (*WODidReceiveMessageToPage)(WOBundleRef,WOBundlePageRef,WOStringRef,WOTypeRef,const void *);
typedef struct { WOBundleClientBase base; WODidCreatePage didCreatePage; WOWillDestroyPage willDestroyPage; WODidInitializePageGroup didInitializePageGroup; WODidReceiveMessage didReceiveMessage; WODidReceiveMessageToPage didReceiveMessageToPage; } WOBundleClientV1;
_Static_assert(offsetof(WOBundleClientV1,didCreatePage)==16 && sizeof(WOBundleClientV1)==56,"unsupported WebKit bundle ABI");
typedef void (*WOSetBundleClient)(WOBundleRef,WOBundleClientBase *);
typedef void (*WOStartMonitor)(WOBundlePageRef,bool);
typedef bool (*WORegisterMonitor)(WOBundlePageRef,void (*)(void *),bool,bool,void *);
typedef void (*WOPostBundlePage)(WOBundlePageRef,WOStringRef,WOTypeRef);
typedef WOStringRef (*WOStringCreate)(const char *);
typedef size_t (*WOStringGetUTF8)(WOStringRef,char *,size_t);
typedef size_t (*WOStringLength)(WOStringRef);
typedef WOTypeID (*WOGetTypeID)(WOTypeRef);
typedef WOTypeID (*WOStringTypeID)(void);
typedef void (*WORelease)(WOTypeRef);
#endif
