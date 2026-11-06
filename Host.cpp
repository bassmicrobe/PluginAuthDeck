// SPDX-License-Identifier: AGPL-3.0-only
#include <string>
#include <string_view>
#include <vector>

namespace HostRequestPolicy
{
constexpr std::size_t maxRequestBytes = 65536;
constexpr std::size_t maxRequestDepth = 32;

// Bound recursion before handing local files to the dependency's JSON parser.
// This is a structural preflight, not a replacement for JSON syntax validation.
bool hasSafeJSONEnvelope(std::string_view json)
{
    if (json.empty() || json.size() > maxRequestBytes) return false;
    std::vector<char> containers;
    bool quoted = false, escaped = false;
    for (const char byte : json)
    {
        if (byte == '\0') return false;
        if (quoted)
        {
            if (escaped) escaped = false;
            else if (byte == '\\') escaped = true;
            else if (byte == '"') quoted = false;
            continue;
        }
        if (byte == '"') quoted = true;
        else if (byte == '{' || byte == '[')
        {
            if (containers.size() >= maxRequestDepth) return false;
            containers.push_back(byte);
        }
        else if (byte == '}' || byte == ']')
        {
            if (containers.empty() || containers.back() != (byte == '}' ? '{' : '[')) return false;
            containers.pop_back();
        }
    }
    return !quoted && containers.empty();
}

enum class Mode { manual, scan, invalid };
Mode parseMode(std::string_view mode)
{
    if (mode.empty() || mode == "manual") return Mode::manual;
    if (mode == "scan") return Mode::scan;
    return Mode::invalid;
}

// -1 means an interactive choice is needed; -2 is a missing/invalid target.
// This same policy is tested without creating any AppKit window or plug-in.
int chooseClass(const std::vector<std::string>& available, std::string_view requested, bool scan)
{
    if (!requested.empty())
    {
        for (std::size_t i = 0; i < available.size(); ++i)
            if (available[i] == requested) return static_cast<int>(i);
        return -2;
    }
    if (available.empty()) return -2;
    return scan || available.size() == 1 ? 0 : -1;
}

bool isAUUnauthorized(std::string_view format, std::string_view classID, std::string_view error)
{
    // Apple defines -10847 as an explicit authorization failure at Open or
    // Initialize. Match JUCE's complete AU creation error, never a number found
    // in arbitrary plug-in text or a generic VST3 load failure.
    return format == "AU" && !classID.empty()
        && error == "An OS error occurred during initialisation of the plug-in (-10847)";
}
}

#ifndef PLUGIN_AUTH_HOST_POLICY_TEST
#include <juce_audio_processors/juce_audio_processors.h>
#include <juce_gui_extra/juce_gui_extra.h>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <fcntl.h>
#include <optional>
#include <sys/stat.h>
#include <thread>
#include <unistd.h>
#include "LicenseProbe.h"
using namespace juce;

namespace
{
std::optional<std::string> readRequestFile(const File& request)
{
    // A FIFO can pass JUCE existsAsFile() and block open before our watchdog
    // starts. Open without blocking/following links and inspect that same fd.
    const int descriptor = ::open(request.getFullPathName().toRawUTF8(), O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0) return std::nullopt;
    const auto closer = ScopeGuard { [descriptor] { ::close(descriptor); } };
    struct stat metadata {};
    if (::fstat(descriptor, &metadata) != 0 || !S_ISREG(metadata.st_mode)
        || metadata.st_size < 0 || metadata.st_size > static_cast<off_t>(HostRequestPolicy::maxRequestBytes))
        return std::nullopt;
    std::string bytes;
    std::array<char, 4096> buffer {};
    while (bytes.size() <= HostRequestPolicy::maxRequestBytes)
    {
        const auto remaining = HostRequestPolicy::maxRequestBytes + 1 - bytes.size();
        const auto count = ::read(descriptor, buffer.data(), std::min(buffer.size(), remaining));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) return std::nullopt;
        if (count == 0) return bytes;
        bytes.append(buffer.data(), static_cast<std::size_t>(count));
    }
    return std::nullopt; // The file grew beyond the bound after fstat.
}
}

// One selected plug-in per process. No AudioDeviceManager, MIDI device, audio
// callback, prepareToPlay(), or network client is created by this host.
class Host final : public JUCEApplication, private Timer
{
public:
    const String getApplicationName() override { return "Plugin Auth Desk — Plugin"; }
    const String getApplicationVersion() override { return JUCE_APPLICATION_VERSION_STRING; }
    bool moreThanOneInstanceAllowed() override { return true; }

    void initialise(const String&) override
    {
        auto args = getCommandLineParameterArray();
        if (args.size() != 2 || args[0] != "--request") { setApplicationReturnValue(2); quit(); return; }
        if (!File::isAbsolutePath(args[1])) { setApplicationReturnValue(2); quit(); return; }
        File request(args[1]);
        const auto bytes = readRequestFile(request);
        if (!bytes) { setApplicationReturnValue(2); quit(); return; }
        statusFile = request.getSiblingFile("status.json");
        heartbeatFile = request.getSiblingFile("heartbeat.json");
        quitFile = request.getSiblingFile("quit.request");
        if (!HostRequestPolicy::hasSafeJSONEnvelope(*bytes)
            || !CharPointer_UTF8::isValidString(bytes->data(), static_cast<int>(bytes->size())))
        { fail("Invalid launch request"); return; }
        config = JSON::parse(String::fromUTF8(bytes->data(), static_cast<int>(bytes->size())));
        const auto mode = HostRequestPolicy::parseMode(config["mode"].toString().toStdString());
        scanMode = mode == HostRequestPolicy::Mode::scan;
        if (mode == HostRequestPolicy::Mode::invalid) { fail("Invalid launch mode"); return; }
        parent = int(config["parentPID"]);
        pluginName = config["name"].toString();
        // A saved PID can be reused after a crash. Our actual parent relationship
        // identifies the launcher's lifetime, without probing/signalling that PID.
        if (parent <= 1 || parent != getppid() || pluginName.isEmpty()) { fail("Invalid launch request"); return; }
        startWatchdog();
        if (scanMode) PluginAuthLicense::configureBackgroundScan();
        else Process::makeForegroundProcess();
        report("loading", "Reading selected plug-in");
        window = std::make_unique<Window>(pluginName + " — Plugin Auth Desk", *this, scanMode);
        auto label = new Label();
        label->setText("Opening " + pluginName + "…", dontSendNotification);
        label->setJustificationType(Justification::centred);
        label->setSize(520, 120);
        window->setContentOwned(label, true);
        window->centreWithSize(520, 145);
        window->setVisible(true);
        keepScanWindowBehind();
        writeHeartbeat();
        startTimer(1000);
        // Defer until the native window and event loop exist (license dialogs
        // presented during plug-in construction need a functioning host UI).
        MessageManager::callAsync([this] { load(); });
    }

    void load()
    {
        if (quitting.load()) return;
        if (quitFile.existsAsFile()) { requestQuit(); return; }
        const auto fmt = config["format"].toString();
        if (fmt == "VST3") formats.addFormat(std::make_unique<VST3PluginFormat>());
        else if (fmt == "AU") formats.addFormat(std::make_unique<AudioUnitPluginFormat>());
        else { fail("Unsupported format"); return; }

        auto* format = formats.getFormat(0);
        format->findAllTypesForFile(descriptions, config["identifier"].toString());
        if (descriptions.isEmpty()) { fail("No compatible plug-in found. Try the other format or architecture."); return; }

        const auto requestedClass = config["classID"].toString();
        std::vector<std::string> availableClasses;
        for (const auto* description : descriptions)
            availableClasses.push_back(description->createIdentifierString().toStdString());
        const auto selection = HostRequestPolicy::chooseClass(availableClasses, requestedClass.toStdString(), scanMode);
        if (selection >= 0) { instantiate(selection); return; }
        if (selection == -2)
        {
            fail("The requested plug-in class is no longer available. Refresh the plug-in list.");
            return; // Never silently activate a different product in this bundle.
        }

        if (descriptions.size() > 1)
        {
            report("selecting", "Choose a plug-in in the bundle");
            auto panel = std::make_unique<Component>();
            auto title = std::make_unique<Label>();
            title->setText("Choose a plug-in", dontSendNotification);
            title->setBounds(20, 10, 500, 30);
            panel->addAndMakeVisible(title.get());
            controls.add(title.release());
            for (int i = 0; i < descriptions.size(); ++i)
            {
                auto button = std::make_unique<TextButton>(descriptions[i]->name);
                button->setBounds(20, 50 + i * 42, 480, 34);
                button->onClick = [this, i] { instantiate(i); };
                panel->addAndMakeVisible(button.get());
                controls.add(button.release());
            }
            const int contentHeight = 65 + descriptions.size() * 42;
            panel->setSize(520, contentHeight);
            auto viewport = std::make_unique<Viewport>();
            viewport->setViewedComponent(panel.release(), true);
            viewport->setScrollBarsShown(true, false);
            viewport->setSize(540, jmin(570, contentHeight));
            window->setContentOwned(viewport.release(), true);
        }
        else instantiate(0);
    }

    void instantiate(int index)
    {
        if (instantiating || quitting.load()) return;
        instantiating = true;
        for (auto* control : controls) control->setEnabled(false);
        pluginName = descriptions[index]->name;
        selectedClassID = descriptions[index]->createIdentifierString();
        report("loading", "Creating plug-in window");
        // Async creation handles AUv3 bridging and plug-ins that need to post to
        // the main thread. The parent stays responsive even if a plug-in hangs.
        formats.createPluginInstanceAsync(*descriptions[index], 48000.0, 512,
            [this](std::unique_ptr<AudioPluginInstance> instance, const String& error)
            {
                if (quitting.load()) return;
                if (!instance)
                {
                    if (HostRequestPolicy::isAUUnauthorized(config["format"].toString().toStdString(),
                                                           selectedClassID.toStdString(), error.toStdString()))
                        recordLicenseEvidence("au_unauthorized", Time::getCurrentTime().toMilliseconds() / 1000.0, 1);
                    fail(error.isNotEmpty() ? error : "Plug-in creation failed");
                    return;
                }
                plugin = std::move(instance);
                auto* editor = plugin->createEditorAndMakeActive();
                if (!editor) { fail("This plug-in has no custom editor. Use its manufacturer's license app."); return; }
                window->setName(pluginName + " — Plugin Auth Desk");
                window->setContentOwned(editor, true);
                window->setResizable(editor->isResizable(), false);
                window->centreWithSize(editor->getWidth(), editor->getHeight() + window->getTitleBarHeight());
                window->setVisible(true);
                if (scanMode) keepScanWindowBehind();
                else window->toFront(true);
                report("ready", "Plug-in window opened. No license status is assumed.");
                probeLicenseState(true);
            });
    }

    void report(const String& state, const String& message)
    {
        lastState = state;
        lastMessage = message;
        if (statusFile == File()) return;
        auto* obj = new DynamicObject();
        obj->setProperty("state", state);
        obj->setProperty("message", message);
        obj->setProperty("name", pluginName);
        obj->setProperty("classID", selectedClassID);
        obj->setProperty("pid", int(getpid()));
        obj->setProperty("scanMode", scanMode);
        if (scanMode) obj->setProperty("scanDeadlineSeconds", 35);
        if (terminationReason.isNotEmpty()) obj->setProperty("terminationReason", terminationReason);
        Array<var> classes;
        Array<var> classEntries;
        for (const auto* description : descriptions)
        {
            classes.add(description->name);
            auto* entry = new DynamicObject();
            entry->setProperty("classID", description->createIdentifierString());
            entry->setProperty("name", description->name);
            classEntries.add(var(entry));
        }
        obj->setProperty("classes", var(classes));
        obj->setProperty("classEntries", var(classEntries));
        if (!licenseEvidence.isVoid()) obj->setProperty("licenseEvidence", licenseEvidence);
        else if (scanMode && !quitting.load() && !candidateRule.empty() && candidateObservedAt > 0.0)
        {
            // A single observation only permits a bounded wait for another
            // sample. It is never license evidence and contains no UI text.
            auto* candidate = new DynamicObject();
            candidate->setProperty("rule", String(candidateRule));
            candidate->setProperty("observedAt", candidateObservedAt);
            obj->setProperty("licenseCandidate", var(candidate));
        }
        // Preserve the failure after normal window closure, so the launcher can
        // display both the reason and the independently confirmed process exit.
        if (lastError.isNotEmpty()) obj->setProperty("error", lastError);
       #if defined(__arm64__) || defined(__aarch64__)
        obj->setProperty("architecture", "arm64");
       #else
        obj->setProperty("architecture", "x86_64");
       #endif
        obj->setProperty("updated", Time::getCurrentTime().toISO8601(true));
        if (state == "ready" || state == "selecting") writeHeartbeat();
        // JUCE implements replaceWithText using a sibling TemporaryFile and
        // rename/replacement, so the launcher never reads a partially written JSON.
        statusFile.replaceWithText(JSON::toString(var(obj)));
    }
    void fail(const String& message)
    {
        clearLicenseCandidate(false);
        lastError = message;
        report("error", message);
        if (window)
        {
            auto* label = new Label();
            label->setText("Could not open the plug-in.\n\n" + message, dontSendNotification);
            label->setJustificationType(Justification::centred);
            label->setSize(620, 180);
            window->setContentOwned(label, true);
        }
        else { setApplicationReturnValue(1); quit(); }
    }
    void timerCallback() override
    {
        if (scanExpiryRequested.load()) { terminationReason = "scan_time_limit"; requestQuit(); return; }
        if (parentLost.load() || quitFile.existsAsFile()) { requestQuit(); return; }
        // This heartbeat intentionally runs only on the message thread. "ready"
        // means the editor was created; this file separately records UI progress.
        writeHeartbeat();
        probeLicenseState();
    }
    void requestQuit()
    {
        if (quitting.exchange(true)) return;
        report("stopping", "Closing plug-in");
        quit();
    }
    void systemRequestedQuit() override { requestQuit(); }
    void shutdown() override
    {
        quitting.store(true);
        shutdownStarted.store(true);
        stopTimer();
        report("stopping", "Closing plug-in");
        window.reset(); // editor must die before processor
        controls.clear();
        plugin.reset();
        report("closed", "Window closed");
        stopWatchdog.store(true);
        if (watchdog.joinable()) watchdog.join();
    }
private:
    void probeLicenseState(bool immediately = false)
    {
        if (quitting.load() || !instantiating || selectedClassID.isEmpty() || !licenseEvidence.isVoid()) return;
        const auto now = Time::getMillisecondCounterHiRes();
        if (!immediately && now < nextProbeAt) return;
        nextProbeAt = now + 2000.0;
        // The product identity is fixed before asynchronous instantiation, so
        // activation dialogs in its nested native event loop can also be seen.
        // Scanner dialogs before a class is selected remain unattributed/unknown.
        const auto result = PluginAuthLicense::inspectOwnVisibleWindows(pluginName.toStdString());
        if (result.rule.empty())
        {
            clearLicenseCandidate();
            return;
        }
        double observedAt = Time::getCurrentTime().toMilliseconds() / 1000.0;
        if (scanMode)
        {
            if (candidateRule != result.rule)
            {
                candidateRule = result.rule;
                candidateObservedAt = observedAt;
                candidateProbeAt = now;
                report(lastState, lastMessage);
                return;
            }
            // A loading/authentication spinner can briefly show "unlicensed".
            // Automatic scans require the same explicit status on two separated
            // observations; absence or a different rule resets the candidate.
            if (now - candidateProbeAt < 1500.0) return;
            observedAt = candidateObservedAt;
        }
        recordLicenseEvidence(result.rule, observedAt, scanMode ? 2 : 1);
    }

    void recordLicenseEvidence(std::string_view rule, double observedAt, int observations)
    {
        if (selectedClassID.isEmpty() || !licenseEvidence.isVoid()) return;
        clearLicenseCandidate(false);
        auto* evidence = new DynamicObject();
        evidence->setProperty("state", "needsActivation");
        evidence->setProperty("rule", String(std::string(rule)));
        evidence->setProperty("classID", selectedClassID);
        evidence->setProperty("name", pluginName);
        evidence->setProperty("observedAt", observedAt);
        evidence->setProperty("observations", observations);
        licenseEvidence = var(evidence);
        // Evidence is historical and monotonic for this session. Disappearance
        // of a label is never interpreted as successful activation.
        report(lastState, lastMessage);
    }

    void clearLicenseCandidate(bool notify = true)
    {
        const bool changed = !candidateRule.empty();
        candidateRule.clear(); candidateObservedAt = 0.0; candidateProbeAt = 0.0;
        if (notify && changed) report(lastState, lastMessage);
    }

    void writeHeartbeat()
    {
        auto* obj = new DynamicObject();
        obj->setProperty("pid", int(getpid()));
        obj->setProperty("timestamp", Time::getCurrentTime().toMilliseconds() / 1000.0);
        heartbeatFile.replaceWithText(JSON::toString(var(obj)));
    }

    void startWatchdog()
    {
        watchdog = std::thread([this]
        {
            using Clock = std::chrono::steady_clock;
            auto orphanDeadline = Clock::time_point::max();
            auto shutdownDeadline = Clock::time_point::max();
            const auto scanDeadline = scanMode ? Clock::now() + std::chrono::seconds(35) : Clock::time_point::max();
            while (!stopWatchdog.load())
            {
                const auto now = Clock::now();
                if (scanMode && now >= scanDeadline - std::chrono::seconds(2)) scanExpiryRequested.store(true);
                // Absolute limit: neither a nested modal loop nor continuing
                // heartbeats can extend an unattended scan's lifetime.
                if (now >= scanDeadline) _exit(74);
                if (getppid() != parent && !parentLost.exchange(true))
                    orphanDeadline = now + std::chrono::seconds(2);
                // A parent crash leaves nobody available to terminate a blocked
                // plug-in. Exit only this helper after allowing normal teardown.
                // The deadline never depends on the plug-in's UI event loop.
                if (now >= orphanDeadline) _exit(72);
                if (shutdownStarted.load() && shutdownDeadline == Clock::time_point::max())
                    shutdownDeadline = now + std::chrono::seconds(8);
                // Also bound an editor/processor destructor that hangs after the
                // user closes this helper's own window. No external PID is killed.
                if (now >= shutdownDeadline) _exit(73);
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
            }
        });
    }

    class Window final : public DocumentWindow
    {
    public:
        Window(const String& name, Host& h, bool scan)
            : DocumentWindow(name, Colour(0xff242830), DocumentWindow::allButtons, false), host(h), passive(scan)
        {
            setUsingNativeTitleBar(true);
            setWantsKeyboardFocus(!passive);
            addToDesktop();
        }
        int getDesktopWindowStyleFlags() const override
        {
            auto flags = DocumentWindow::getDesktopWindowStyleFlags();
            if (passive) flags |= ComponentPeer::windowIgnoresKeyPresses | ComponentPeer::windowIgnoresMouseClicks;
            return flags;
        }
        void closeButtonPressed() override { host.requestQuit(); }
        Host& host;
        const bool passive;
    };
    void keepScanWindowBehind()
    {
        if (scanMode && window && window->getPeer())
            PluginAuthLicense::orderScanWindowBehind(window->getPeer()->getNativeHandle());
    }
    File statusFile;
    File heartbeatFile;
    File quitFile;
    var config;
    int parent = 0;
    bool scanMode = false;
    bool instantiating = false;
    String lastError;
    String selectedClassID, lastState, lastMessage;
    String terminationReason;
    var licenseEvidence;
    double nextProbeAt = 0.0;
    std::string candidateRule;
    double candidateObservedAt = 0.0, candidateProbeAt = 0.0;
    std::atomic<bool> scanExpiryRequested { false };
    std::atomic<bool> quitting { false }, parentLost { false }, shutdownStarted { false }, stopWatchdog { false };
    std::thread watchdog;
    String pluginName;
    AudioPluginFormatManager formats;
    OwnedArray<PluginDescription> descriptions;
    std::unique_ptr<AudioPluginInstance> plugin;
    OwnedArray<Component> controls;
    std::unique_ptr<Window> window;
};
START_JUCE_APPLICATION(Host)
#else
#include <cassert>
#include <iostream>
int main()
{
    using namespace HostRequestPolicy;
    assert(parseMode("") == Mode::manual);
    assert(parseMode("manual") == Mode::manual);
    assert(parseMode("scan") == Mode::scan);
    assert(parseMode("SCAN") == Mode::invalid);
    assert(parseMode("anything-else") == Mode::invalid);
    assert(hasSafeJSONEnvelope(R"({"name":"日本語 🎛️ [quoted]", "escaped":"\\\"{"})"));
    assert(hasSafeJSONEnvelope(std::string(maxRequestDepth, '[') + "0" + std::string(maxRequestDepth, ']')));
    assert(!hasSafeJSONEnvelope(std::string(30000, '[') + "0" + std::string(30000, ']')));
    assert(!hasSafeJSONEnvelope("{[}]"));
    assert(!hasSafeJSONEnvelope("{\"name\":\"unterminated}"));
    assert(!hasSafeJSONEnvelope(std::string("{}\0[]", 5)));
    assert(!hasSafeJSONEnvelope(std::string(maxRequestBytes + 1, ' ')));
    const std::vector<std::string> classes {"exact-first", "exact-second"};
    assert(chooseClass(classes, "", false) == -1);
    assert(chooseClass(classes, "", true) == 0);
    assert(chooseClass(classes, "exact-second", true) == 1);
    assert(chooseClass(classes, "exact-second", false) == 1);
    assert(chooseClass(classes, "Exact-Second", true) == -2);
    assert(chooseClass(classes, "missing", false) == -2);
    assert(chooseClass({}, "", true) == -2);
    assert(chooseClass({"only"}, "", false) == 0);
    const std::string unauthorized = "An OS error occurred during initialisation of the plug-in (-10847)";
    assert(isAUUnauthorized("AU", "selected-class", unauthorized));
    assert(!isAUUnauthorized("VST3", "selected-class", unauthorized));
    assert(!isAUUnauthorized("au", "selected-class", unauthorized));
    assert(!isAUUnauthorized("AU", "", unauthorized));
    assert(!isAUUnauthorized("AU", "selected-class", "An OS error occurred during initialisation of the plug-in (-10846)"));
    assert(!isAUUnauthorized("AU", "selected-class", "Unable to initialise the AudioUnit plug-in"));
    assert(!isAUUnauthorized("AU", "selected-class", "Unable to load VST-3 plug-in file"));
    assert(!isAUUnauthorized("AU", "selected-class", unauthorized + " extra text"));
    assert(!isAUUnauthorized("AU", "selected-class", "-10847"));
    assert(!isAUUnauthorized("AU", "selected-class", ""));
    std::cout << "PASS: 30 request bounds, mode, exact class-selection, and AU authorization policy cases\n";
}
#endif
