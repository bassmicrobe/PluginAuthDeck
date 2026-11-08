// SPDX-License-Identifier: AGPL-3.0-only
#import <AppKit/AppKit.h>
#import <Vision/Vision.h>
#import <ImageIO/ImageIO.h>
#include "LicenseProbe.h"
#include <algorithm>
#include <chrono>
#include <deque>
#include <cmath>
#include <vector>
#include <unordered_set>
#include <atomic>
#include <thread>
#include <poll.h>
#include <spawn.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <mach-o/dyld.h>
#include <crt_externs.h>

@interface PADLicenseOCRState : NSObject
{
@public
    PluginAuthLicense::ProbeResult result;
}
@property(nonatomic, weak) NSView* view;
@property(nonatomic, weak) NSWindow* window;
@property(nonatomic, weak) NSWindow* preferredWindow;
@property(nonatomic, copy) NSString* product;
@property(nonatomic) NSRect bounds;
@property(nonatomic) BOOL busy;
@property(nonatomic) BOOL ready;
@property(nonatomic) double capturedAt;
@end
@implementation PADLicenseOCRState
@end

namespace PluginAuthLicense
{
namespace
{
bool userInteracted = false;
constexpr double ocrBudgetMilliseconds = 2500.0;
constexpr double ocrSampleIntervalMilliseconds = 1500.0;

void monitorScanInteraction()
{
    static id monitor = nil;
    if (monitor != nil) return;
    // A local monitor sees only this host's events. No key characters, button
    // coordinates, or event payload is read or retained; the event is unchanged.
    monitor = [NSEvent addLocalMonitorForEventsMatchingMask:
        NSEventMaskKeyDown | NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown
        | NSEventMaskOtherMouseDown | NSEventMaskScrollWheel handler:^NSEvent*(NSEvent* event) {
        userInteracted = true;
        return event;
    }];
}

double monotonicMilliseconds()
{
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

bool isRosettaProcess()
{
#if defined(__x86_64__)
    static const bool translated = [] {
        int value = 0; size_t size = sizeof(value);
        return sysctlbyname("sysctl.proc_translated", &value, &size, nullptr, 0) == 0 && value == 1;
    }();
    return translated;
#else
    return false;
#endif
}

constexpr std::size_t maximumPNGBytes = 12 * 1024 * 1024;
constexpr std::size_t maximumProtocolBytes = 4096;
std::atomic<bool> workerCleanupFailed {false};
std::atomic<bool> workerActive {false};

bool waitForFD(int fd, short events, double deadline)
{
    while (monotonicMilliseconds() < deadline)
    {
        pollfd descriptor {fd, events, 0};
        const int timeout = std::max(1, std::min(25, (int)(deadline - monotonicMilliseconds())));
        const int ready = poll(&descriptor, 1, timeout);
        if (ready > 0) return (descriptor.revents & (events | POLLHUP)) != 0;
        if (ready < 0 && errno != EINTR) return false;
    }
    return false;
}

bool readExactly(int fd, void* destination, std::size_t bytes, double deadline)
{
    auto* out = static_cast<unsigned char*>(destination);
    std::size_t position = 0;
    while (position < bytes)
    {
        if (!waitForFD(fd, POLLIN, deadline)) return false;
        const auto count = read(fd, out + position, bytes - position);
        if (count > 0) position += (std::size_t)count;
        else if (count == 0 || (errno != EINTR && errno != EAGAIN)) return false;
    }
    return true;
}

bool writeExactly(int fd, const void* source, std::size_t bytes, double deadline)
{
    const auto* data = static_cast<const unsigned char*>(source);
    std::size_t position = 0;
    while (position < bytes)
    {
        if (!waitForFD(fd, POLLOUT, deadline)) return false;
        const auto count = write(fd, data + position, bytes - position);
        if (count > 0) position += (std::size_t)count;
        else if (count == 0 || (errno != EINTR && errno != EAGAIN)) return false;
    }
    return true;
}

bool protocolNumber(id object)
{
    return [object isKindOfClass:NSNumber.class]
        && CFGetTypeID((__bridge CFTypeRef)object) != CFBooleanGetTypeID()
        && std::isfinite([(NSNumber*)object doubleValue]);
}

bool validRule(NSString* rule)
{
    return [rule isKindOfClass:NSString.class] && [@[@"", @"product_not_activated", @"product_not_registered",
        @"unlicensed_status", @"license_expired", @"trial_expired", @"demo_mode", @"no_valid_license", @"activation_form"] containsObject:rule];
}

bool validOCRDiagnostic(NSString* diagnostic)
{
    return [diagnostic isKindOfClass:NSString.class] && [@[@"ocr_matched", @"ocr_no_supported_status", @"ocr_no_text", @"uad_dsp_disabled",
        @"ocr_image_unavailable", @"ocr_time_budget_exceeded", @"ocr_recognition_failed",
        @"ocr_recognition_exception", @"ocr_text_limit"] containsObject:diagnostic];
}

struct OwnedOCRChild
{
    pid_t pid = -1;
    int input = -1, output = -1;
    int status = 0;
    bool exited = false;

    bool reap()
    {
        if (exited || pid <= 1) return exited;
        const pid_t found = waitpid(pid, &status, WNOHANG);
        if (found == pid) { exited = true; return true; }
        // If another component reaped it, ownership is gone. Do not signal a
        // PID which could now have been reused; reject the unverified result.
        if (found < 0 && errno == ECHILD) { exited = true; status = -1; return true; }
        return false;
    }

    ~OwnedOCRChild()
    {
        if (input >= 0) close(input);
        if (output >= 0) close(output);
        if (pid <= 1 || reap()) return;
        kill(pid, SIGTERM); // Only this still-owned, unreaped child.
        const double deadline = monotonicMilliseconds() + 150;
        bool killed = false;
        while (!reap() && monotonicMilliseconds() < deadline)
        {
            if (!killed) { kill(pid, SIGKILL); killed = true; }
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }
        if (!exited) workerCleanupFailed.store(true); // Never launch a second overdue child.
    }
};

ProbeResult recognizeInNativeWorker(NSImage* image, std::string_view productName, double sampledAt)
{
    ProbeResult result;
    result.sampledAtMilliseconds = sampledAt;
    result.diagnostic = "ocr_native_worker_failed";
    if (workerCleanupFailed.load()) { result.diagnostic = "ocr_native_worker_cleanup_failed"; return result; }
    if (workerActive.exchange(true)) return result;
    struct ActiveJob { ~ActiveJob() { workerActive.store(false); } } activeJob;
    const double captureTime = sampledAt > 0 ? sampledAt : monotonicMilliseconds();
    const double deadline = captureTime + ocrBudgetMilliseconds;
    if (!std::isfinite(captureTime) || captureTime > monotonicMilliseconds()) return result;
    if (monotonicMilliseconds() >= deadline) { result.diagnostic = "ocr_time_budget_exceeded"; return result; }
    if (productName.empty() || productName.size() > 1024 || productName.find('\0') != std::string_view::npos)
    { result.diagnostic = "ocr_native_worker_protocol_error"; return result; }
    CGImageRef cg = [image CGImageForProposedRect:nullptr context:nil hints:nil];
    if (cg == nullptr || CGImageGetWidth(cg) > 2048 || CGImageGetHeight(cg) > 2048
        || CGImageGetWidth(cg) * CGImageGetHeight(cg) > 2500000)
    { result.diagnostic = "ocr_image_unavailable"; return result; }
    NSBitmapImageRep* bitmap = [[NSBitmapImageRep alloc] initWithCGImage:cg];
    NSData* png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (png == nil || png.length == 0 || png.length > maximumPNGBytes) return result;
    NSString* product = [[NSString alloc] initWithBytes:productName.data() length:productName.size() encoding:NSUTF8StringEncoding];
    if (product == nil) return result;
    NSData* header = [NSJSONSerialization dataWithJSONObject:@{@"version": @1, @"product": product,
        @"pngBytes": @(png.length), @"sampledAtMilliseconds": @(captureTime)} options:0 error:nil];
    if (header == nil || header.length + 1 > maximumProtocolBytes) return result;
    NSMutableData* payload = [header mutableCopy];
    [payload appendBytes:"\n" length:1]; [payload appendData:png];
    if (monotonicMilliseconds() >= deadline) { result.diagnostic = "ocr_time_budget_exceeded"; return result; }

    int inPipe[2] {-1, -1}, outPipe[2] {-1, -1};
    if (pipe(inPipe) != 0) return result;
    if (pipe(outPipe) != 0) { close(inPipe[0]); close(inPipe[1]); return result; }
    bool descriptorsValid = true;
    for (int fd : {inPipe[0], inPipe[1], outPipe[0], outPipe[1]})
        descriptorsValid = fd > STDERR_FILENO && fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 && descriptorsValid;
    descriptorsValid = fcntl(inPipe[1], F_SETNOSIGPIPE, 1) == 0 && descriptorsValid;
    descriptorsValid = fcntl(inPipe[1], F_SETFL, O_NONBLOCK) == 0 && descriptorsValid;
    descriptorsValid = fcntl(outPipe[0], F_SETFL, O_NONBLOCK) == 0 && descriptorsValid;
    if (!descriptorsValid)
    { for (int fd : {inPipe[0], inPipe[1], outPipe[0], outPipe[1]}) close(fd); return result; }
    uint32_t executableSize = 1024;
    std::vector<char> executable(executableSize);
    if (_NSGetExecutablePath(executable.data(), &executableSize) != 0)
    {
        executable.resize(executableSize);
        if (_NSGetExecutablePath(executable.data(), &executableSize) != 0)
        { for (int fd : {inPipe[0], inPipe[1], outPipe[0], outPipe[1]}) close(fd); return result; }
    }
    posix_spawn_file_actions_t actions;
    if (posix_spawn_file_actions_init(&actions) != 0)
    { for (int fd : {inPipe[0], inPipe[1], outPipe[0], outPipe[1]}) close(fd); return result; }
    int actionError = 0;
    actionError |= posix_spawn_file_actions_adddup2(&actions, inPipe[0], STDIN_FILENO);
    actionError |= posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO);
    actionError |= posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    for (int fd : {inPipe[0], inPipe[1], outPipe[0], outPipe[1]})
        actionError |= posix_spawn_file_actions_addclose(&actions, fd);
    const std::string parent = std::to_string(getpid());
    char* args[] {const_cast<char*>("/usr/bin/arch"), const_cast<char*>("-arm64"), executable.data(),
        const_cast<char*>("--ocr-worker"), const_cast<char*>(parent.c_str()), nullptr};
    posix_spawnattr_t attributes;
    const int attributeError = posix_spawnattr_init(&attributes);
    if (attributeError == 0) actionError |= posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);
    OwnedOCRChild child;
    const int spawnError = actionError != 0 ? actionError : attributeError != 0 ? attributeError
        : posix_spawn(&child.pid, "/usr/bin/arch", &actions, &attributes, args, *_NSGetEnviron());
    if (spawnError != 0) child.pid = -1; // POSIX does not define the output PID on failure.
    if (attributeError == 0) posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    close(inPipe[0]); close(outPipe[1]);
    child.input = inPipe[1]; child.output = outPipe[0];
    if (spawnError != 0) return result;
    if (!writeExactly(child.input, payload.bytes, payload.length, deadline))
    { result.diagnostic = monotonicMilliseconds() >= deadline ? "ocr_time_budget_exceeded" : "ocr_native_worker_protocol_error"; return result; }
    close(child.input); child.input = -1;
    NSMutableData* response = [NSMutableData data];
    bool eof = false;
    while (monotonicMilliseconds() < deadline)
    {
        if (!eof && waitForFD(child.output, POLLIN, deadline))
        {
            unsigned char buffer[512];
            const auto bytes = read(child.output, buffer, sizeof(buffer));
            if (bytes > 0) [response appendBytes:buffer length:(NSUInteger)bytes];
            else if (bytes == 0) eof = true;
            else if (errno != EINTR && errno != EAGAIN) return result;
            if (response.length > maximumProtocolBytes) { result.diagnostic = "ocr_native_worker_protocol_error"; return result; }
        }
        if (child.reap() && eof) break;
        if (eof) std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    if (!child.reap() || monotonicMilliseconds() >= deadline)
    { result.diagnostic = "ocr_time_budget_exceeded"; return result; }
    if (!WIFEXITED(child.status) || WEXITSTATUS(child.status) != 0) return result;
    id object = [NSJSONSerialization JSONObjectWithData:response options:0 error:nil];
    if (![object isKindOfClass:NSDictionary.class]) { result.diagnostic = "ocr_native_worker_protocol_error"; return result; }
    NSDictionary* decoded = object;
    NSNumber* version = decoded[@"version"];
    NSNumber* count = decoded[@"staticTextNodes"];
    NSString* rule = decoded[@"rule"];
    NSString* diagnostic = decoded[@"diagnostic"];
    if (decoded.count != 4 || !protocolNumber(version) || version.doubleValue != 1
        || !protocolNumber(count) || count.doubleValue < 0 || count.doubleValue > 256
        || std::floor(count.doubleValue) != count.doubleValue || !validRule(rule) || !validOCRDiagnostic(diagnostic)
        || (rule.length > 0) != [diagnostic isEqualToString:@"ocr_matched"])
    { result.diagnostic = "ocr_native_worker_protocol_error"; return result; }
    result.rule = rule.UTF8String;
    result.diagnostic = diagnostic.UTF8String;
    result.staticTextNodes = (std::size_t)count.unsignedIntegerValue;
    result.contentObserved = result.staticTextNodes > 0
        && (result.diagnostic == "ocr_matched" || result.diagnostic == "ocr_no_supported_status");
    return result;
}

NSString* normalized(std::string_view input)
{
    // Avoid parsing large help paragraphs, pasted keys, or arbitrary documents.
    if (input.empty() || input.size() > 1024) return nil;
    NSString* text = [[NSString alloc] initWithBytes:input.data()
                                            length:input.size()
                                          encoding:NSUTF8StringEncoding];
   #if !__has_feature(objc_arc)
    [text autorelease];
   #endif
    if (text == nil || text.length > 256) return nil;
    text = [[text precomposedStringWithCompatibilityMapping] lowercaseString];
    text = [text stringByReplacingOccurrencesOfString:@"licence" withString:@"license"];
    NSArray* parts = [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray* words = [NSMutableArray arrayWithCapacity:parts.count];
    for (NSString* part in parts) if (part.length != 0) [words addObject:part];
    text = [words componentsJoinedByString:@" "];
    // A question (e.g. FAQ "License expired?") is deliberately not a status.
    while ([text hasSuffix:@"."] || [text hasSuffix:@"!"])
        text = [text substringToIndex:text.length - 1];
    return text;
}

std::string utf8(NSString* text)
{
    const auto* value = text.UTF8String;
    return value != nullptr ? std::string(value, [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) : std::string();
}

bool isOneOf(NSString* value, NSArray<NSString*>* candidates)
{
    return value != nil && [candidates containsObject:value];
}

bool inputRole(NSString* role)
{
    return isOneOf(role, @[NSAccessibilityTextFieldRole, NSAccessibilityTextAreaRole,
                          NSAccessibilityComboBoxRole, @"AXSecureTextField"]);
}

bool protectedObject(id object)
{
    return [object respondsToSelector:@selector(isAccessibilityProtectedContent)]
        && [object isAccessibilityProtectedContent];
}

struct Signals
{
    bool prompt = false, action = false, dismiss = false, help = false, licensed = false;
    bool activationRequired = false;
    bool uadDSPDisabled = false;
    std::size_t inputs = 0;
    std::string explicitRule;
    std::string messageRule;
};

void textSignals(Signals& signals, id candidate, std::string_view product, bool button = false)
{
    if (![candidate isKindOfClass:NSString.class] || [candidate length] > 1024) return;
    if (!button)
    {
        // Native alert message labels often contain a status sentence followed
        // by recovery instructions. Keep the first sentence as tentative only:
        // it additionally needs activation + dismissal controls in the same
        // scope, unlike a complete standalone status. Never search arbitrary
        // substrings in help paragraphs or retain their original text.
        const NSRange boundary = [candidate rangeOfCharacterFromSet:
            [NSCharacterSet characterSetWithCharactersInString:@".!\n"]];
        if (boundary.location != NSNotFound && boundary.location > 0 && boundary.location <= 256)
        {
            const auto rule = matchStatusText(utf8([candidate substringToIndex:boundary.location]), product);
            if (signals.messageRule.empty() && !rule.empty()) signals.messageRule = rule;
        }
    }
    if ([candidate length] > 256) return;
    NSString* text = normalized(utf8(candidate));
    if (text == nil) return;
    // A DSP plug-in's DISABLED button can mean missing hardware, driver,
    // resources, or a license. Preserve this obstruction without guessing
    // which one; it must not look like a successfully inspected normal editor.
    signals.uadDSPDisabled |= [normalized(product) hasPrefix:@"uad "] && [text isEqualToString:@"disabled"];
    if (button)
    {
        signals.action |= isOneOf(text, @[@"activate", @"activate license", @"activate licence", @"authorize", @"authorize now",
                                          @"register", @"unlock", @"認証", @"アクティベート", @"登録"]);
        signals.dismiss |= isOneOf(text, @[@"cancel", @"close", @"quit", @"continue demo", @"continue trial", @"キャンセル"]);
        return;
    }
    if ([text hasSuffix:@":"]) text = [text substringToIndex:text.length - 1];
    signals.activationRequired |= isOneOf(text, @[@"activation required", @"authorization required",
        @"license activation required", @"plug-in activation required"]);
    signals.prompt |= isOneOf(text, @[@"enter license key", @"enter your license key", @"please enter your license key",
        @"enter a license key", @"license key", @"enter serial number", @"enter your serial number", @"serial number",
        @"registration code", @"activation code", @"enter activation code", @"enter registration code",
        @"ライセンスキーを入力", @"ライセンスキー", @"シリアル番号"]);
    signals.help |= isOneOf(text, @[@"help", @"faq", @"frequently asked questions", @"activation help", @"license help",
                                   @"registration help", @"how to activate", @"ヘルプ", @"よくある質問"]);
    // Only a boolean survives this prefix check; any displayed license-holder
    // identity is neither extracted nor returned. It vetoes ambiguous demo
    // labels/key-change forms, but not an explicit expiration/failure sentence.
    signals.licensed |= [text hasPrefix:@"licensed to "] || [text hasPrefix:@"registered to "]
        || isOneOf(text, @[@"licensed to", @"registered to", @"license status: activated", @"license status: licensed",
                           @"license status: valid", @"registration status: registered"]);
    const auto rule = matchStatusText(utf8(candidate), product);
    if (signals.explicitRule.empty() && !rule.empty()) signals.explicitRule = rule;
}

std::string ruleFor(const Signals& signals, bool image = false)
{
    if (signals.help) return {};
    if (!signals.explicitRule.empty()) return signals.explicitRule;
    if (signals.licensed) return {};
    if (!signals.messageRule.empty() && signals.action && signals.dismiss)
        return signals.messageRule;
    // A license dialog can authorize through iLok/a browser and contain no
    // serial-number field. Require both an explicit requirement heading and
    // separate activate/dismiss actions; an editor's permanent Activate button
    // or a preset named "Activation Required" does not satisfy this rule.
    if (signals.activationRequired && signals.action && signals.dismiss)
        return "product_not_activated";
    // A bare state-like label may be a preset name even when exposed as AX
    // static text. It is never evidence, including beside a permanent Activate
    // button. Use a complete status phrase or the full form conjunction below.
    // A prompt or an Activate button alone is common in help and settings.
    // AX requires a real input control; pixels require an additional distinct
    // cancel/demo action because OCR cannot establish an input's semantic role.
    return signals.prompt && signals.action && (image ? signals.dismiss : signals.inputs > 0)
        ? "activation_form" : "";
}

bool blocksSubtree(id object, NSString* role)
{
    // Never descend into a text entry/control: some implementations expose the
    // typed contents as child static text. Its label/value/help is not read.
    if (isOneOf(role, @[NSAccessibilityTextFieldRole, NSAccessibilityTextAreaRole,
                       NSAccessibilityComboBoxRole, NSAccessibilityButtonRole,
                       NSAccessibilityPopUpButtonRole, NSAccessibilityMenuButtonRole,
                       NSAccessibilityMenuItemRole, NSAccessibilityMenuRole,
                       NSAccessibilitySliderRole, NSAccessibilityCheckBoxRole,
                       NSAccessibilityRadioButtonRole, NSAccessibilityLinkRole])) return true;
    if ([object isKindOfClass:NSTextView.class]) return true;
    if ([object isKindOfClass:NSTextField.class] && [(NSTextField*)object isEditable]) return true;
    if ([object respondsToSelector:@selector(isAccessibilityProtectedContent)]
        && [object isAccessibilityProtectedContent]) return true;
    // Don't traverse the accessibility bridge to an AUv3 extension or any other
    // remote process. Such plug-ins remain "unknown" unless their local UI
    // exposes a safe, explicit status label in this host process.
    return false;
}
}

std::string matchStatusText(std::string_view raw, std::string_view productName)
{
    @autoreleasepool
    {
        NSString* text = normalized(raw);
        if (text == nil) return {};
        NSString* product = normalized(productName);
        NSMutableArray<NSString*>* subjects = [NSMutableArray arrayWithArray:
            @[@"this product", @"this plugin", @"this plug-in", @"this software"]];
        if (product.length > 0) [subjects addObject:product];
        for (NSString* subject in subjects)
        {
            for (NSString* ending in @[@" is not activated", @" is not activated on this machine",
                                       @" is not activated on this computer", @" is not activated on this device",
                                       @" is not activated on this system"])
                if ([text isEqualToString:[subject stringByAppendingString:ending]]) return "product_not_activated";
            if ([text isEqualToString:[subject stringByAppendingString:@" is not registered"]]) return "product_not_registered";
            if ([text isEqualToString:[subject stringByAppendingString:@" is unregistered"]]) return "product_not_registered";
            if ([text isEqualToString:[subject stringByAppendingString:@" is unlicensed"]]) return "unlicensed_status";
            if ([text isEqualToString:[subject stringByAppendingString:@" is not licensed"]]) return "unlicensed_status";
            if ([text isEqualToString:[subject stringByAppendingString:@" is not authorized"]]) return "product_not_activated";
            if ([text isEqualToString:[subject stringByAppendingString:@" requires activation"]]) return "product_not_activated";
            for (NSString* ending in @[@" is running in demo mode", @" is running in trial mode",
                                       @" is in demo mode", @" is in trial mode",
                                       @" is running in evaluation mode"])
                if ([text isEqualToString:[subject stringByAppendingString:ending]]) return "demo_mode";
        }
        if (product.length > 0 && [text isEqualToString:[@"this is an unregistered version of " stringByAppendingString:product]])
            return "product_not_registered";
        // UA documents this exact native plug-in error. Restrict the short
        // heading to UADx product identity, not arbitrary preset/control text.
        // "Activate License" on its own is also a normal action, not evidence.
        if ([product hasPrefix:@"uadx "] && isOneOf(text, @[@"plug-in not licensed", @"plugin not licensed"]))
            return "unlicensed_status";
        if (isOneOf(text, @[@"license has expired", @"your license has expired", @"the license has expired",
                           @"your trial license has expired", @"the trial license has expired",
                           @"license expired", @"license status: expired"])) return "license_expired";
        if (isOneOf(text, @[@"registration status: not registered", @"license status: not registered"])) return "product_not_registered";
        if (isOneOf(text, @[@"registration status: unregistered", @"license status: unregistered"])) return "product_not_registered";
        if (isOneOf(text, @[@"license status: unlicensed", @"license status: not activated"])) return "unlicensed_status";
        if (isOneOf(text, @[@"trial expired", @"trial has expired", @"your trial has expired",
                           @"your trial period has expired", @"the trial period has expired",
                           @"trial period expired", @"evaluation period expired",
                           @"your evaluation period has expired", @"trial status: expired"])) return "trial_expired";
        if (isOneOf(text, @[@"license status: demo", @"license status: trial",
                           @"license status: evaluation", @"license mode: demo",
                           @"license mode: trial", @"registration status: demo"])) return "demo_mode";
        if (isOneOf(text, @[@"no valid license found", @"no valid license was found",
                           @"no valid license was found for this product"])) return "no_valid_license";
        if (isOneOf(text, @[@"この製品は認証されていません", @"このプラグインは認証されていません",
                           @"この製品はアクティベートされていません"])) return "product_not_activated";
        return {};
    }
}

ProbeResult inspectLocalRoots(NSArray* roots, std::string_view productName, Limits limits)
{
    ProbeResult result;
    if (![NSThread isMainThread] || limits.maxNodes == 0 || limits.maxMilliseconds <= 0) return result;
    result.sampledAtMilliseconds = monotonicMilliseconds();
    @autoreleasepool
    {
        using Clock = std::chrono::steady_clock;
        const auto deadline = Clock::now() + std::chrono::duration<double, std::milli>(limits.maxMilliseconds);
        const auto timedOut = [&] { return Clock::now() >= deadline; };
        struct Pending { id object; unsigned depth; std::size_t scope; };
        std::deque<Pending> pending;
        std::vector<Signals> scopes;
        std::unordered_set<const void*> visited;
        std::unordered_set<const void*> enqueued;
        NSMutableArray* retained = [NSMutableArray array];
        for (id root in roots)
        {
            if (pending.size() >= limits.maxNodes) break;
            if (!enqueued.insert((__bridge const void*)root).second) continue;
            [retained addObject:root];
            scopes.emplace_back();
            pending.push_back({root, 0, scopes.size() - 1});
        }
        while (!pending.empty())
        {
            if (timedOut() || result.visitedNodes >= limits.maxNodes)
            {
                result.budgetExhausted = true;
                break;
            }
            const auto current = pending.front();
            pending.pop_front();
            id object = current.object;
            if (object == nil || !visited.insert((__bridge const void*)object).second) continue;
            ++result.visitedNodes;
            @try
            {
                NSString* className = NSStringFromClass([object class]);
                if ([className rangeOfString:@"Remote" options:NSCaseInsensitiveSearch].location != NSNotFound) continue;
                if (![object respondsToSelector:@selector(accessibilityRole)]) continue;
                NSString* role = [object accessibilityRole];
                if (timedOut()) { result.budgetExhausted = true; break; }
                if ([object isKindOfClass:NSView.class] && [(NSView*)object isHiddenOrHasHiddenAncestor]) continue;
                if (protectedObject(object)) continue;
                auto& signals = scopes[current.scope];
                if (inputRole(role) || [object isKindOfClass:NSTextView.class]
                    || ([object isKindOfClass:NSTextField.class] && [(NSTextField*)object isEditable]))
                {
                    ++signals.inputs; // Existence only: no input properties/children.
                    continue;
                }
                if ([role isEqualToString:NSAccessibilityButtonRole])
                {
                    // Button labels identify an action; button values and
                    // descendants are never read, and labels alone are negative.
                    if ([object respondsToSelector:@selector(accessibilityTitle)])
                        textSignals(signals, [object accessibilityTitle], productName, true);
                    if ([object respondsToSelector:@selector(accessibilityLabel)])
                        textSignals(signals, [object accessibilityLabel], productName, true);
                    continue;
                }
                if (blocksSubtree(object, role)) continue;
                if (timedOut()) { result.budgetExhausted = true; break; }
                if ([role isEqualToString:NSAccessibilityStaticTextRole])
                {
                    bool readableText = false;
                    // Text is transient and never returned/logged. Only read
                    // values of static, unprotected text, never input values.
                    for (SEL selector : {@selector(accessibilityTitle), @selector(accessibilityLabel), @selector(accessibilityValue)})
                    {
                        if (timedOut()) { result.budgetExhausted = true; break; }
                        if (![object respondsToSelector:selector]) continue;
                        id candidate = nil;
                        if (selector == @selector(accessibilityTitle)) candidate = [object accessibilityTitle];
                        else if (selector == @selector(accessibilityLabel)) candidate = [object accessibilityLabel];
                        else candidate = [object accessibilityValue];
                        if (timedOut()) { result.budgetExhausted = true; break; }
                        if ([candidate isKindOfClass:NSString.class] && [candidate length] <= 256)
                            readableText |= normalized(utf8(candidate)).length > 0;
                        textSignals(signals, candidate, productName);
                    }
                    if (readableText) ++result.staticTextNodes;
                }
                if (current.depth >= limits.maxDepth) { result.budgetExhausted = true; continue; }
                if (timedOut()) { result.budgetExhausted = true; break; }
                if (![object respondsToSelector:@selector(accessibilityChildren)]) continue;
                id children = [object accessibilityChildren];
                if (timedOut()) { result.budgetExhausted = true; break; }
                if (![children isKindOfClass:NSArray.class]) continue;
                const auto remaining = limits.maxNodes - result.visitedNodes;
                for (id child in (NSArray*)children)
                {
                    if (pending.size() >= remaining) { result.budgetExhausted = true; break; }
                    if (!enqueued.insert((__bridge const void*)child).second) continue;
                    [retained addObject:child];
                    pending.push_back({child, current.depth + 1, current.scope});
                }
            }
            @catch (NSException* exception)
            {
                (void)exception;
                result.budgetExhausted = true;
                // A vendor's accessibility implementation is optional. Failure
                // leaves the result unknown and never exposes exception/UI text.
            }
        }
        if (!result.budgetExhausted)
            for (const auto& signals : scopes)
                if (auto rule = ruleFor(signals); !rule.empty()) { result.rule = rule; break; }
        result.contentObserved = !result.budgetExhausted && result.staticTextNodes > 0;
        result.diagnostic = !result.rule.empty() ? "ax_matched"
            : result.budgetExhausted ? "ax_incomplete" : "ax_no_supported_status";
        if (result.rule.empty())
            for (const auto& signals : scopes)
                if (signals.uadDSPDisabled)
                {
                    result.diagnostic = "uad_dsp_disabled";
                    result.contentObserved = false;
                    break;
                }
    }
    return result;
}

NSImage* renderMaskedLocalView(NSView* view, ProbeResult& result)
{
    if (![NSThread isMainThread] || view == nil) { result.diagnostic = "ocr_wrong_thread_or_view"; return nil; }
    if (view.isHiddenOrHasHiddenAncestor) { result.diagnostic = "ocr_hidden_view"; return nil; }
    @autoreleasepool
    {
        const auto started = monotonicMilliseconds();
        const NSRect bounds = view.bounds;
        if (!std::isfinite(bounds.size.width) || !std::isfinite(bounds.size.height)
            || bounds.origin.x != 0 || bounds.origin.y != 0
            || bounds.size.width < 32 || bounds.size.height < 16
            || bounds.size.width > 2048 || bounds.size.height > 2048
            || bounds.size.width * bounds.size.height > 2500000)
        { result.diagnostic = "ocr_view_size_limit"; return nil; }
        NSMutableArray<NSValue*>* masks = [NSMutableArray array];
        NSMutableArray* retained = [NSMutableArray arrayWithObject:view];
        struct Node { id object; unsigned depth; bool native; };
        std::deque<Node> pending {{view, 0, true}, {view, 0, false}};
        std::unordered_set<const void*> nativeSeen, axSeen;
        std::size_t nodes = 0;
        @try
        {
            while (!pending.empty())
            {
                if (++nodes > 2048 || monotonicMilliseconds() - started > 20)
                { result.diagnostic = "ocr_mask_budget_exhausted"; return nil; }
                const auto node = pending.front(); pending.pop_front();
                id object = node.object;
                auto& seen = node.native ? nativeSeen : axSeen;
                if (!seen.insert((__bridge const void*)object).second) continue;
                if (node.depth > 32) { result.diagnostic = "ocr_mask_depth_limit"; return nil; }
                if ([NSStringFromClass([object class]) rangeOfString:@"Remote" options:NSCaseInsensitiveSearch].location != NSNotFound)
                { result.diagnostic = "ocr_remote_content"; return nil; }
                NSView* native = [object isKindOfClass:NSView.class] ? (NSView*)object : nil;
                if (native != nil && native.isHiddenOrHasHiddenAncestor) continue;
                NSString* role = [object respondsToSelector:@selector(accessibilityRole)] ? [object accessibilityRole] : nil;
                const bool isProtected = protectedObject(object);
                const bool isInput = inputRole(role) || [object isKindOfClass:NSTextView.class]
                    || ([object isKindOfClass:NSTextField.class] && [(NSTextField*)object isEditable]);
                bool nonActivationControl = false;
                if (!isProtected && !isInput && [role isEqualToString:NSAccessibilityButtonRole])
                {
                    Signals labels;
                    if ([object respondsToSelector:@selector(accessibilityTitle)])
                        textSignals(labels, [object accessibilityTitle], {}, true);
                    if ([object respondsToSelector:@selector(accessibilityLabel)])
                        textSignals(labels, [object accessibilityLabel], {}, true);
                    nonActivationControl = !labels.action && !labels.dismiss;
                }
                else nonActivationControl = isOneOf(role, @[NSAccessibilityPopUpButtonRole, NSAccessibilityMenuButtonRole,
                    NSAccessibilityMenuItemRole, NSAccessibilityMenuRole, NSAccessibilitySliderRole,
                    NSAccessibilityCheckBoxRole, NSAccessibilityRadioButtonRole, NSAccessibilityLinkRole]);
                const bool mask = isProtected || isInput || nonActivationControl;
                if (mask)
                {
                    NSRect rectangle = NSZeroRect;
                    if (native != nil)
                        rectangle = [view convertRect:native.bounds fromView:native];
                    else if (view.window != nil && [object respondsToSelector:@selector(accessibilityFrame)])
                    {
                        const NSRect frame = [object accessibilityFrame];
                        if (NSIsEmptyRect(frame)) { result.diagnostic = "ocr_input_geometry_missing"; return nil; }
                        rectangle = [view convertRect:[view.window convertRectFromScreen:frame] fromView:nil];
                    }
                    else { result.diagnostic = "ocr_input_geometry_missing"; return nil; }
                    if (!std::isfinite(rectangle.origin.x) || !std::isfinite(rectangle.origin.y)
                        || !std::isfinite(rectangle.size.width) || !std::isfinite(rectangle.size.height))
                    { result.diagnostic = "ocr_input_geometry_invalid"; return nil; }
                    rectangle = NSIntersectionRect(bounds, NSInsetRect(rectangle, -3, -3));
                    if (!NSIsEmptyRect(rectangle)) [masks addObject:[NSValue valueWithRect:rectangle]];
                    continue; // No input value, label, title, or child access.
                }
                id children = node.native && native != nil ? native.subviews
                    : [object respondsToSelector:@selector(accessibilityChildren)] ? [object accessibilityChildren] : nil;
                if ([children isKindOfClass:NSArray.class])
                    for (id child in (NSArray*)children)
                    {
                        if (pending.size() >= 2048) { result.diagnostic = "ocr_mask_budget_exhausted"; return nil; }
                        [retained addObject:child]; pending.push_back({child, node.depth + 1, node.native});
                    }
            }
            // A caller may change a view's geometry while arranging subviews.
            // Drawing and privacy inspection stay on the same main-thread turn.
            NSBitmapImageRep* bitmap = [[NSBitmapImageRep alloc]
                initWithBitmapDataPlanes:nullptr pixelsWide:(NSInteger)std::ceil(bounds.size.width)
                pixelsHigh:(NSInteger)std::ceil(bounds.size.height) bitsPerSample:8 samplesPerPixel:4
                hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
            if (bitmap == nil) { result.diagnostic = "ocr_bitmap_unavailable"; return nil; }
            bitmap.size = bounds.size;
            NSGraphicsContext* context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
            if (context == nil) { result.diagnostic = "ocr_bitmap_unavailable"; return nil; }
            const auto bitmapRect = [&](NSRect rectangle) {
                if (view.isFlipped) rectangle.origin.y = bounds.size.height - NSMaxY(rectangle);
                return rectangle;
            };
            [NSGraphicsContext saveGraphicsState];
            @try
            {
                [NSGraphicsContext setCurrentContext:context];
                [[NSColor whiteColor] setFill]; NSRectFill(bounds);
                CGContextRef cg = context.CGContext;
                CGContextSaveGState(cg);
                // Apply each exclusion separately. Intersecting clip paths
                // remain masked even when input rectangles overlap/duplicate.
                for (NSValue* mask in masks)
                {
                    CGContextBeginPath(cg); CGContextAddRect(cg, bounds);
                    CGContextAddRect(cg, bitmapRect(mask.rectValue)); CGContextEOClip(cg);
                }
                [view displayRectIgnoringOpacity:bounds inContext:context];
                CGContextRestoreGState(cg);
                // Defensive sanitization before the bitmap enters Vision, even
                // if a custom renderer disregards the inherited drawing clip.
                [[NSColor whiteColor] setFill];
                for (NSValue* mask in masks) NSRectFill(bitmapRect(mask.rectValue));
            }
            @finally { [NSGraphicsContext restoreGraphicsState]; }
            result.maskedRegions = masks.count;
            result.sampledAtMilliseconds = monotonicMilliseconds();
            result.diagnostic = "ocr_rendered_local_view";
            NSImage* image = [[NSImage alloc] initWithSize:bounds.size];
            [image addRepresentation:bitmap];
            return image;
        }
        @catch (NSException*) { result.diagnostic = "ocr_render_exception"; return nil; }
    }
}

static ProbeResult recognizeImageWithBudget(NSImage* image, std::string_view productName, double sampledAt, double budgetMilliseconds)
{
    ProbeResult result;
    result.sampledAtMilliseconds = sampledAt;
    result.diagnostic = "ocr_no_supported_status";
    const double started = sampledAt > 0 ? sampledAt : monotonicMilliseconds();
    @autoreleasepool
    {
        @try
        {
            CGImageRef cg = [image CGImageForProposedRect:nullptr context:nil hints:nil];
            if (cg == nullptr) { result.diagnostic = "ocr_image_unavailable"; return result; }
#ifdef PLUGIN_AUTH_PROBE_DIAGNOSTICS
            VNRecognizeTextRequest* request = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest*, NSError* completionError) {
                fprintf(stderr, "Vision completion NSError domain=%s code=%ld\n", completionError.domain.UTF8String ?: "", (long)completionError.code);
            }];
#else
            VNRecognizeTextRequest* request = [VNRecognizeTextRequest new];
#endif
            // The fast recognizer traps inside Vision on the tested macOS
            // version. Keep accurate recognition and bound/cancel its work.
            request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
            request.usesLanguageCorrection = NO;
            request.minimumTextHeight = 0.008;
            request.recognitionLanguages = @[@"en-US"];
            VNImageRequestHandler* handler = [[VNImageRequestHandler alloc] initWithCGImage:cg options:@{}];
#ifdef PLUGIN_AUTH_PROBE_DIAGNOSTICS
            fprintf(stderr, "Vision objects request=%d handler=%d width=%zu height=%zu revision=%lu\n",
                request != nil, handler != nil, CGImageGetWidth(cg), CGImageGetHeight(cg), (unsigned long)request.revision);
#endif
            const double remaining = budgetMilliseconds - (monotonicMilliseconds() - started);
            if (remaining <= 0) { result.diagnostic = "ocr_time_budget_exceeded"; return result; }
            __weak VNRecognizeTextRequest* cancellable = request;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_MSEC)),
                dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [cancellable cancel]; });
            NSError* error = nil;
            if (![handler performRequests:@[request] error:&error])
            {
#ifdef PLUGIN_AUTH_PROBE_DIAGNOSTICS
                // Isolated fixture diagnostics: never emit localized errors,
                // recognized text, image data, or user/plugin content.
                fprintf(stderr, "Vision NSError domain=%s code=%ld\n", error.domain.UTF8String ?: "", (long)error.code);
                fprintf(stderr, "Vision results present=%d count=%lu\n", request.results != nil, (unsigned long)request.results.count);
#endif
                result.diagnostic = error.code == VNErrorRequestCancelled ? "ocr_time_budget_exceeded" : "ocr_recognition_failed";
                return result;
            }
            if (monotonicMilliseconds() - started > budgetMilliseconds)
            { result.diagnostic = "ocr_time_budget_exceeded"; return result; }
            NSArray<VNRecognizedTextObservation*>* observations = request.results;
            if (observations.count > 256) { result.diagnostic = "ocr_text_limit"; return result; }
            Signals signals;
            struct OCRLine { NSString* text; CGRect bounds; };
            std::vector<OCRLine> lines;
            // Inspect the entire bounded result set before accepting a match.
            // A help/FAQ heading later in the set must still veto an earlier hit.
            for (VNRecognizedTextObservation* observation in observations)
            {
                VNRecognizedText* text = [observation topCandidates:1].firstObject;
                if (text.confidence < 0.8 || text.string.length > 256) continue;
                ++result.staticTextNodes;
                textSignals(signals, text.string, productName);
                textSignals(signals, text.string, productName, true);
                lines.push_back({text.string, observation.boundingBox});
            }
            // Vision returns wrapped paragraphs as separate observations. Join
            // only short, consecutive, left-aligned lines in the same column;
            // never combine arbitrary text from opposite parts of an editor.
            // Status matching still requires a complete fixed phrase. A
            // question/help prefix remains part of the phrase and cannot match.
            std::stable_sort(lines.begin(), lines.end(), [](const auto& a, const auto& b) {
                return CGRectGetMidY(a.bounds) > CGRectGetMidY(b.bounds);
            });
            for (std::size_t start = 0; start < lines.size(); ++start)
            {
                NSString* joined = lines[start].text;
                for (std::size_t end = start + 1; end < lines.size() && end < start + 3; ++end)
                {
                    const auto& previous = lines[end - 1].bounds;
                    const auto& next = lines[end].bounds;
                    const double height = std::max(previous.size.height, next.size.height);
                    const double gap = CGRectGetMinY(previous) - CGRectGetMaxY(next);
                    if (height <= 0 || gap < -height * 0.25 || gap > height * 1.6
                        || std::abs(previous.origin.x - next.origin.x) > height * 1.2) break;
                    joined = [joined stringByAppendingFormat:@" %@", lines[end].text];
                    if (joined.length > 256) break;
                    textSignals(signals, joined, productName);
                }
            }
            result.rule = ruleFor(signals, true);
            result.contentObserved = result.staticTextNodes > 0;
            if (!result.rule.empty()) result.diagnostic = "ocr_matched";
            else if (signals.uadDSPDisabled)
            { result.diagnostic = "uad_dsp_disabled"; result.contentObserved = false; }
            else if (!result.contentObserved) result.diagnostic = "ocr_no_text";
        }
        @catch (NSException*) { result.diagnostic = "ocr_recognition_exception"; }
    }
    return result;
}

ProbeResult recognizeLocalImage(NSImage* image, std::string_view productName, double sampledAt)
{
    // Vision must never share the vendor plug-in process. Some plug-ins change
    // process-wide rendering/runtime state, and a cancelled native Vision
    // request may never return. The owned child has a hard lifetime bound and
    // is reaped before another sample starts, on both arm64 and Rosetta hosts.
    return recognizeInNativeWorker(image, productName, sampledAt);
}

int runNativeOCRWarmup(int expectedParentPID)
{
    if (expectedParentPID <= 1 || getppid() != expectedParentPID || isRosettaProcess()) return 2;
    constexpr double warmupBudgetMilliseconds = 60000.0;
    const double started = monotonicMilliseconds();
    const double deadline = started + warmupBudgetMilliseconds;
    std::atomic<bool> finished {false};
    std::thread watchdog([&] {
        while (!finished.load())
        {
            if (getppid() != expectedParentPID) _exit(72);
            if (monotonicMilliseconds() >= deadline) _exit(74);
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
    });
    struct FinishWatchdog {
        std::atomic<bool>& finished; std::thread& thread;
        ~FinishWatchdog() { finished.store(true); thread.join(); }
    } finishWatchdog {finished, watchdog};
    @autoreleasepool
    {
        @try
        {
            // These fixed pixels initialize both text detection and recognition.
            // No window, screen, plug-in, user-provided image, or stdin is read.
            NSBitmapImageRep* bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr
                pixelsWide:960 pixelsHigh:240 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
                isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
            if (bitmap == nil) return 70;
            NSGraphicsContext* context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
            if (context == nil) return 70;
            [NSGraphicsContext saveGraphicsState];
            @try
            {
                [NSGraphicsContext setCurrentContext:context];
                [NSColor.whiteColor setFill]; NSRectFill(NSMakeRect(0, 0, 960, 240));
                NSDictionary* attributes = @{NSFontAttributeName: [NSFont systemFontOfSize:32],
                    NSForegroundColorAttributeName: NSColor.blackColor};
                [@"Image recognition preparation" drawAtPoint:NSMakePoint(24, 150) withAttributes:attributes];
                [@"Output Gain Frequency" drawAtPoint:NSMakePoint(24, 90) withAttributes:attributes];
            }
            @finally { [NSGraphicsContext restoreGraphicsState]; }
            NSImage* image = [[NSImage alloc] initWithSize:NSMakeSize(960, 240)];
            [image addRepresentation:bitmap];
            const auto result = recognizeImageWithBudget(image, "Synthetic preparation", started, warmupBudgetMilliseconds);
            if (getppid() != expectedParentPID) return 72;
            if (monotonicMilliseconds() >= deadline || result.diagnostic == "ocr_time_budget_exceeded") return 74;
            if (result.diagnostic != "ocr_no_supported_status" || !result.rule.empty() || result.staticTextNodes == 0) return 70;
            if (fcntl(STDOUT_FILENO, F_SETFL, O_NONBLOCK) != 0
                || fcntl(STDOUT_FILENO, F_SETNOSIGPIPE, 1) != 0) return 2;
            static const char response[] = "{\"version\":1,\"ready\":true}";
            return writeExactly(STDOUT_FILENO, response, sizeof(response) - 1, deadline) ? 0 : 70;
        }
        @catch (NSException*) { return 70; }
    }
}

void configureNativeOCRWorker()
{
    // Do not instantiate NSApplication here. This only changes the presentation
    // of the already-created worker application, and is never called off-main.
    if (NSThread.isMainThread && NSApp != nil) [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
}

int runNativeOCRWorker(int expectedParentPID)
{
    // This entry never initializes a plug-in, opens a window or captures a view.
    // The only image it can inspect is the already-masked anonymous-pipe frame.
    if (expectedParentPID <= 1 || getppid() != expectedParentPID || isRosettaProcess()) return 2;
    std::atomic<bool> finished {false};
    std::atomic<double> deadline {monotonicMilliseconds() + ocrBudgetMilliseconds};
    std::thread watchdog([&] {
        while (!finished.load())
        {
            if (getppid() != expectedParentPID) _exit(72);
            if (monotonicMilliseconds() >= deadline.load()) _exit(74);
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
    });
    struct FinishWatchdog {
        std::atomic<bool>& finished; std::thread& thread;
        ~FinishWatchdog() { finished.store(true); thread.join(); }
    } finishWatchdog {finished, watchdog};
    auto inputFailure = [&] { return monotonicMilliseconds() >= deadline.load() ? 74 : 2; };
    @autoreleasepool
    {
        @try
        {
            // Nonblocking I/O makes the absolute deadline apply even if the
            // sender never finishes a frame or never drains the response.
            if (fcntl(STDIN_FILENO, F_SETFL, O_NONBLOCK) != 0
                || fcntl(STDOUT_FILENO, F_SETFL, O_NONBLOCK) != 0
                || fcntl(STDOUT_FILENO, F_SETNOSIGPIPE, 1) != 0) return 2;
            NSMutableData* header = [NSMutableData data];
            bool terminated = false;
            for (std::size_t i = 0; i < maximumProtocolBytes; ++i)
            {
                unsigned char byte = 0;
                if (!readExactly(STDIN_FILENO, &byte, 1, deadline.load())) return inputFailure();
                if (byte == '\n') { terminated = true; break; }
                [header appendBytes:&byte length:1];
            }
            if (!terminated) return 2;
            id object = [NSJSONSerialization JSONObjectWithData:header options:0 error:nil];
            if (![object isKindOfClass:NSDictionary.class]) return 2;
            NSDictionary* decoded = object;
            NSNumber* version = decoded[@"version"];
            NSNumber* size = decoded[@"pngBytes"];
            NSNumber* capture = decoded[@"sampledAtMilliseconds"];
            NSString* product = decoded[@"product"];
            if (decoded.count != 4 || !protocolNumber(version) || version.doubleValue != 1
                || !protocolNumber(size) || size.doubleValue < 1 || size.doubleValue > maximumPNGBytes
                || std::floor(size.doubleValue) != size.doubleValue || !protocolNumber(capture)
                || ![product isKindOfClass:NSString.class]) return 2;
            NSData* productBytes = [product dataUsingEncoding:NSUTF8StringEncoding];
            const double sampledAt = capture.doubleValue;
            const double age = monotonicMilliseconds() - sampledAt;
            if (productBytes.length == 0 || productBytes.length > 1024
                || memchr(productBytes.bytes, 0, productBytes.length) != nullptr
                || sampledAt <= 0 || age < 0 || age > 8000) return 2;
            deadline.store(std::min(deadline.load(), sampledAt + ocrBudgetMilliseconds));
            if (monotonicMilliseconds() >= deadline.load()) return 74;
            NSMutableData* png = [NSMutableData dataWithLength:size.unsignedIntegerValue];
            if (!readExactly(STDIN_FILENO, png.mutableBytes, png.length, deadline.load())) return inputFailure();
            // Exact framing requires EOF. Extra bytes cannot become another job.
            if (!waitForFD(STDIN_FILENO, POLLIN, deadline.load())) return inputFailure();
            unsigned char extra = 0;
            if (read(STDIN_FILENO, &extra, 1) != 0) return 2;
            static const unsigned char signature[] {137, 80, 78, 71, 13, 10, 26, 10};
            if (png.length < sizeof(signature) || memcmp(png.bytes, signature, sizeof(signature)) != 0) return 2;
            CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)png,
                (__bridge CFDictionaryRef)@{(__bridge NSString*)kCGImageSourceShouldCache: @NO});
            if (source == nullptr) return 2;
            struct SourceOwner { CGImageSourceRef source; ~SourceOwner() { CFRelease(source); } } sourceOwner {source};
            CFStringRef type = CGImageSourceGetType(source);
            if (type == nullptr || !CFEqual(type, CFSTR("public.png")) || CGImageSourceGetCount(source) != 1) return 2;
            NSDictionary* properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr));
            NSNumber* width = properties[(__bridge NSString*)kCGImagePropertyPixelWidth];
            NSNumber* height = properties[(__bridge NSString*)kCGImagePropertyPixelHeight];
            if (!protocolNumber(width) || !protocolNumber(height)
                || width.doubleValue < 1 || height.doubleValue < 1
                || width.doubleValue > 2048 || height.doubleValue > 2048
                || std::floor(width.doubleValue) != width.doubleValue || std::floor(height.doubleValue) != height.doubleValue
                || width.doubleValue * height.doubleValue > 2500000) return 2;
            if (monotonicMilliseconds() >= deadline.load()) return 74;
            CGImageRef cg = CGImageSourceCreateImageAtIndex(source, 0,
                (__bridge CFDictionaryRef)@{(__bridge NSString*)kCGImageSourceShouldCache: @NO});
            if (cg == nullptr) return 2;
            NSImage* image = [[NSImage alloc] initWithCGImage:cg size:NSMakeSize(width.doubleValue, height.doubleValue)];
            CGImageRelease(cg);
            if (image == nil) return 2;
            const std::string productName(static_cast<const char*>(productBytes.bytes), productBytes.length);
            // Already in the isolated native process: do not spawn recursively.
            const ProbeResult result = recognizeImageWithBudget(image, productName, sampledAt, ocrBudgetMilliseconds);
            NSString* rule = [NSString stringWithUTF8String:result.rule.c_str()];
            NSString* diagnostic = [NSString stringWithUTF8String:result.diagnostic.c_str()];
            if (!validRule(rule) || !validOCRDiagnostic(diagnostic) || result.staticTextNodes > 256
                || (rule.length > 0) != [diagnostic isEqualToString:@"ocr_matched"]) return 2;
            if (getppid() != expectedParentPID) return 72;
            if (monotonicMilliseconds() >= deadline.load()) return 74;
            NSData* response = [NSJSONSerialization dataWithJSONObject:@{@"version": @1,
                @"rule": rule, @"diagnostic": diagnostic, @"staticTextNodes": @(result.staticTextNodes)} options:0 error:nil];
            if (response == nil || response.length > maximumProtocolBytes) return 2;
            return writeExactly(STDOUT_FILENO, response.bytes, response.length, deadline.load()) ? 0 : inputFailure();
        }
        @catch (NSException*) { return 2; }
    }
}

std::size_t preferredOCRSourceIndex(NSArray* sources, id positiveSource, std::size_t roundRobinIndex)
{
    if (sources.count == 0) return 0;
    const NSUInteger preferred = positiveSource == nil ? NSNotFound : [sources indexOfObjectIdenticalTo:positiveSource];
    return preferred != NSNotFound ? preferred : roundRobinIndex % sources.count;
}

ProbeResult inspectOwnVisibleWindows(std::string_view productName, Limits limits, bool allowOCR)
{
    if (![NSThread isMainThread] || NSApp == nil) return {};
    @autoreleasepool
    {
        NSMutableArray* roots = [NSMutableArray array];
        for (NSWindow* window in NSApp.windows)
            if (roots.count < 16 && window.isVisible && !window.isMiniaturized && ![window isKindOfClass:NSSavePanel.class])
                [roots addObject:window];
        auto native = inspectLocalRoots(roots, productName, limits);
        if (!allowOCR || !native.rule.empty()) return native;
        const bool uadDSPDisabled = native.diagnostic == "uad_dsp_disabled";
        // When the scan needs the rendered fallback, partial AX labels are not
        // a substitute for that observation (for example the host's heading
        // around an otherwise blank GPU editor). Only a consumed OCR result
        // can mark this fallback attempt as readable.
        native.contentObserved = false;
        monitorScanInteraction();
        if (userInteracted) { native.diagnostic = "ocr_user_interaction"; return native; }
        static PADLicenseOCRState* state = [PADLicenseOCRState new];
        NSString* product = [NSString stringWithUTF8String:std::string(productName).c_str()];
        ProbeResult completed;
        bool hasCompleted = false;
        if (state.ready)
        {
            state.ready = NO;
            NSView* source = state.view;
            if (source != nil && state.window != nil && source.window == state.window
                && source == state.window.contentView && state.window.isVisible
                && NSEqualRects(source.bounds, state.bounds) && [state.product isEqualToString:product]
                && monotonicMilliseconds() - state->result.sampledAtMilliseconds <= 8000)
            {
                completed = state->result; hasCompleted = true;
                state.preferredWindow = !completed.rule.empty() ? state.window : nil;
            }
            else state.preferredWindow = nil;
        }
        if (state.busy && monotonicMilliseconds() - state.capturedAt > ocrBudgetMilliseconds)
        {
            // Cancellation is cooperative. Never launch more jobs while an
            // overdue Vision request is still returning, or report it pending
            // indefinitely. Late results are rejected by the worker as well.
            native.diagnostic = "ocr_time_budget_exceeded";
            return native;
        }
        const bool intervalWait = roots.count > 0 && monotonicMilliseconds() - state.capturedAt < ocrSampleIntervalMilliseconds;
        if (!state.busy && !intervalWait)
        {
            // One image/job at a time. Once a dialog supplies a positive
            // observation, redraw that same live source for confirmation.
            // Interleaving an unrelated normal editor's negative image would
            // otherwise reset the host's candidate forever. Each observation
            // still requires a new capture and its original capture timestamp.
            static std::size_t nextWindow = 0;
            const auto firstWindow = preferredOCRSourceIndex(roots, state.preferredWindow, nextWindow);
            for (NSUInteger attempt = 0; attempt < roots.count; ++attempt)
            {
                const auto sourceIndex = (firstWindow + attempt) % roots.count;
                NSWindow* window = roots[sourceIndex];
                ProbeResult capture;
                NSView* content = window.contentView;
                NSImage* image = renderMaskedLocalView(content, capture);
                if (image == nil) { native.diagnostic = capture.diagnostic; continue; }
                state.view = content; state.window = window; state.bounds = content.bounds;
                state.product = product; state.busy = YES; state.capturedAt = capture.sampledAtMilliseconds;
                nextWindow = (sourceIndex + 1) % roots.count;
                const std::string copiedProduct(productName);
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    auto recognized = recognizeLocalImage(image, copiedProduct, capture.sampledAtMilliseconds);
                    recognized.maskedRegions = capture.maskedRegions;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        state->result = recognized; state.ready = YES; state.busy = NO;
                    });
                });
                break;
            }
        }
        if (hasCompleted)
        {
            // Explicit license evidence has priority over the ambiguous DSP
            // status. Otherwise a disabled editor is never a clean inspection,
            // even if another part of its rendered UI contains readable text.
            if (completed.rule.empty() && uadDSPDisabled)
            { completed.diagnostic = "uad_dsp_disabled"; completed.contentObserved = false; }
            return completed; // Consume a captured observation once.
        }
        native.pending = state.busy || intervalWait;
        if (native.pending) { native.sampledAtMilliseconds = 0; native.diagnostic = state.busy ? "ocr_pending" : "ocr_sampling_interval"; }
        return native;
    }
}

void configureBackgroundScan()
{
    if (![NSThread isMainThread] || NSApp == nil) return;
    monitorScanInteraction(); // Before a plug-in can present or accept UI input.
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
}

void orderScanWindowBehind(void* nativeView)
{
    if (![NSThread isMainThread] || nativeView == nullptr) return;
    NSView* view = (__bridge NSView*)nativeView;
    if (![view isKindOfClass:NSView.class]) return;
    NSWindow* window = view.window;
    if (window == nil) return;
    // JUCE setVisible orders the window without activation. Keep the passive
    // scan window behind normal work windows, without moving other apps or
    // changing their focus. A vendor may still present its own native dialog.
    [window orderBack:nil];
}
}
