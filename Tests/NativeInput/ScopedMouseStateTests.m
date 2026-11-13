#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#include <sys/wait.h>
#include <spawn.h>
#include <mach-o/dyld.h>
#include <limits.h>
#include <unistd.h>
// White-box policy tests include the implementation; do not apply header-only
// nullability completeness rules to its existing function definitions.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#import "../../Sources/SafarierObjCSupport/SFRRuntime.m"
#pragma clang diagnostic pop

@interface SFRMouseFixture : NSResponder
@property(nonatomic) NSUInteger observed;
@property(nonatomic) BOOL throwsOnDown;
@end
@implementation SFRMouseFixture
- (void)mouseDown:(NSEvent *)event {
    self.observed = NSEvent.pressedMouseButtons;
    if (self.throwsOnDown) @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"native fixture" userInfo:nil];
}
@end
@interface SFRWrongMouseFixture : NSObject
- (NSUInteger)mouseDown:(NSEvent *)event;
@end
@implementation SFRWrongMouseFixture
- (NSUInteger)mouseDown:(NSEvent *)event { return 0; }
@end
@interface SFRCompletionFixture : NSObject
@property(nonatomic) BOOL called;
- (void)complete:(void (^)(void))ready;
- (void)fail:(void (^)(void))ready;
@end
@implementation SFRCompletionFixture
- (void)complete:(void (^)(void))ready { self.called = YES; ready(); }
- (void)fail:(void (^)(void))ready { @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"completion fixture" userInfo:nil]; }
@end
@interface SFRActivityFixture : NSObject
@property(nonatomic, getter=isActive) BOOL active;
@end
@implementation SFRActivityFixture
@end
static id sOriginalWindowMarker;
static id SFRKeyWindowSpy(id receiver, SEL selector) { return sOriginalWindowMarker; }
static NSUInteger sCursorSpyCalls;
static void SFRCursorSpy(id receiver, SEL selector) { sCursorSpyCalls++; }
static void SFRCursorBoolSpy(id receiver, SEL selector, BOOL hidden) { sCursorSpyCalls++; }

static NSUInteger sChecks;
static BOOL RunWorker(void (^operation)(void)) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        operation(); dispatch_semaphore_signal(done);
    });
    return dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0;
}
static void Check(BOOL condition, const char *name) {
    sChecks++;
    if (!condition) { fprintf(stderr, "FAIL %s\n", name); exit(1); }
    printf("PASS %s\n", name);
}

static NSUInteger sLegacyOriginalCalls, sLegacyPermissionCalls;
static BOOL sLegacyPermissionValue;
static id sLegacyReceiver, sLegacyImage, sLegacyEvent, sLegacyPasteboard, sLegacySource;
static SEL sLegacySelector;
static NSPoint sLegacyPoint;
static NSSize sLegacyOffset;
static BOOL sLegacySlideBack;
static BOOL SFRLegacyPermissionSpy(id self, SEL cmd) { sLegacyPermissionCalls++; return sLegacyPermissionValue; }
static BOOL SFRLegacyPermissionOther(id self, SEL cmd) { return YES; }
static void SFRLegacyOriginalSpy(id self, SEL cmd, id image, NSPoint point, NSSize offset, id event, id pasteboard, id source, BOOL slideBack) {
    sLegacyOriginalCalls++;
    sLegacyReceiver = self; sLegacySelector = cmd; sLegacyImage = image;
    sLegacyPoint = point; sLegacyOffset = offset; sLegacyEvent = event;
    sLegacyPasteboard = pasteboard; sLegacySource = source; sLegacySlideBack = slideBack;
}
static void SFRLegacyOtherSpy(id self, SEL cmd, id image, NSPoint point, NSSize offset, id event, id pasteboard, id source, BOOL slideBack) { }
static NSString *SFRLegacyEncoding(int bad) {
    const char *types[] = {@encode(void), @encode(id), @encode(SEL), @encode(id), @encode(NSPoint), @encode(NSSize), @encode(id), @encode(id), @encode(id), @encode(BOOL)};
    NSMutableString *result = [NSMutableString string];
    for (int i = 0; i < 10; i++) [result appendFormat:@"%s", i == bad ? @encode(int) : types[i]];
    return result;
}
static NSUInteger sModernCalls;
static id sModernReceiver, sModernItems, sModernEvent, sModernSource, sModernResult;
static SEL sModernSelector;
static id SFRModernSpy(id self, SEL cmd, id items, id event, id source) {
    sModernCalls++; sModernReceiver = self; sModernSelector = cmd;
    sModernItems = items; sModernEvent = event; sModernSource = source;
    return sModernResult;
}
static NSString *SFRModernEncoding(int bad) {
    const char *types[] = {@encode(id), @encode(id), @encode(SEL), @encode(id), @encode(id), @encode(id)};
    NSMutableString *result = [NSMutableString string];
    for (int i = 0; i < 6; i++) [result appendFormat:@"%s", i == bad ? @encode(int) : types[i]];
    return result;
}
static int sModernBadSlot = -1, sModernBadType = -1;
static BOOL sModernGesture = YES, sModernOwn = NO;
static int sModernExtraSlot = -1, sModernOwnSlot = 0;
static Class SFRLegacyFixture(const char *name, int bad, BOOL ownLegacy, const char *permissionEncoding) {
    Class parent = objc_allocateClassPair(WKWebView.class, [[NSString stringWithFormat:@"%sParent", name] UTF8String], 0);
    SEL drag = NSSelectorFromString(@"dragImage:at:offset:event:pasteboard:source:slideBack:");
    class_addMethod(parent, drag, (IMP)SFRLegacyOriginalSpy, SFRLegacyEncoding(bad).UTF8String);
    SEL modern[] = {NSSelectorFromString(@"beginDraggingSessionWithItems:event:source:"), NSSelectorFromString(@"beginDraggingSessionWithItems:gesture:source:")};
    for (int i = 0; i < (sModernGesture ? 2 : 1); i++)
        class_addMethod(parent, modern[i], (IMP)SFRModernSpy, [SFRModernEncoding(i == sModernBadSlot ? sModernBadType : -1) stringByAppendingString:(i == sModernExtraSlot ? @"@" : @"")].UTF8String);
    objc_registerClassPair(parent);
    Class target = objc_allocateClassPair(parent, name, 0);
    class_addMethod(target, NSSelectorFromString(@"canBeginLegacySystemDrag"), (IMP)SFRLegacyPermissionSpy, permissionEncoding);
    if (ownLegacy) class_addMethod(target, drag, (IMP)SFRLegacyOtherSpy, SFRLegacyEncoding(-1).UTF8String);
    if (sModernOwn) class_addMethod(target, modern[sModernOwnSlot], (IMP)SFRModernSpy, SFRModernEncoding(-1).UTF8String);
    objc_registerClassPair(target);
    return target;
}
// Each case executes in a fresh process, so the fixed single-target bridge state
// and Objective-C runtime are never inherited from a forked parent.
extern char **environ;
static BOOL RunIsolatedFixture(const char *mode) {
    char executable[PATH_MAX];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) != 0) return NO;
    char *const args[] = {executable, (char *)mode, NULL};
    pid_t child = 0;
    if (posix_spawn(&child, executable, NULL, NULL, args, environ) != 0) return NO;
    int status = 0;
    return waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0;
}
// Literal public selector is deliberately independent of the production slot table.
static BOOL PublicGestureFixture(void) {
    NSString *encoding = [NSString stringWithFormat:@"%s@:", @encode(BOOL)];
    Class target = SFRLegacyFixture("SFRPublicGestureSelector", -1, NO, encoding.UTF8String);
    SEL publicGesture = NSSelectorFromString(@"beginDraggingSessionWithItems:gesture:source:");
    SEL incorrectGesture = NSSelectorFromString(@"beginDraggingSessionWithItems:gestureRecognizer:source:");
    return class_getInstanceMethod(class_getSuperclass(target), publicGesture) &&
        SFRInstallLegacySystemDragBoundary(target, NULL) == SFRCallStatusOK &&
        SFROwnInstanceMethod(target, publicGesture) && !SFROwnInstanceMethod(target, incorrectGesture) && NSApp == nil;
}
static BOOL OptionalGestureFixture(void) {
    sModernGesture = NO;
    NSString *encoding = [NSString stringWithFormat:@"%s@:", @encode(BOOL)];
    Class target = SFRLegacyFixture("SFROptionalRuntime", -1, NO, encoding.UTF8String);
    SEL gesture = NSSelectorFromString(@"beginDraggingSessionWithItems:gesture:source:");
    BOOL present = class_getInstanceMethod(class_getSuperclass(target), gesture) != NULL;
    NSString *detail = nil;
    BOOL installed = SFRInstallLegacySystemDragBoundary(target, &detail) == SFRCallStatusOK;
    BOOL ok = present ? (SFROwnInstanceMethod(target, gesture) && [detail containsString:@"gesture present"]) :
                        (!SFROwnInstanceMethod(target, gesture) && [detail containsString:@"gesture unavailable"]);
    printf("OPTIONAL_GESTURE_RUNTIME=%s\n", present ? "present" : "absent");
    return installed && ok && NSApp == nil;
}
static void TestLegacySystemDragBoundary(void) {
    Check(NSApp == nil, "legacy test does not initialize NSApplication");
    SEL drag = NSSelectorFromString(@"dragImage:at:offset:event:pasteboard:source:slideBack:");
    Method system = class_getInstanceMethod(NSView.class, drag);
    IMP systemOriginal = method_getImplementation(system);
    NSString *permissionEncoding = [NSString stringWithFormat:@"%s@:", @encode(BOOL)];
    NSString *extraPermissionEncoding = [permissionEncoding stringByAppendingString:@"@"];
    for (int i = 0; i < 10; i++) {
        Class invalid = SFRLegacyFixture([[NSString stringWithFormat:@"SFRLegacyBad%d", i] UTF8String], i, NO, permissionEncoding.UTF8String);
        Check(SFRInstallLegacySystemDragBoundary(invalid, NULL) != SFRCallStatusOK, "legacy rejects each ABI mismatch");
    }
    for (int slot = 0; slot < 2; slot++) for (int type = 0; type < 6; type++) {
        sModernBadSlot = slot; sModernBadType = type;
        Class invalid = SFRLegacyFixture([[NSString stringWithFormat:@"SFRModernBad%d_%d", slot, type] UTF8String], -1, NO, permissionEncoding.UTF8String);
        Check(SFRInstallLegacySystemDragBoundary(invalid, NULL) != SFRCallStatusOK && !SFROwnInstanceMethod(invalid, drag), "modern ABI mismatch preflight leaves legacy uninstalled");
    }
    sModernBadSlot = -1; sModernBadType = -1;
    for (int slot = 0; slot < 2; slot++) {
        sModernExtraSlot = slot;
        Class invalid = SFRLegacyFixture([[NSString stringWithFormat:@"SFRModernExtra%d", slot] UTF8String], -1, NO, permissionEncoding.UTF8String);
        Check(SFRInstallLegacySystemDragBoundary(invalid, NULL) != SFRCallStatusOK && !SFROwnInstanceMethod(invalid, drag), "modern extra argument preflight");
    }
    sModernExtraSlot = -1; sModernOwn = YES;
    Class modernOwned = SFRLegacyFixture("SFRModernOwned", -1, NO, permissionEncoding.UTF8String);
    Check(SFRInstallLegacySystemDragBoundary(modernOwned, NULL) != SFRCallStatusOK && !SFROwnInstanceMethod(modernOwned, drag), "modern own conflict preflight");
    sModernOwnSlot = 1;
    Class gestureOwned = SFRLegacyFixture("SFRGestureOwned", -1, NO, permissionEncoding.UTF8String);
    Check(SFRInstallLegacySystemDragBoundary(gestureOwned, NULL) != SFRCallStatusOK && !SFROwnInstanceMethod(gestureOwned, drag), "gesture own conflict preflight");
    sModernOwn = NO;
    Class badPermission = SFRLegacyFixture("SFRLegacyBadPermission", -1, NO, "i@:");
    Check(SFRInstallLegacySystemDragBoundary(badPermission, NULL) != SFRCallStatusOK, "legacy rejects permission ABI mismatch");
    Class extraPermission = SFRLegacyFixture("SFRLegacyExtraPermission", -1, NO, extraPermissionEncoding.UTF8String);
    Check(SFRInstallLegacySystemDragBoundary(extraPermission, NULL) != SFRCallStatusOK, "legacy rejects permission extra argument");
    Class owned = SFRLegacyFixture("SFRLegacyOwned", -1, YES, permissionEncoding.UTF8String);
    IMP ownedOriginal = method_getImplementation(class_getInstanceMethod(owned, drag));
    Check(SFRInstallLegacySystemDragBoundary(owned, NULL) != SFRCallStatusOK && method_getImplementation(class_getInstanceMethod(owned, drag)) == ownedOriginal, "legacy refuses existing own implementation");
    Class target = SFRLegacyFixture("SFRLegacyTarget", -1, NO, permissionEncoding.UTF8String);
    __block SFRCallStatus offMain = SFRCallStatusOK;
    Check(RunWorker(^{ offMain = SFRInstallLegacySystemDragBoundary(target, NULL); }), "legacy off-main installer worker completes");
    Check(offMain != SFRCallStatusOK, "legacy off-main install refused");
    Check(SFRInstallLegacySystemDragBoundary(target, NULL) == SFRCallStatusOK, "legacy install succeeds");
    Check(SFRInstallLegacySystemDragBoundary(target, NULL) == SFRCallStatusOK, "legacy install is idempotent");
    Class other = SFRLegacyFixture("SFRLegacyOtherTarget", -1, NO, permissionEncoding.UTF8String);
    Check(SFRInstallLegacySystemDragBoundary(other, NULL) != SFRCallStatusOK, "legacy second target refused");
    SEL modernSelectors[] = {NSSelectorFromString(@"beginDraggingSessionWithItems:event:source:"), NSSelectorFromString(@"beginDraggingSessionWithItems:gesture:source:")};
    typedef id (*ModernCall)(id, SEL, id, id, id);
    id modernReceiver = [NSObject new], items = [NSObject new], eventArg = [NSObject new], sourceArg = [NSObject new];
    sModernResult = [NSObject new];
    for (int i = 0; i < 2; i++) {
        SEL selector = modernSelectors[i];
        Method ownModern = SFROwnInstanceMethod(target, selector);
        Check(ownModern != NULL, "modern boundary installed on target");
        ModernCall modern = (ModernCall)method_getImplementation(ownModern);
        sLegacyPermissionValue = NO; sLegacyPermissionCalls = 0; sModernCalls = 0;
        Check(modern(modernReceiver, selector, items, eventArg, sourceArg) == nil && sLegacyPermissionCalls == 1 && sModernCalls == 0, "modern denied returns nil without original");
        sLegacyPermissionValue = YES;
        Check(modern(modernReceiver, selector, items, eventArg, sourceArg) == sModernResult && sLegacyPermissionCalls == 2 && sModernCalls == 1 && sModernReceiver == modernReceiver && sModernSelector == selector && sModernItems == items && sModernEvent == eventArg && sModernSource == sourceArg, "modern forwards identity and all arguments");
        sModernResult = nil;
        Check(modern(modernReceiver, selector, items, eventArg, sourceArg) == nil && sLegacyPermissionCalls == 3 && sModernCalls == 2, "modern preserves original nil return");
        sModernResult = [NSObject new];
        Check(RunWorker(^{ (void)modern(modernReceiver, selector, items, eventArg, sourceArg); }), "modern off-main worker completes");
        Check(sLegacyPermissionCalls == 3 && sModernCalls == 2, "modern off-main denied");
    }
    SEL gateSelector = NSSelectorFromString(@"canBeginLegacySystemDrag");
    Method gateMethod = SFROwnInstanceMethod(target, gateSelector);
    IMP gateOriginal = method_setImplementation(gateMethod, (IMP)SFRLegacyPermissionOther);
    ModernCall gateCheck = (ModernCall)method_getImplementation(SFROwnInstanceMethod(target, modernSelectors[0]));
    NSUInteger gateCalls = sLegacyPermissionCalls, originalCalls = sModernCalls;
    Check(gateCheck(modernReceiver, modernSelectors[0], items, eventArg, sourceArg) == nil && sLegacyPermissionCalls == gateCalls && sModernCalls == originalCalls, "modern permission drift fails closed");
    method_setImplementation(gateMethod, gateOriginal);
    for (int i = 0; i < 2; i++) {
        SEL selector = modernSelectors[i];
        Method inheritedModern = class_getInstanceMethod(class_getSuperclass(target), selector);
        IMP originalModern = method_setImplementation(inheritedModern, (IMP)SFRLegacyPermissionOther);
        ModernCall modern = (ModernCall)method_getImplementation(SFROwnInstanceMethod(target, selector));
        NSUInteger beforePermission = sLegacyPermissionCalls, beforeOriginal = sModernCalls;
        Check(SFRInstallLegacySystemDragBoundary(target, NULL) != SFRCallStatusOK && modern(modernReceiver, selector, items, eventArg, sourceArg) == nil && sLegacyPermissionCalls == beforePermission && sModernCalls == beforeOriginal, "modern inherited drift fails closed");
        method_setImplementation(inheritedModern, originalModern);
        Method ownModern = SFROwnInstanceMethod(target, selector);
        IMP boundary = method_setImplementation(ownModern, (IMP)SFRModernSpy);
        Check(SFRInstallLegacySystemDragBoundary(target, NULL) != SFRCallStatusOK && modern(modernReceiver, selector, items, eventArg, sourceArg) == nil, "modern ownership drift fails closed");
        method_setImplementation(ownModern, boundary);
    }
    sLegacyPermissionCalls = 0;
    typedef void (*LegacyCall)(id, SEL, id, NSPoint, NSSize, id, id, id, BOOL);
    LegacyCall call = (LegacyCall)method_getImplementation(class_getInstanceMethod(target, drag));
    id dummy = [NSObject new];
    sLegacyPermissionValue = NO;
    call(dummy, drag, nil, NSZeroPoint, NSZeroSize, nil, nil, nil, NO);
    Check(sLegacyPermissionCalls == 1 && sLegacyOriginalCalls == 0, "legacy denial does not call original");
    sLegacyPermissionValue = YES;
    id image = [NSObject new], event = [NSObject new], pasteboard = [NSObject new], source = [NSObject new];
    NSPoint point = NSMakePoint(13.25, -27.5);
    NSSize offset = NSMakeSize(-4.75, 9.125);
    call(dummy, drag, image, point, offset, event, pasteboard, source, YES);
    Check(sLegacyPermissionCalls == 2 && sLegacyOriginalCalls == 1, "legacy permission forwards original exactly once");
    Check(sLegacyReceiver == dummy && sLegacySelector == drag && sLegacyImage == image &&
          NSEqualPoints(sLegacyPoint, point) && NSEqualSizes(sLegacyOffset, offset) &&
          sLegacyEvent == event && sLegacyPasteboard == pasteboard && sLegacySource == source && sLegacySlideBack == YES,
          "legacy forwards selector all objects point size and BOOL unchanged");
    Check(RunWorker(^{ call(dummy, drag, nil, NSZeroPoint, NSZeroSize, nil, nil, nil, NO); }), "legacy off-main call worker completes");
    Check(sLegacyPermissionCalls == 2 && sLegacyOriginalCalls == 1, "legacy off-main call denied before permission");
    SEL permission = NSSelectorFromString(@"canBeginLegacySystemDrag");
    method_setImplementation(class_getInstanceMethod(target, permission), (IMP)SFRLegacyPermissionOther);
    Check(SFRInstallLegacySystemDragBoundary(target, NULL) != SFRCallStatusOK, "legacy permission drift rejected");
    call(dummy, drag, nil, NSZeroPoint, NSZeroSize, nil, nil, nil, NO);
    Check(sLegacyPermissionCalls == 2 && sLegacyOriginalCalls == 1, "legacy permission drift denies invocation");
    method_setImplementation(class_getInstanceMethod(target, permission), (IMP)SFRLegacyPermissionSpy);
    method_setImplementation(class_getInstanceMethod(target, drag), (IMP)SFRLegacyOtherSpy);
    Check(SFRInstallLegacySystemDragBoundary(target, NULL) != SFRCallStatusOK, "legacy ownership drift rejected");
    Check(method_getImplementation(system) == systemOriginal && NSApp == nil, "legacy leaves NSView and NSApp untouched");
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2) {
            if (strcmp(argv[1], "--public-gesture-fixture") == 0) return PublicGestureFixture() ? 0 : 1;
            if (strcmp(argv[1], "--optional-gesture-fixture") == 0) return OptionalGestureFixture() ? 0 : 1;
            return 2;
        }
        if (argc != 1) return 2;
        Check(RunIsolatedFixture("--public-gesture-fixture"), "public gesture selector installed and incorrect selector absent");
        Check(RunIsolatedFixture("--optional-gesture-fixture"), "optional gesture follows actual inherited runtime availability");
        TestLegacySystemDragBoundary();
        Method method = class_getClassMethod(NSEvent.class, @selector(pressedMouseButtons));
        IMP original = method_getImplementation(method);
        __block NSUInteger seen = 0;
        NSString *detail = nil;
        SFRCallStatus status = SFRWithScopedMouseButtons(1, ^{ seen = NSEvent.pressedMouseButtons; }, &detail);
        Check(status == SFRCallStatusOK && seen == 1, "synthetic button query");
        Check(method_getImplementation(method) == original, "success restores original IMP");
        __block BOOL nestedOK = NO;
        status = SFRWithScopedMouseButtons(1, ^{
            SFRCallStatus inner = SFRWithScopedMouseButtons(2, ^{ nestedOK = NSEvent.pressedMouseButtons == 2; }, NULL);
            nestedOK = nestedOK && inner == SFRCallStatusOK && NSEvent.pressedMouseButtons == 1;
        }, &detail);
        Check(status == SFRCallStatusOK && nestedOK, "nested scope restores enclosing mask");
        Check(method_getImplementation(method) == original, "nested scope restores original IMP");
        status = SFRWithScopedMouseButtons(1, ^{
            @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"isolated native fixture" userInfo:nil];
        }, &detail);
        Check(status == SFRCallStatusException, "Objective-C exception is contained");
        Check(method_getImplementation(method) == original, "exception restores original IMP");
        __block NSUInteger background = NSUIntegerMax;
        const NSUInteger sentinel = (NSUInteger)1 << 31;
        status = SFRWithScopedMouseButtons(sentinel, ^{
            Check(NSEvent.pressedMouseButtons == sentinel, "main sees scoped sentinel");
            Check(RunWorker(^{ background = NSEvent.pressedMouseButtons; }), "worker completes");
        }, &detail);
        Check(status == SFRCallStatusOK && background != sentinel, "other thread retains hardware query");
        __block BOOL called = NO;
        __block SFRCallStatus offMain = SFRCallStatusOK;
        Check(RunWorker(^{
            offMain = SFRWithScopedMouseButtons(1, ^{ called = YES; }, NULL);
        }), "off-main worker completes");
        Check(offMain == SFRCallStatusException && !called, "off-main mutation refused");
        Check(method_getImplementation(method) == original, "off-main refusal leaves IMP unchanged");
        BOOL loopOK = YES;
        for (NSUInteger value = 0; value < 100; value++) {
            __block NSUInteger observed = NSUIntegerMax;
            status = SFRWithScopedMouseButtons(value, ^{ observed = NSEvent.pressedMouseButtons; }, NULL);
            loopOK = loopOK && status == SFRCallStatusOK && observed == value && method_getImplementation(method) == original;
        }
        Check(loopOK, "100 scopes leave no override");
        NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSMakePoint(10, 10) modifierFlags:0 timestamp:0 windowNumber:0 context:nil eventNumber:1 clickCount:1 pressure:0];
        SFRMouseFixture *mouse = [SFRMouseFixture new];
        status = SFRDispatchScopedMouseEvent(mouse, down, 1, &detail);
        Check(status == SFRCallStatusOK && mouse.observed == 1, "native event observes logical down state");
        Check(method_getImplementation(method) == original, "native event restores hardware query");
        mouse.throwsOnDown = YES;
        status = SFRDispatchScopedMouseEvent(mouse, down, 1, &detail);
        Check(status == SFRCallStatusException && method_getImplementation(method) == original, "event exception stays inside ObjC and restores state");
        status = SFRDispatchScopedMouseEvent(mouse, down, 0, &detail);
        Check(status == SFRCallStatusSignatureMismatch, "inconsistent event mask refused");
        status = SFRDispatchScopedMouseEvent([NSObject new], down, 1, &detail);
        Check(status == SFRCallStatusMissingSelector, "missing event callback refused");
        status = SFRDispatchScopedMouseEvent([SFRWrongMouseFixture new], down, 1, &detail);
        Check(status == SFRCallStatusSignatureMismatch, "wrong event callback ABI refused");
        __block BOOL completed = NO;
        SFRCompletionFixture *completion = [SFRCompletionFixture new];
        status = SFRCallWithVoidCompletion(completion, @"complete:", ^{ completed = YES; }, &detail);
        Check(status == SFRCallStatusOK && completed && completion.called, "void completion ABI and callback");
        status = SFRCallWithVoidCompletion(completion, @"description", ^{}, &detail);
        Check(status == SFRCallStatusSignatureMismatch, "non-block completion ABI refused");
        status = SFRCallWithVoidCompletion(completion, @"fail:", ^{}, &detail);
        Check(status == SFRCallStatusException, "completion exception contained");
        typedef struct { atomic_bool stop, leaked; atomic_ulong reads; } Race;
        Race *race = calloc(1, sizeof(Race));
        atomic_init(&race->stop, false);
        atomic_init(&race->leaked, false);
        atomic_init(&race->reads, 0);
        dispatch_semaphore_t raceDone = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            while (!atomic_load(&race->stop)) {
                if (NSEvent.pressedMouseButtons & sentinel) atomic_store(&race->leaked, true);
                atomic_fetch_add(&race->reads, 1);
            }
            dispatch_semaphore_signal(raceDone);
        });
        for (NSUInteger i = 0; i < 2000; i++) {
            status = SFRWithScopedMouseButtons(sentinel | i, ^{ (void)NSEvent.pressedMouseButtons; }, NULL);
            if (status != SFRCallStatusOK) atomic_store(&race->leaked, true);
        }
        atomic_store(&race->stop, true);
        Check(dispatch_semaphore_wait(raceDone, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0, "concurrent getter worker completes");
        Check(!atomic_load(&race->leaked) && atomic_load(&race->reads) > 0 && method_getImplementation(method) == original, "2000 concurrent scope transitions do not leak or free an in-flight IMP");
        free(race);
        // White-box cursor tests substitute spies, never the real system cursor writers.
        SFRActivityFixture *activity = [SFRActivityFixture new];
        // Do not initialize AppKit cursors or call their real setters in a CLI test.
        // The GUI probe separately validates the real cursor classes and installation.
        sCursorProtectedApplication = (NSApplication *)activity;
        IMP cursorSet = atomic_load(&sCursorSetOriginal);
        IMP cursorMove = atomic_load(&sCursorHideUntilMoveOriginal);
        IMP cursorChange = atomic_load(&sCursorHideUntilChangeOriginal);
        atomic_store(&sCursorSetOriginal, (IMP)SFRCursorSpy);
        atomic_store(&sCursorHideUntilMoveOriginal, (IMP)SFRCursorBoolSpy);
        atomic_store(&sCursorHideUntilChangeOriginal, (IMP)SFRCursorSpy);
        activity.active = NO;
        NSUInteger suppressedBefore = SFRBackgroundCursorWritesSuppressed();
        SFRSetCursor([NSObject new], @selector(set));
        SFRHideCursorUntilMove(NSCursor.class, @selector(setHiddenUntilMouseMoves:), YES);
        SFRHideCursorUntilChange(NSCursor.class, NSSelectorFromString(@"hideUntilChanged"));
        Check(sCursorSpyCalls == 0 && SFRBackgroundCursorWritesSuppressed() >= suppressedBefore + 2, "inactive Runner cannot set or hide the system cursor");
        activity.active = YES;
        SFRSetCursor([NSObject new], @selector(set));
        SFRHideCursorUntilMove(NSCursor.class, @selector(setHiddenUntilMouseMoves:), NO);
        Check(sCursorSpyCalls == 2, "foreground cursor calls forward to original implementation spies");
        atomic_store(&sCursorSetOriginal, cursorSet);
        atomic_store(&sCursorHideUntilMoveOriginal, cursorMove);
        atomic_store(&sCursorHideUntilChangeOriginal, cursorChange);
        sCursorProtectedApplication = nil;
        IMP savedKeyOriginal = atomic_load(&sApplicationKeyOriginal);
        void *savedWebKitImage = atomic_load(&sBackgroundWebKitImage);
        SFRBackgroundPageActivityToken *origin = [SFRBackgroundPageActivityToken new];
        SFRActivityFixture *inactive = [SFRActivityFixture new];
        id virtualWindow = [NSObject new];
        sOriginalWindowMarker = [NSObject new];
        origin.application = (NSApplication *)inactive;
        origin.window = (NSWindow *)virtualWindow;
        sBackgroundPageActivity = origin;
        atomic_store(&sApplicationKeyOriginal, (IMP)SFRKeyWindowSpy);
        Dl_info testImage = {0};
        dladdr((const void *)&main, &testImage);
        atomic_store(&sBackgroundWebKitImage, testImage.dli_fbase);
        Check(SFRLogicalKeyWindow(inactive, @selector(keyWindow)) == virtualWindow, "verified query origin receives logical window");
        atomic_store(&sBackgroundWebKitImage, NULL);
        Check(SFRLogicalKeyWindow(inactive, @selector(keyWindow)) == sOriginalWindowMarker, "application and AppKit query origins retain real window");
        atomic_store(&sBackgroundWebKitImage, testImage.dli_fbase);
        inactive.active = YES;
        Check(SFRLogicalKeyWindow(inactive, @selector(keyWindow)) == sOriginalWindowMarker, "foreground query remains original even for WebKit origin");
        origin.closed = YES;
        sBackgroundPageActivity = nil;
        sOriginalWindowMarker = nil;
        atomic_store(&sApplicationKeyOriginal, savedKeyOriginal);
        atomic_store(&sBackgroundWebKitImage, savedWebKitImage);
        id lease = nil;
        status = SFRBeginBackgroundPageActivity([NSObject new], &lease, ^{ called = YES; }, &detail);
        Check(status == SFRCallStatusMissingClass && lease == nil, "non-WebView page context refused");
        printf("NATIVE_BRIDGE_SELFTEST_OK checks=%lu\n", (unsigned long)sChecks);
    }
    return 0;
}
