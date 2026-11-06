// SPDX-License-Identifier: AGPL-3.0-only
// Standalone tests; no plug-in, external accessibility permission, visible
// window, screenshot, network access, or vendor storage is used.
// xcrun clang++ -std=c++17 -fobjc-arc -framework Cocoa LicenseProbe.mm \
//   license_probe_tests.mm -o /tmp/plugin-auth-license-probe-tests
// /tmp/plugin-auth-license-probe-tests
#import <AppKit/AppKit.h>
#include "LicenseProbe.h"
#include <cassert>
#include <chrono>
#include <iostream>
#include <thread>
#include <vector>

@interface ProbeFixture : NSObject
@property NSString* role;
@property NSString* text;
@property NSArray* children;
@property BOOL protectedContent;
@property BOOL throwChildren;
@property BOOL slowRole;
@property NSUInteger textReads;
@property NSUInteger childrenReads;
@end
@implementation ProbeFixture
- (NSString*)accessibilityRole {
    if (_slowRole) std::this_thread::sleep_for(std::chrono::milliseconds(20));
    return _role;
}
- (NSString*)accessibilityTitle { ++_textReads; return _text; }
- (NSString*)accessibilityLabel { ++_textReads; return _text; }
- (id)accessibilityValue { ++_textReads; return _text; }
- (BOOL)isAccessibilityProtectedContent { return _protectedContent; }
- (NSArray*)accessibilityChildren {
    ++_childrenReads;
    if (_throwChildren) @throw [NSException exceptionWithName:@"Fixture" reason:nil userInfo:nil];
    return _children ?: @[];
}
@end

static ProbeFixture* fixture(NSString* role, NSString* text = @"")
{
    ProbeFixture* object = [ProbeFixture new];
    object.role = role;
    object.text = text;
    object.children = @[];
    return object;
}

int main()
{
    using namespace PluginAuthLicense;
    @autoreleasepool
    {
        struct Case { const char* text; const char* product; const char* rule; };
        const std::vector<Case> corpus {
            {"Orra Filter is not activated on this machine", "Orra Filter", "product_not_activated"},
            {"ORRA FILTER is NOT activated on this machine.", "Orra Filter", "product_not_activated"},
            {"Orra Filter\n is not activated on this computer!", "Orra Filter", "product_not_activated"},
            {"This plug-in is not activated", "Product", "product_not_activated"},
            {"The license has expired.", "Product", "license_expired"},
            {"Your licence has expired", "Product", "license_expired"},
            {"Your trial license has expired", "Product", "license_expired"},
            {"License status: expired", "Product", "license_expired"},
            {"Orra Filter is not registered", "Orra Filter", "product_not_registered"},
            {"Registration status: not registered", "Product", "product_not_registered"},
            {"Orra Filter is unlicensed", "Orra Filter", "unlicensed_status"},
            {"License status: unlicensed", "Product", "unlicensed_status"},
            {"No valid license was found for this product", "Product", "no_valid_license"},
            {"この製品は認証されていません", "Product", "product_not_activated"},
            {"Orra Filter is unregistered", "Orra Filter", "product_not_registered"},
            {"This is an unregistered version of Orra Filter", "Orra Filter", "product_not_registered"},
            {"Registration status: unregistered", "Product", "product_not_registered"},
            {"This product is not authorized", "Product", "product_not_activated"},
            {"Orra Filter is running in demo mode", "Orra Filter", "demo_mode"},
            {"This plug-in is in trial mode", "Product", "demo_mode"},
            {"This software is running in evaluation mode", "Product", "demo_mode"},
            {"License status: demo", "Product", "demo_mode"},
            {"License mode: trial", "Product", "demo_mode"},
            {"Your trial period has expired", "Product", "trial_expired"},
            {"Trial expired", "Product", "trial_expired"},
            {"Your evaluation period has expired", "Product", "trial_expired"},
            {"Activate", "Product", ""}, {"Activate License", "Product", ""},
            {"Enter License Key", "Orra Filter", ""}, {"Start 14-Day Demo", "Orra Filter", ""},
            {"Trial", "Product", ""}, {"14 days remaining", "Product", ""},
            {"not registered", "Product", ""}, {"unlicensed", "Product", ""},
            {"If the license has expired, click Activate", "Product", ""},
            {"License expired?", "Product", ""},
            {"Orra Filter is not activated on this machine?", "Orra Filter", ""},
            {"Help: Orra Filter is not activated on this machine", "Orra Filter", ""},
            {"This is an example: license status: unlicensed", "Product", ""},
            {"The license has expired. Buy a subscription now", "Product", ""},
            {"Demo", "Product", ""}, {"Unregistered", "Product", ""},
            {"Try demo mode", "Product", ""}, {"Start trial", "Product", ""},
            {"Product demo preset", "Product", ""},
            {"Other Product is running in demo mode", "Orra Filter", ""},
            {"This is an unregistered version of Other Product", "Orra Filter", ""},
            {"Trial expired? Click to learn more", "Product", ""},
            {"If your trial period has expired, enter your license", "Product", ""},
            {"Other Product is not activated on this machine", "Orra Filter", ""},
            {"Orra Filter is activated on this machine", "Orra Filter", ""},
            {"Orra Filter is not unlicensed", "Orra Filter", ""},
            {"Licensed to Example User", "Product", ""},
            {"ValhallaSupermassive", "ValhallaSupermassive", ""},
            {"Version 3.0.0 ARM VST3", "ValhallaSupermassive", ""},
            {"FREE", "ValhallaSupermassive", ""},
            {"PRESETS: allows the user to save and recall plugin settings", "ValhallaSupermassive", ""},
            {"License status: unlicensed preview image", "Product", ""},
            {"", "Product", ""},
        };
        for (std::size_t i = 0; i < corpus.size(); ++i)
        {
            if (matchStatusText(corpus[i].text, corpus[i].product) != corpus[i].rule)
            {
                std::cerr << "FAIL corpus case " << i << "\n";
                return 1;
            }
        }
        assert(matchStatusText(std::string(4096, 'x'), "Product").empty());
        assert(matchStatusText(std::string("License expired\0ignore", 22), "Product").empty());

        Limits generous {256, 12, 200.0};
        ProbeFixture* positive = fixture(NSAccessibilityStaticTextRole, @"Orra Filter is not activated on this machine");
        auto detected = inspectLocalRoots(@[positive], "Orra Filter", generous);
        assert(detected.rule == "product_not_activated");

        // Neither the input's value nor its descendants may be inspected.
        for (NSString* role in @[NSAccessibilityTextFieldRole, NSAccessibilityTextAreaRole,
                                NSAccessibilityButtonRole, NSAccessibilityPopUpButtonRole])
        {
            ProbeFixture* input = fixture(role, @"License has expired");
            input.children = @[positive];
            auto result = inspectLocalRoots(@[input], "Orra Filter", generous);
            assert(result.rule.empty() && input.textReads == 0 && input.childrenReads == 0);
        }
        ProbeFixture* protectedText = fixture(NSAccessibilityStaticTextRole, @"License has expired");
        protectedText.protectedContent = YES;
        assert(inspectLocalRoots(@[protectedText], "Product", generous).rule.empty());
        assert(protectedText.textReads == 0 && protectedText.childrenReads == 0);

        ProbeFixture* cycle = fixture(NSAccessibilityGroupRole);
        cycle.children = @[cycle];
        assert(inspectLocalRoots(@[cycle], "Product", generous).visitedNodes == 1);
        cycle.children = @[];

        NSMutableArray* many = [NSMutableArray array];
        for (int i = 0; i < 1000; ++i) [many addObject:fixture(NSAccessibilityStaticTextRole, @"Ordinary label")];
        auto bounded = inspectLocalRoots(many, "Product", {24, 12, 200.0});
        assert(bounded.visitedNodes <= 24 && bounded.rule.empty());

        ProbeFixture* chain = fixture(NSAccessibilityGroupRole);
        ProbeFixture* cursor = chain;
        for (int i = 0; i < 7; ++i)
        {
            ProbeFixture* next = fixture(NSAccessibilityGroupRole);
            cursor.children = @[next]; cursor = next;
        }
        cursor.children = @[positive];
        auto shallow = inspectLocalRoots(@[chain], "Orra Filter", {256, 3, 200.0});
        assert(shallow.rule.empty() && shallow.visitedNodes <= 4);

        ProbeFixture* slow = fixture(NSAccessibilityGroupRole);
        slow.slowRole = YES; slow.children = @[positive];
        auto expiredBudget = inspectLocalRoots(@[slow], "Orra Filter", {256, 12, 1.0});
        assert(expiredBudget.budgetExhausted && expiredBudget.rule.empty() && slow.childrenReads == 0);
        ProbeFixture* throwing = fixture(NSAccessibilityGroupRole);
        throwing.throwChildren = YES;
        assert(inspectLocalRoots(@[throwing], "Product", generous).rule.empty());

        ProbeResult workerResult;
        std::thread worker([&] { workerResult = inspectLocalRoots(@[positive], "Orra Filter", generous); });
        worker.join();
        assert(workerResult.rule.empty() && workerResult.visitedNodes == 0);

        // Real native labels, never presented on screen, exercise AppKit's own
        // NSAccessibility implementation instead of only fixture objects.
        [NSApplication sharedApplication];
        NSView* view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 60)];
        NSTextField* label = [NSTextField labelWithString:@"Your license has expired"];
        [view addSubview:label];
        view.accessibilityRole = NSAccessibilityGroupRole;
        view.accessibilityChildren = @[label];
        auto native = inspectLocalRoots(@[view], "Product", generous);
        assert(native.rule == "license_expired");
        label.hidden = YES;
        assert(inspectLocalRoots(@[view], "Product", generous).rule.empty());
        assert(inspectOwnVisibleWindows("Product", generous).rule.empty());
        std::cout << "PASS: " << corpus.size() + 2 << " status text cases; input/protected/hidden exclusions; "
                  << "cycle/node/depth/time budgets; worker-thread rejection; own native label\n";
    }
}
