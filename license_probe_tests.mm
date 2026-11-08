// SPDX-License-Identifier: AGPL-3.0-only
// Standalone tests; no plug-in, external accessibility permission, visible
// window, screen capture, network access, or vendor storage is used.
// xcrun clang++ -std=c++17 -fobjc-arc -framework Cocoa -framework Vision -framework ImageIO LicenseProbe.mm \
//   license_probe_tests.mm -o /tmp/plugin-auth-license-probe-tests
// /tmp/plugin-auth-license-probe-tests
// Build both -arch arm64 and -arch x86_64 and lipo them together to exercise
// Rosetta -> native worker recognition with the same positive/negative corpus.
#import <AppKit/AppKit.h>
#include "LicenseProbe.h"
#include <cassert>
#include <chrono>
#include <iostream>
#include <thread>
#include <vector>
#include <csignal>

@interface ProbeFixture : NSObject
@property NSString* role;
@property NSString* text;
@property NSArray* children;
@property BOOL protectedContent;
@property BOOL throwChildren;
@property BOOL slowRole;
@property NSUInteger textReads;
@property NSUInteger childrenReads;
@property NSUInteger valueReads;
@end
@implementation ProbeFixture
- (NSString*)accessibilityRole {
    if (_slowRole) std::this_thread::sleep_for(std::chrono::milliseconds(20));
    return _role;
}
- (NSString*)accessibilityTitle { ++_textReads; return _text; }
- (NSString*)accessibilityLabel { ++_textReads; return _text; }
- (id)accessibilityValue { ++_textReads; ++_valueReads; return _text; }
- (BOOL)isAccessibilityProtectedContent { return _protectedContent; }
- (NSArray*)accessibilityChildren {
    ++_childrenReads;
    if (_throwChildren) @throw [NSException exceptionWithName:@"Fixture" reason:nil userInfo:nil];
    return _children ?: @[];
}
@end

@interface ProbePaintedFixture : NSView
@property NSArray<NSString*>* lines;
@property BOOL fixtureFlipped;
@end
@implementation ProbePaintedFixture
- (BOOL)isFlipped { return _fixtureFlipped; }
- (void)drawRect:(NSRect)rect {
    [[NSColor whiteColor] setFill]; NSRectFill(rect);
    NSUInteger i = 0;
    for (NSString* line in _lines) {
        const CGFloat y = _fixtureFlipped ? 12 + i * 46 : self.bounds.size.height - 46 - i * 46;
        [line drawAtPoint:NSMakePoint(12, y) withAttributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:28], NSForegroundColorAttributeName: NSColor.blackColor}];
        ++i;
    }
}
@end

@interface ProbeDensePaintedFixture : NSView
@end
@implementation ProbeDensePaintedFixture
- (void)drawRect:(NSRect)rect {
    [[NSColor colorWithWhite:0.12 alpha:1] setFill]; NSRectFill(rect);
    NSArray* words = @[@"INPUT", @"OUTPUT", @"GAIN", @"ATTACK", @"RELEASE", @"RATIO", @"METER", @"PRESET"];
    NSDictionary* small = @{NSFontAttributeName:[NSFont systemFontOfSize:16],
        NSForegroundColorAttributeName:[NSColor colorWithWhite:0.82 alpha:1]};
    for (NSUInteger row = 0; row < 5; ++row)
        for (NSUInteger col = 0; col < 12; ++col) {
            CGFloat x = 14 + col * 154, y = 30 + row * 92;
            [words[(row + col) % words.count] drawAtPoint:NSMakePoint(x, y) withAttributes:small];
            [[NSColor colorWithWhite:0.5 alpha:1] setStroke];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x + 16, y + 26, 44, 44)] stroke];
            for (int tick = 0; tick < 9; ++tick) {
                NSBezierPath* mark = [NSBezierPath bezierPath];
                [mark moveToPoint:NSMakePoint(x + 4 + tick * 8, y + 22)];
                [mark lineToPoint:NSMakePoint(x + 4 + tick * 8, y + 26)]; [mark stroke];
            }
        }
    [@"This product is not activated" drawAtPoint:NSMakePoint(600, 520) withAttributes:@{
        NSFontAttributeName:[NSFont boldSystemFontOfSize:28], NSForegroundColorAttributeName:NSColor.whiteColor}];
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

int main(int argc, char** argv)
{
    using namespace PluginAuthLicense;
    @autoreleasepool
    {
        if (argc > 1 && (std::string(argv[1]) == "--ocr-worker" || std::string(argv[1]) == "--ocr-warmup"))
        {
            if (argc != 3 || std::string(argv[2]).empty()
                || std::string(argv[2]).find_first_not_of("0123456789") != std::string::npos) return 2;
            const auto parent = strtoll(argv[2], nullptr, 10);
            if (parent <= 1 || parent > INT_MAX) return 2;
            if (std::string(argv[1]) == "--ocr-worker" && getenv("PAD_TEST_OCR_HANG") != nullptr)
            {
                // Test only: simulate an uncooperative Vision call. The real
                // parent must kill/reap this owned child and recover next time.
                signal(SIGTERM, SIG_IGN);
                std::this_thread::sleep_for(std::chrono::seconds(15));
                return 3;
            }
            return std::string(argv[1]) == "--ocr-warmup" ? runNativeOCRWarmup((int)parent) : runNativeOCRWorker((int)parent);
        }
        if (argc > 1 && std::string(argv[1]) == "--benchmark-ocr")
        {
            [NSApplication sharedApplication];
            ProbePaintedFixture* large = [[ProbePaintedFixture alloc] initWithFrame:NSMakeRect(0, 0, 1900, 486)];
            large.lines = @[@"This product is not activated", @"Input Output Gain Frequency Release Ratio",
                            @"Threshold Mix Presets Settings Version 1.0", @"Left Right Stereo Mono Bypass"];
            large.accessibilityChildren = @[];
            ProbeResult render;
            NSImage* image = renderMaskedLocalView(large, render);
            assert(image != nil);
            for (int sample = 0; sample < 3; ++sample)
            {
                const auto start = std::chrono::steady_clock::now();
                const auto result = recognizeLocalImage(image, "Product");
                const auto ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
                std::cout << "accurate 1900x486 sample " << sample + 1 << ": " << ms << " ms, rule=" << result.rule
                          << ", diagnostic=" << result.diagnostic << std::endl;
                assert(result.rule == "product_not_activated");
            }
            return 0;
        }
        if (argc > 1 && std::string(argv[1]) == "--benchmark-dense-ocr")
        {
            [NSApplication sharedApplication];
            ProbeDensePaintedFixture* dense = [[ProbeDensePaintedFixture alloc] initWithFrame:NSMakeRect(0, 0, 1900, 580)];
            dense.accessibilityChildren = @[];
            bool success = true;
            for (int sample = 0; sample < 5; ++sample)
            {
                ProbeResult rendering;
                NSImage* image = renderMaskedLocalView(dense, rendering);
                assert(image != nil);
                const auto start = std::chrono::steady_clock::now();
                const auto result = recognizeLocalImage(image, "Synthetic Product", rendering.sampledAtMilliseconds);
                const auto ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
                std::cout << "isolated dense1900x580 sample=" << sample + 1 << " ms=" << ms
                          << " diagnostic=" << result.diagnostic << " nodes=" << result.staticTextNodes << std::endl;
                success &= result.rule == "product_not_activated";
            }
            return success ? 0 : 1;
        }
        assert(runNativeOCRWorker(0) == 2);
        assert(runNativeOCRWorker((int)getpid()) == 2); // Never accept a claimed, non-parent PID.
        assert(runNativeOCRWarmup(0) == 2);
        assert(runNativeOCRWarmup((int)getpid()) == 2);
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
            // UA's native plug-in troubleshooting docs distinguish this error
            // from hardware, connectivity and ordinary Activate License UI.
            {"Plug-in Not Licensed", "UADx 1176 Rev A Compressor", "unlicensed_status"},
            {"Plugin Not Licensed", "UADx LA-2A Leveler Collection", "unlicensed_status"},
            {"Plug-in Not Licensed", "Other Compressor", ""},
            {"DISABLED", "UAD 4K Buss Compressor", ""},
            {"Activate License", "UADx 1176 Rev A Compressor", ""},
            {"No Connection to UA Connect", "UADx 1176 Rev A Compressor", ""},
            {"Not Logged In", "UADx 1176 Rev A Compressor", ""},
            {"GUI Load Failed", "UADx 1176 Rev A Compressor", ""},
            {"No valid license was found for this product", "Product", "no_valid_license"},
            {"この製品は認証されていません", "Product", "product_not_activated"},
            {"Orra Filter is unregistered", "Orra Filter", "product_not_registered"},
            {"This is an unregistered version of Orra Filter", "Orra Filter", "product_not_registered"},
            {"Registration status: unregistered", "Product", "product_not_registered"},
            {"This product is not authorized", "Product", "product_not_activated"},
            {"This plug-in is not licensed", "Product", "unlicensed_status"},
            {"This product requires activation", "Product", "product_not_activated"},
            {"Orra Filter is running in demo mode", "Orra Filter", "demo_mode"},
            {"This plug-in is in trial mode", "Product", "demo_mode"},
            {"This software is running in evaluation mode", "Product", "demo_mode"},
            {"License status: demo", "Product", "demo_mode"},
            {"License mode: trial", "Product", "demo_mode"},
            {"Your trial period has expired", "Product", "trial_expired"},
            {"Trial expired", "Product", "trial_expired"},
            {"Your evaluation period has expired", "Product", "trial_expired"},
            {"Demo Version", "Product", ""},
            {"Not registered", "Product", ""},
            {"Unlicensed", "Product", ""},
            {"Not activated", "Product", ""},
            {"Activate", "Product", ""}, {"Activate License", "Product", ""},
            {"Enter License Key", "Orra Filter", ""}, {"Start 14-Day Demo", "Orra Filter", ""},
            {"Trial", "Product", ""}, {"14 days remaining", "Product", ""},
            {"If the license has expired, click Activate", "Product", ""},
            {"License expired?", "Product", ""},
            {"Orra Filter is not activated on this machine?", "Orra Filter", ""},
            {"Help: Orra Filter is not activated on this machine", "Orra Filter", ""},
            {"This is an example: license status: unlicensed", "Product", ""},
            {"The license has expired. Buy a subscription now", "Product", ""},
            {"Demo", "Product", ""}, {"Demo Version?", "Product", ""},
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
        assert(detected.rule == "product_not_activated" && detected.contentObserved);
        auto emptyText = inspectLocalRoots(@[fixture(NSAccessibilityStaticTextRole, @"   \n")], "Product", generous);
        assert(!emptyText.contentObserved && emptyText.staticTextNodes == 0);
        auto ordinaryText = inspectLocalRoots(@[fixture(NSAccessibilityStaticTextRole, @"Input Gain")], "Product", generous);
        assert(ordinaryText.contentObserved && ordinaryText.rule.empty());
        ProbeFixture* dspDisabled = fixture(NSAccessibilityButtonRole, @"DISABLED");
        auto disabledResult = inspectLocalRoots(@[dspDisabled], "UAD 4K Buss Compressor", generous);
        assert(disabledResult.rule.empty() && disabledResult.diagnostic == "uad_dsp_disabled" && !disabledResult.contentObserved);
        assert(inspectLocalRoots(@[dspDisabled], "UADx 1176 Rev A Compressor", generous).diagnostic != "uad_dsp_disabled");
        assert(inspectLocalRoots(@[dspDisabled], "Other Compressor", generous).diagnostic != "uad_dsp_disabled");
        auto explicitFailure = inspectLocalRoots(@[dspDisabled, fixture(NSAccessibilityStaticTextRole, @"This product is not activated")],
                                                 "UAD 4K Buss Compressor", generous);
        assert(explicitFailure.rule == "product_not_activated");

        // Neither the input's value nor its descendants may be inspected.
        for (NSString* role in @[NSAccessibilityTextFieldRole, NSAccessibilityTextAreaRole, NSAccessibilityPopUpButtonRole])
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

        ProbeFixture* prompt = fixture(NSAccessibilityStaticTextRole, @"Enter License Key");
        ProbeFixture* action = fixture(NSAccessibilityButtonRole, @"Activate");
        ProbeFixture* input = fixture(NSAccessibilityTextFieldRole, @"SECRET-KEY-NEVER-READ");
        ProbeFixture* form = fixture(NSAccessibilityGroupRole);
        form.children = @[prompt, input, action];
        assert(inspectLocalRoots(@[form], "Product", generous).rule == "activation_form");
        assert(input.textReads == 0 && input.childrenReads == 0 && action.valueReads == 0 && action.childrenReads == 0);
        assert(inspectLocalRoots(@[action], "Product", generous).rule.empty());
        assert(inspectLocalRoots(@[prompt], "Product", generous).rule.empty());
        assert(inspectLocalRoots(@[prompt, input, action], "Product", generous).rule.empty()); // separate scopes
        ProbeFixture* dismiss = fixture(NSAccessibilityButtonRole, @"Quit");
        ProbeFixture* requirement = fixture(NSAccessibilityStaticTextRole, @"Activation Required");
        form.children = @[requirement, action, dismiss];
        assert(inspectLocalRoots(@[form], "Product", generous).rule == "product_not_activated");
        form.children = @[requirement, action];
        assert(inspectLocalRoots(@[form], "Product", generous).rule.empty());
        form.children = @[requirement, dismiss];
        assert(inspectLocalRoots(@[form], "Product", generous).rule.empty());
        form.children = @[requirement, action, dismiss, fixture(NSAccessibilityStaticTextRole, @"Licensed to Example User")];
        assert(inspectLocalRoots(@[form], "Product", generous).rule.empty());
        ProbeFixture* message = fixture(NSAccessibilityStaticTextRole, @"This product is not activated. Please activate a license before continuing.");
        form.children = @[message, action, dismiss];
        assert(inspectLocalRoots(@[form], "Product", generous).rule == "product_not_activated");
        form.children = @[message, action];
        assert(inspectLocalRoots(@[form], "Product", generous).rule.empty());
        form.children = @[fixture(NSAccessibilityStaticTextRole, @"For example: this product is not activated. Click Activate."), action, dismiss];
        assert(inspectLocalRoots(@[form], "Product", generous).rule.empty());
        form.children = @[prompt, input, action, fixture(NSAccessibilityStaticTextRole, @"FAQ")];
        assert(inspectLocalRoots(@[form], "Product", generous).rule.empty());
        form.children = @[positive, fixture(NSAccessibilityStaticTextRole, @"Activation Help")];
        assert(inspectLocalRoots(@[form], "Orra Filter", generous).rule.empty());
        form.children = @[prompt, input, action, fixture(NSAccessibilityStaticTextRole, @"Licensed to Example User")];
        assert(inspectLocalRoots(@[form], "Product", generous).rule.empty());
        for (NSString* presetName in @[@"Demo Version", @"Not registered", @"Unlicensed", @"Not activated"]) {
            ProbeFixture* presetLabel = fixture(NSAccessibilityStaticTextRole, presetName);
            assert(inspectLocalRoots(@[presetLabel], "Product", generous).rule.empty());
            form.children = @[presetLabel, action]; // Normal editor with a permanent licensing button.
            assert(inspectLocalRoots(@[form], "Product", generous).rule.empty());
        }

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
        assert(expiredBudget.budgetExhausted && !expiredBudget.contentObserved && expiredBudget.rule.empty() && slow.childrenReads == 0);
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

        // Pixels drawn by this fixture have no AX static text. Only an
        // offscreen NSView redraw is used; no display/window image is captured.
        ProbePaintedFixture* painted = [[ProbePaintedFixture alloc] initWithFrame:NSMakeRect(0, 0, 850, 200)];
        painted.lines = @[@"This product is not activated"];
        painted.accessibilityChildren = @[];
        ProbeResult rendering;
        NSImage* rendered = renderMaskedLocalView(painted, rendering);
        assert(rendered != nil && rendering.sampledAtMilliseconds > 0);
        const auto paintedResult = recognizeLocalImage(rendered, "Product", rendering.sampledAtMilliseconds);
        assert(paintedResult.rule == "product_not_activated" && paintedResult.contentObserved
               && paintedResult.sampledAtMilliseconds == rendering.sampledAtMilliseconds);
        setenv("PAD_TEST_OCR_HANG", "1", 1);
        const auto hungStart = std::chrono::steady_clock::now();
        const auto hungResult = recognizeLocalImage(rendered, "Product");
        unsetenv("PAD_TEST_OCR_HANG");
        const auto hungSeconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - hungStart).count();
        assert(hungResult.diagnostic == "ocr_time_budget_exceeded" && !hungResult.contentObserved);
        assert(hungSeconds >= 2 && hungSeconds < 5);
        assert(recognizeLocalImage(rendered, "Product").rule == "product_not_activated");
        painted.lines = @[@"This product is not", @"activated on this machine"];
        assert(recognizeLocalImage(renderMaskedLocalView(painted, rendering), "Product").rule == "product_not_activated");
        painted.lines = @[@"Activation Required", @"Activate", @"Quit"];
        assert(recognizeLocalImage(renderMaskedLocalView(painted, rendering), "Product").rule == "product_not_activated");
        painted.lines = @[@"This product is not", @"activated on this machine?"];
        assert(recognizeLocalImage(renderMaskedLocalView(painted, rendering), "Product").rule.empty());
        painted.lines = @[@"Plug-in Not Licensed"];
        assert(recognizeLocalImage(renderMaskedLocalView(painted, rendering), "UADx 1176 Rev A Compressor").rule == "unlicensed_status");
        assert(recognizeLocalImage(renderMaskedLocalView(painted, rendering), "Other Compressor").rule.empty());
        painted.lines = @[@"DISABLED", @"Input Output Gain Frequency"];
        const auto disabledOCR = recognizeLocalImage(renderMaskedLocalView(painted, rendering), "UAD 4K Buss Compressor");
        assert(disabledOCR.rule.empty() && disabledOCR.diagnostic == "uad_dsp_disabled" && !disabledOCR.contentObserved);
        assert(recognizeLocalImage(renderMaskedLocalView(painted, rendering), "UADx 1176 Rev A Compressor").contentObserved);
        painted.lines = @[];
        const auto blankResult = recognizeLocalImage(renderMaskedLocalView(painted, rendering), "Product");
        assert(!blankResult.contentObserved && blankResult.staticTextNodes == 0 && blankResult.diagnostic == "ocr_no_text");
        painted.lines = @[@"Input Output Gain Frequency"];
        const auto normalResult = recognizeLocalImage(renderMaskedLocalView(painted, rendering), "Product");
        assert(normalResult.contentObserved && normalResult.rule.empty() && normalResult.diagnostic == "ocr_no_supported_status");
        const auto expiredCapture = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now().time_since_epoch()).count() - 3000.0;
        const auto expiredRecognition = recognizeLocalImage(rendered, "Product", expiredCapture);
        assert(expiredRecognition.rule.empty() && expiredRecognition.diagnostic == "ocr_time_budget_exceeded");
        painted.lines = @[@"Enter License Key", @"Activate", @"Cancel"];
        rendered = renderMaskedLocalView(painted, rendering);
        assert(recognizeLocalImage(rendered, "Product").rule == "activation_form");
        painted.lines = @[@"Activate"];
        assert(recognizeLocalImage(renderMaskedLocalView(painted, rendering), "Product").rule.empty());
        painted.lines = @[@"Enter License Key", @"Activate", @"Cancel", @"FAQ"];
        assert(recognizeLocalImage(renderMaskedLocalView(painted, rendering), "Product").rule.empty());
        painted.lines = @[@"Licensed to Example User"];
        assert(recognizeLocalImage(renderMaskedLocalView(painted, rendering), "Product").rule.empty());
        painted.lines = @[@"Demo Version"];
        assert(recognizeLocalImage(renderMaskedLocalView(painted, rendering), "Product").rule.empty());
        painted.lines = @[@"Demo Version", @"Activate"];
        assert(recognizeLocalImage(renderMaskedLocalView(painted, rendering), "Product").rule.empty());
        painted.lines = @[@"Not registered", @"Activate"];
        assert(recognizeLocalImage(renderMaskedLocalView(painted, rendering), "Product").rule.empty());
        painted.lines = @[@"License status: demo"];
        assert(recognizeLocalImage(renderMaskedLocalView(painted, rendering), "Product").rule == "demo_mode");
        painted.lines = @[@"Demo Version", @"Activate", @"Licensed to Example User"];
        assert(recognizeLocalImage(renderMaskedLocalView(painted, rendering), "Product").rule.empty());
        painted.lines = @[@"Enter License Key", @"Activate", @"Cancel", @"License status: activated"];
        assert(recognizeLocalImage(renderMaskedLocalView(painted, rendering), "Product").rule.empty());

        // Both coordinate orientations and native/AX-only input controls are
        // inspected before drawing. Input pixels and values cannot be evidence.
        painted.lines = @[];
        for (int flipped = 0; flipped < 2; ++flipped) {
            painted.fixtureFlipped = flipped != 0;
            NSTextField* secret = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 55, 820, 50)];
            secret.stringValue = @"This product is not activated";
            secret.font = [NSFont systemFontOfSize:28]; secret.editable = YES;
            [painted addSubview:secret];
            painted.accessibilityChildren = @[secret];
            rendered = renderMaskedLocalView(painted, rendering);
            assert(rendered != nil && rendering.maskedRegions >= 1);
            assert(recognizeLocalImage(rendered, "Product").rule.empty());
            painted.lines = @[@"This product is not activated"];
            assert(recognizeLocalImage(renderMaskedLocalView(painted, rendering), "Product").rule == "product_not_activated");
            painted.lines = @[];
            [secret removeFromSuperview];
        }
        ProbeFixture* axInput = fixture(NSAccessibilityTextFieldRole, @"SECRET-AX-KEY");
        painted.accessibilityChildren = @[axInput];
        assert(renderMaskedLocalView(painted, rendering) == nil);
        assert(rendering.diagnostic == "ocr_input_geometry_missing" && axInput.textReads == 0 && axInput.childrenReads == 0);
        ProbeFixture* protectedButton = fixture(NSAccessibilityButtonRole, @"SECRET-BUTTON-VALUE");
        protectedButton.protectedContent = YES;
        painted.accessibilityChildren = @[protectedButton];
        assert(renderMaskedLocalView(painted, rendering) == nil);
        assert(protectedButton.textReads == 0 && protectedButton.childrenReads == 0);

        // A normal editor A and authentication dialog B must produce A,B,B,
        // not A,B,A,B. A second image of B can then satisfy the host's separate
        // two-observation/time policy. Closed/replaced B is never preferred.
        NSObject* editorSource = [NSObject new];
        NSObject* dialogSource = [NSObject new];
        NSArray* sources = @[editorSource, dialogSource];
        assert(preferredOCRSourceIndex(sources, nil, 0) == 0);
        assert(preferredOCRSourceIndex(sources, nil, 1) == 1);
        assert(preferredOCRSourceIndex(sources, dialogSource, 0) == 1);
        assert(preferredOCRSourceIndex(@[editorSource], dialogSource, 0) == 0);
        assert(preferredOCRSourceIndex(@[], dialogSource, 0) == 0);
        std::cout << "PASS: " << corpus.size() + 2 << " status text cases; input/protected/hidden exclusions; "
                  << "cycle/node/depth/time budgets; worker-thread rejection; own native label; "
                  << "form conjunctions; local image OCR; masked native/AX inputs; FAQ/licensed negatives\n";
    }
}
