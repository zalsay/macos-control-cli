#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import "SafarierObjCSupport.h"

typedef SFRCallStatus (*ObjectCompletionBridge)(id, NSString *, id, void (^)(id _Nullable), NSString **);

@interface SFRCompletionFake : NSObject
@property (nonatomic, copy) void (^pending)(id);
@property (nonatomic, strong) id received;
- (void)accept:(id)value completion:(void (^)(id))completion;
- (NSInteger)badReturn:(id)value completion:(void (^)(id))completion;
- (void)badFirst:(NSInteger)value completion:(void (^)(id))completion;
- (void)badSecond:(id)value completion:(NSInteger)completion;
- (void)throws:(id)value completion:(void (^)(id))completion;
@end
@implementation SFRCompletionFake
- (void)accept:(id)value completion:(void (^)(id))completion { self.received = value; self.pending = completion; }
- (NSInteger)badReturn:(id)value completion:(void (^)(id))completion { abort(); }
- (void)badFirst:(NSInteger)value completion:(void (^)(id))completion { abort(); }
- (void)badSecond:(id)value completion:(NSInteger)completion { abort(); }
- (void)throws:(id)value completion:(void (^)(id))completion { [NSException raise:@"FixtureException" format:@"fixture"]; }
@end

static int failures = 0;
#define CHECK(condition, label) do { if (!(condition)) { fprintf(stderr, "FAIL %s\n", label); failures++; } else { printf("PASS %s\n", label); } } while (0)
int main(void) { @autoreleasepool {
    ObjectCompletionBridge bridge = (ObjectCompletionBridge)dlsym(RTLD_DEFAULT, "SFRCallWithObjectCompletion");
    CHECK(bridge != NULL, "bridge exists");
    if (!bridge) return 1;
    SFRCompletionFake *fake = [SFRCompletionFake new];
    NSObject *argument = [NSObject new], *result = [NSObject new];
    __block id received = nil;
    SFRCallStatus status = bridge(fake, @"accept:completion:", argument, ^(id value) { received = value; }, NULL);
    CHECK(status == SFRCallStatusOK && fake.received == argument && received == nil, "correct ABI and argument");
    fake.pending(result);
    CHECK(received == result, "escaping object completion");
    status = bridge(fake, @"absent:completion:", argument, ^(id value) {}, NULL);
    CHECK(status == SFRCallStatusMissingSelector, "missing selector");
    status = bridge(fake, @"badReturn:completion:", argument, ^(id value) {}, NULL);
    CHECK(status == SFRCallStatusSignatureMismatch, "wrong return type");
    status = bridge(fake, @"badFirst:completion:", argument, ^(id value) {}, NULL);
    CHECK(status == SFRCallStatusSignatureMismatch, "wrong object argument type");
    status = bridge(fake, @"badSecond:completion:", argument, ^(id value) {}, NULL);
    CHECK(status == SFRCallStatusSignatureMismatch, "wrong completion argument type");
    status = bridge(fake, @"throws:completion:", argument, ^(id value) {}, NULL);
    CHECK(status == SFRCallStatusException, "exception is caught");
    return failures ? 1 : 0;
} }
