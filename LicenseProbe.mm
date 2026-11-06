// SPDX-License-Identifier: AGPL-3.0-only
#import <AppKit/AppKit.h>
#include "LicenseProbe.h"
#include <algorithm>
#include <chrono>
#include <deque>
#include <unordered_set>

namespace PluginAuthLicense
{
namespace
{
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

std::string matchNSString(id candidate, std::string_view product)
{
    if (![candidate isKindOfClass:NSString.class]) return {};
    NSString* text = candidate;
    if (text.length == 0 || text.length > 256) return {};
    return matchStatusText(utf8(text), product);
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
            if ([text isEqualToString:[subject stringByAppendingString:@" is not authorized"]]) return "product_not_activated";
            for (NSString* ending in @[@" is running in demo mode", @" is running in trial mode",
                                       @" is in demo mode", @" is in trial mode",
                                       @" is running in evaluation mode"])
                if ([text isEqualToString:[subject stringByAppendingString:ending]]) return "demo_mode";
        }
        if (product.length > 0 && [text isEqualToString:[@"this is an unregistered version of " stringByAppendingString:product]])
            return "product_not_registered";
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
    @autoreleasepool
    {
        using Clock = std::chrono::steady_clock;
        const auto deadline = Clock::now() + std::chrono::duration<double, std::milli>(limits.maxMilliseconds);
        const auto timedOut = [&] { return Clock::now() >= deadline; };
        struct Pending { id object; unsigned depth; };
        std::deque<Pending> pending;
        std::unordered_set<const void*> visited;
        std::unordered_set<const void*> enqueued;
        NSMutableArray* retained = [NSMutableArray array];
        for (id root in roots)
        {
            if (pending.size() >= limits.maxNodes) break;
            if (!enqueued.insert((__bridge const void*)root).second) continue;
            [retained addObject:root];
            pending.push_back({root, 0});
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
                if (blocksSubtree(object, role)) continue;
                if ([object isKindOfClass:NSView.class] && [(NSView*)object isHiddenOrHasHiddenAncestor]) continue;
                if (timedOut()) { result.budgetExhausted = true; break; }
                if ([role isEqualToString:NSAccessibilityStaticTextRole])
                {
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
                        result.rule = matchNSString(candidate, productName);
                        if (!result.rule.empty()) return result;
                    }
                }
                if (current.depth >= limits.maxDepth) continue;
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
                    pending.push_back({child, current.depth + 1});
                }
            }
            @catch (NSException* exception)
            {
                (void)exception;
                // A vendor's accessibility implementation is optional. Failure
                // leaves the result unknown and never exposes exception/UI text.
            }
        }
    }
    return result;
}

ProbeResult inspectOwnVisibleWindows(std::string_view productName, Limits limits)
{
    if (![NSThread isMainThread] || NSApp == nil) return {};
    @autoreleasepool
    {
        NSMutableArray* roots = [NSMutableArray array];
        for (NSWindow* window in NSApp.windows)
        {
            if (roots.count >= 16) break;
            if (window.isVisible && !window.isMiniaturized && ![window isKindOfClass:NSSavePanel.class])
                [roots addObject:window];
        }
        return inspectLocalRoots(roots, productName, limits);
    }
}

void configureBackgroundScan()
{
    if (![NSThread isMainThread] || NSApp == nil) return;
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
