// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <cstddef>
#include <string>
#include <string_view>

#ifdef __OBJC__
@class NSArray;
@class NSView;
@class NSImage;
#endif

namespace PluginAuthLicense
{
// Empty means unknown, never "activated". Only fixed rule IDs leave the probe.
std::string matchStatusText(std::string_view text, std::string_view productName);

struct Limits
{
    std::size_t maxNodes = 256;
    unsigned maxDepth = 12;
    double maxMilliseconds = 6.0;
};

struct ProbeResult
{
    std::string rule;
    std::size_t visitedNodes = 0;
    bool budgetExhausted = false;
    // OCR runs off the UI thread. A pending job is not a negative observation.
    bool pending = false;
    double sampledAtMilliseconds = 0.0; // steady_clock capture time, not consume time
    std::size_t staticTextNodes = 0;
    std::size_t maskedRegions = 0;
    // A complete, nonempty observation of readable local UI content. False
    // for blank/unrenderable editors, pending OCR or an incomplete traversal.
    // This is coverage evidence only, never proof that a license is valid.
    bool contentObserved = false;
    std::string diagnostic; // fixed codes only, never UI/OCR text
};

// Must be called on the UI thread. Uses only this process's NSApp windows and
// in-process NSAccessibility objects. No AXUIElement/AXIsProcessTrusted API,
// permission request, input value, or vendor file is used. Optional OCR redraws
// only this process's own content view into temporary memory with input regions
// masked. Callers must enable it only for unattended scan mode, never manual UI.
ProbeResult inspectOwnVisibleWindows(std::string_view productName, Limits limits = {}, bool allowOCR = false);

// Scan-mode presentation of this process's own windows only. Neither function
// activates the app, sends UI input, or changes any external application's state.
void configureBackgroundScan();
void orderScanWindowBehind(void* nativeView);

// Headless native worker: bounded JSON header + PNG from stdin, fixed-result
// JSON to stdout. No files, plug-ins, devices or windows. Returns 0 for a valid
// result, 2 for invalid input; watchdog exits 72/74 on parent loss/time limit.
// Optional main-thread presentation hook if an application already exists.
// Both worker entry points also work before NSApplication initialization.
void configureNativeOCRWorker();
int runNativeOCRWorker(int expectedParentPID);
// Prepares Vision using fixed synthetic text only. Never reads stdin or a user
// image. Native-only, same parent checks; 60-second watchdog. Emits only
// {"version":1,"ready":true} after successful recognition. Failure is nonzero.
int runNativeOCRWarmup(int expectedParentPID);

#ifdef __OBJC__
// Testable traversal core. Production callers should use inspectOwnVisibleWindows.
// Roots must be local AppKit objects, never external AXUIElement references.
ProbeResult inspectLocalRoots(NSArray* roots, std::string_view productName, Limits limits = {});

// Test seams: local view rendering and in-memory image recognition, without a
// visible window or capture API. A nil image means safe rendering was impossible.
// Neither function writes an image or returns recognized strings. Recognition
// runs in the owned native worker even when the calling host is native arm64;
// plug-in process state cannot contaminate Vision or leave a stuck OCR job.
NSImage* renderMaskedLocalView(NSView* view, ProbeResult& diagnostics);
ProbeResult recognizeLocalImage(NSImage* image, std::string_view productName, double sampledAtMilliseconds = 0.0);
// Pure source-selection policy: reconfirm a positive source before rotating to
// another window. A missing/deallocated source falls back to round-robin.
std::size_t preferredOCRSourceIndex(NSArray* sources, id positiveSource, std::size_t roundRobinIndex);
#endif
}
