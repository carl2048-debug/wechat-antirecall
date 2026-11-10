#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <libproc.h>
#include <atomic>
#include <map>
#include <string>
#include <cstring>
#include <unistd.h>
#include "NativeFeatures.h"
#include "WeChatAntiRecallRuntime.h"

namespace {
std::atomic<bool> silent(false), blockUpdates(false);
std::map<SEL, IMP> originals;
bool updateHooks = false;
CFTypeRef savedUpdater = nullptr;
BOOL savedChecks = NO, savedDownloads = NO;

void setUpdaterSuppressed(bool enabled) {
    auto objectCall = reinterpret_cast<id(*)(id, SEL)>(objc_msgSend);
    auto boolCall = reinterpret_cast<BOOL(*)(id, SEL)>(objc_msgSend);
    auto setBool = reinterpret_cast<void(*)(id, SEL, BOOL)>(objc_msgSend);
    if (!enabled) {
        if (savedUpdater) {
            id updater = (__bridge id)savedUpdater;
            setBool(updater, sel_registerName("setAutomaticallyChecksForUpdates:"), savedChecks);
            setBool(updater, sel_registerName("setAutomaticallyDownloadsUpdates:"), savedDownloads);
            CFRelease(savedUpdater);
            savedUpdater = nullptr;
        }
        return;
    }
    Class cls = NSClassFromString(@"XAppUpdateManager");
    SEL shared = sel_registerName("sharedInstance"), getter = sel_registerName("sparkleUpdater");
    if (![(id)cls respondsToSelector:shared]) return;
    id manager = objectCall((id)cls, shared);
    if (![manager respondsToSelector:getter]) return;
    id updater = objectCall(manager, getter);
    const char *methods[] = {"automaticallyChecksForUpdates", "automaticallyDownloadsUpdates",
        "setAutomaticallyChecksForUpdates:", "setAutomaticallyDownloadsUpdates:"};
    for (const char *method : methods) if (![updater respondsToSelector:sel_registerName(method)]) return;
    if (savedUpdater && updater != (__bridge id)savedUpdater) setUpdaterSuppressed(false);
    if (!savedUpdater) {
        savedChecks = boolCall(updater, sel_registerName(methods[0]));
        savedDownloads = boolCall(updater, sel_registerName(methods[1]));
        savedUpdater = CFRetain((__bridge CFTypeRef)updater);
    }
    setBool(updater, sel_registerName(methods[2]), NO);
    setBool(updater, sel_registerName(methods[3]), NO);
}

void blockedVoid(id object, SEL selector) {
    if (!blockUpdates.load()) reinterpret_cast<void(*)(id,SEL)>(originals.at(selector))(object, selector);
}
void blockedArgument(id object, SEL selector, uintptr_t argument) {
    if (!blockUpdates.load()) reinterpret_cast<void(*)(id,SEL,uintptr_t)>(originals.at(selector))(object, selector, argument);
}
BOOL blockedBool(id object, SEL selector) {
    return blockUpdates.load() ? NO : reinterpret_cast<BOOL(*)(id,SEL)>(originals.at(selector))(object, selector);
}

bool installUpdateHooks() {
    Class cls = NSClassFromString(@"XAppUpdateManager");
    if (!cls) return false;
    const char *names[] = {"startUpdater", "checkForUpdates:", "startBackgroundUpdatesCheck:",
        "enableAutoUpdate:", "automaticallyDownloadsUpdates", "setAutomaticallyDownloadsUpdates:",
        "canCheckForUpdate", "setCanCheckForUpdate:"};
    struct Entry { SEL selector; Method method; IMP replacement; } entries[8];
    for (size_t i = 0; i < 8; ++i) {
        SEL selector = sel_registerName(names[i]);
        Method method = class_getInstanceMethod(cls, selector);
        if (!method) return false;
        const bool argument = strchr(names[i], ':') != nullptr;
        char returnType[32] = {};
        method_getReturnType(method, returnType, sizeof(returnType));
        IMP replacement;
        if (returnType[0] == 'v') replacement = argument ? (IMP)blockedArgument : (IMP)blockedVoid;
        else if (!argument && (returnType[0] == 'B' || returnType[0] == 'c')) replacement = (IMP)blockedBool;
        else return false;
        if (method_getNumberOfArguments(method) != (argument ? 3 : 2)) return false;
        entries[i] = {selector, method, replacement};
    }
    // Publish the immutable dispatch map before any replacement becomes reachable.
    for (const auto &entry : entries) originals.emplace(entry.selector, method_getImplementation(entry.method));
    for (const auto &entry : entries) class_replaceMethod(cls, entry.selector, entry.replacement, method_getTypeEncoding(entry.method));
    return true;
}

void refreshOptions() {
    NSString *domain = NSBundle.mainBundle.bundleIdentifier;
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"Library/Preferences/%@.plist", domain]];
    id value = [NSDictionary dictionaryWithContentsOfFile:path][@"WeChatAntiRecall_NativeOptions"];
    if (![value isKindOfClass:NSDictionary.class]) {
        CFPropertyListRef preferences = CFPreferencesCopyAppValue(CFSTR("WeChatAntiRecall_NativeOptions"), kCFPreferencesCurrentApplication);
        value = CFBridgingRelease(preferences);
    }
    NSDictionary *settings = [value isKindOfClass:NSDictionary.class] ? value : @{};
    auto flag = ^bool(NSString *name) {
        id v = settings[name];
        return [v isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)v) == CFBooleanGetTypeID() && [v boolValue];
    };
    silent.store(flag(@"silent"));
    const bool suppress = updateHooks && flag(@"blockUpdates");
    blockUpdates.store(suppress);
    setUpdaterSuppressed(suppress);
}

void publish(bool messageHook, bool redPacket) {
    struct proc_bsdinfo info = {};
    if (proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return;
    NSMutableArray *components = [NSMutableArray arrayWithObjects:
        @(wechat_antirecall_recall_log_runtime_version()), @(wechat_antirecall_window_privacy_runtime_version()), @"WeChatAntiRecallNativeOptions:1", nil];
    if (messageHook) [components addObject:@(wechat_antirecall_keyword_alert_runtime_version())];
    if (redPacket) [components addObject:@(wechat_antirecall_red_packet_runtime_version())];
    if (updateHooks) [components addObject:@"WeChatAntiRecallBlockUpdates:1"];
    NSDictionary *state = @{
        @"pid": @(getpid()), @"startToken": @(info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec),
        @"build": [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"",
        @"executable": NSBundle.mainBundle.executablePath.stringByResolvingSymlinksInPath ?: @"",
        @"components": components, @"contentCache": @(messageHook)
    };
    NSString *relative = [@"Library/Caches/WeChatAntiRecallRuntime" stringByAppendingPathComponent:NSBundle.mainBundle.bundleIdentifier];
    NSString *directory = [NSHomeDirectory() stringByAppendingPathComponent:relative];
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
    [data writeToFile:[directory stringByAppendingPathComponent:@"session.json"] options:NSDataWritingAtomic error:nil];
}
}

bool wechat_antirecall_native_silent(void) { return silent.load(); }

void wechat_antirecall_native_features_start(bool messageHook, bool redPacket) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Publish a receipt immediately; update-hook availability is refreshed
        // after installing AppKit/Objective-C changes on the main queue.
        publish(messageHook, redPacket);
        dispatch_async(dispatch_get_main_queue(), ^{
            updateHooks = installUpdateHooks();
            refreshOptions();
            publish(messageHook, redPacket);
            static dispatch_source_t timer;
            timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
            dispatch_source_set_event_handler(timer, ^{ refreshOptions(); });
            dispatch_resume(timer);
        });
    });
}
