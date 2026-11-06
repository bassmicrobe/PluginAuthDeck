// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <cstddef>
#include <string>
#include <string_view>

#ifdef __OBJC__
@class NSArray;
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
};

// Must be called on the UI thread. Uses only this process's NSApp windows and
// in-process NSAccessibility objects. No AXUIElement/AXIsProcessTrusted API,
// permission request, screenshot, OCR, input value, or vendor file is used.
ProbeResult inspectOwnVisibleWindows(std::string_view productName, Limits limits = {});

// Scan-mode presentation of this process's own windows only. Neither function
// activates the app, sends UI input, or changes any external application's state.
void configureBackgroundScan();
void orderScanWindowBehind(void* nativeView);

#ifdef __OBJC__
// Testable traversal core. Production callers should use inspectOwnVisibleWindows.
// Roots must be local AppKit objects, never external AXUIElement references.
ProbeResult inspectLocalRoots(NSArray* roots, std::string_view productName, Limits limits = {});
#endif
}
