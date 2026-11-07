// SPDX-License-Identifier: AGPL-3.0-only
#include <string>
#include <string_view>
#include <vector>
#include <array>
#include <cstdint>
#include <cmath>
#include <limits>

namespace HostRequestPolicy
{
constexpr std::size_t maxRequestBytes = 65536;
constexpr std::size_t maxRequestDepth = 32;

int workerParentPID(std::string_view text)
{
    // Command-line integers must be canonical positive decimal values, never
    // prefixes accepted by intValue (such as "123junk") or overflowing casts.
    if (text.empty() || text.size() > 10 || text.front() == '0') return -1;
    int value = 0;
    for (const auto character : text)
    {
        if (character < '0' || character > '9') return -1;
        const int digit = character - '0';
        if (value > (std::numeric_limits<int>::max() - digit) / 10) return -1;
        value = value * 10 + digit;
    }
    return value > 1 ? value : -1;
}

int scanDeadline(double requested, bool present)
{
    if (!present) return 35;
    return std::isfinite(requested) && requested >= 35 && requested <= 90
        && std::floor(requested) == requested ? static_cast<int>(requested) : -1;
}

double probePollDelayMilliseconds(bool pending) { return pending ? 250.0 : 2000.0; }
constexpr int scanSoftQuitMarginSeconds = 1;

// Match JUCE's macOS normalized FUID hash without constructing a component.
int vstClassUID(const unsigned char* bytes)
{
    std::uint32_t hash = 0;
    for (int i = 0; i < 16; i += 4)
    {
        const auto word = (std::uint32_t(bytes[i]) << 24) | (std::uint32_t(bytes[i + 1]) << 16)
            | (std::uint32_t(bytes[i + 2]) << 8) | std::uint32_t(bytes[i + 3]);
        hash = hash * 31 + word;
    }
    return static_cast<int>(hash);
}

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
#include <map>
#include <sys/stat.h>
#include <thread>
#include <unistd.h>
#include <AudioToolbox/AudioToolbox.h>
#include <CoreFoundation/CoreFoundation.h>
#include <pluginterfaces/base/ipluginbase.h>
#include <pluginterfaces/vst/ivsthostapplication.h>
#include <public.sdk/source/vst/moduleinfo/moduleinfoparser.h>
#include "LicenseProbe.h"
using namespace juce;

namespace
{
double unixNow() { return Time::getCurrentTime().toMilliseconds() / 1000.0; }
double steadyMilliseconds()
{
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

template <std::size_t N> String boundedText(const char (&text)[N])
{
    return String::fromUTF8(text, static_cast<int>(strnlen(text, N)));
}
template <std::size_t N> String boundedText(const Steinberg::char16 (&text)[N])
{
    std::size_t length = 0;
    while (length < N && text[length] != 0) ++length;
    return String(CharPointer_UTF16(reinterpret_cast<const CharPointer_UTF16::CharType*>(text)), length);
}

// Factory metadata queries need a host identity (notably for shell factories).
// This context cannot create processors, controllers, audio, or MIDI objects.
struct MetadataHostContext final : Steinberg::Vst::IHostApplication
{
    Steinberg::tresult PLUGIN_API queryInterface(const Steinberg::TUID iid, void** result) override
    {
        if (!result) return Steinberg::kInvalidArgument;
        *result = nullptr;
        if (std::memcmp(iid, Steinberg::FUnknown_iid, 16) != 0
            && std::memcmp(iid, Steinberg::Vst::IHostApplication_iid, 16) != 0) return Steinberg::kNoInterface;
        *result = static_cast<Steinberg::Vst::IHostApplication*>(this);
        addRef();
        return Steinberg::kResultOk;
    }
    Steinberg::uint32 PLUGIN_API addRef() override { return ++references; }
    Steinberg::uint32 PLUGIN_API release() override { return --references; }
    Steinberg::tresult PLUGIN_API getName(Steinberg::Vst::String128 name) override
    {
        std::fill_n(name, 128, 0);
        constexpr char identity[] = "AuthPluginHost";
        std::copy(std::begin(identity), std::end(identity), name);
        return Steinberg::kResultOk;
    }
    Steinberg::tresult PLUGIN_API createInstance(Steinberg::TUID, Steinberg::TUID, void** object) override
    {
        if (object) *object = nullptr;
        return Steinberg::kNotImplemented;
    }
    std::atomic<Steinberg::uint32> references { 1 };
};

// Unlike JUCE findAllTypesForFile's slow path, this never calls factory
// createInstance/component.initialize for any sibling class. Keep the module
// alive until the selected JUCE instance has been destroyed.
class VSTMetadataModule
{
public:
    ~VSTMetadataModule()
    {
        if (factory3) factory3->release();
        if (factory2) factory2->release();
        if (factory) factory->release();
        if (entered && bundle)
            if (auto exit = reinterpret_cast<bool (*)()>(CFBundleGetFunctionPointerForName(bundle, CFSTR("bundleExit")))) exit();
        if (bundle) CFRelease(bundle);
    }
    bool enumerate(const File& file, OwnedArray<PluginDescription>& result)
    {
        if (!file.isDirectory() || !file.hasFileExtension("vst3")) return false;
        // Preserve JUCE's fast-path names and IDs exactly when the bundle ships
        // moduleinfo (including its SDK-supported trailing-comma JSON syntax).
        for (const auto* location : {"Contents/Resources/moduleinfo.json", "Contents/moduleinfo.json"})
            if (readModuleInfo(file, file.getChildFile(location), result)) return true;
        const auto path = file.getFullPathName().toUTF8();
        auto url = CFURLCreateFromFileSystemRepresentation(nullptr, reinterpret_cast<const UInt8*>(path.getAddress()),
                                                         static_cast<CFIndex>(path.sizeInBytes() - 1), true);
        if (!url) return false;
        bundle = CFBundleCreate(nullptr, url);
        CFRelease(url);
        if (!bundle || !CFBundleLoadExecutable(bundle)) return false;
        const auto enter = reinterpret_cast<bool (*)(CFBundleRef)>(CFBundleGetFunctionPointerForName(bundle, CFSTR("bundleEntry")));
        if (!enter || !enter(bundle)) return false;
        entered = true;
        const auto getFactory = reinterpret_cast<Steinberg::IPluginFactory* (*)()>(CFBundleGetFunctionPointerForName(bundle, CFSTR("GetPluginFactory")));
        if (!getFactory || !(factory = getFactory())) return false;
        factory->queryInterface(Steinberg::IPluginFactory2_iid, reinterpret_cast<void**>(&factory2));
        factory->queryInterface(Steinberg::IPluginFactory3_iid, reinterpret_cast<void**>(&factory3));
        if (factory3) factory3->setHostContext(&context);
        Steinberg::PFactoryInfo factoryInfo {};
        factory->getFactoryInfo(&factoryInfo);
        const auto count = factory->countClasses();
        if (count < 0 || count > 4096) return false;
        for (int i = 0; i < count; ++i)
        {
            Steinberg::PClassInfo info {};
            if (factory->getClassInfo(i, &info) != Steinberg::kResultOk) return false;
            if (boundedText(info.category) != "Audio Module Class") continue;
            auto description = std::make_unique<PluginDescription>();
            description->name = boundedText(info.name).trim();
            if (description->name.isEmpty()) return false;
            description->descriptiveName = description->name;
            description->fileOrIdentifier = file.getFullPathName();
            description->lastFileModTime = file.getLastModificationTime();
            description->lastInfoUpdateTime = Time::getCurrentTime();
            description->pluginFormatName = "VST3";
            description->manufacturerName = boundedText(factoryInfo.vendor);
            description->uniqueId = HostRequestPolicy::vstClassUID(reinterpret_cast<const unsigned char*>(info.cid));
            std::uint32_t legacyHash = 0;
            for (const auto byte : info.cid) legacyHash = legacyHash * 31 + static_cast<std::uint32_t>(byte);
            description->deprecatedUid = static_cast<int>(legacyHash);
            Steinberg::PClassInfoW unicode {};
            Steinberg::PClassInfo2 extended {};
            if (factory3 && factory3->getClassInfoUnicode(i, &unicode) == Steinberg::kResultOk)
            {
                description->version = boundedText(unicode.version).trim();
                description->category = boundedText(unicode.subCategories).trim();
                if (description->manufacturerName.trim().isEmpty()) description->manufacturerName = boundedText(unicode.vendor).trim();
            }
            else if (factory2 && factory2->getClassInfo2(i, &extended) == Steinberg::kResultOk)
            {
                description->version = boundedText(extended.version).trim();
                description->category = boundedText(extended.subCategories).trim();
                if (description->manufacturerName.trim().isEmpty()) description->manufacturerName = boundedText(extended.vendor).trim();
            }
            if (description->category.isEmpty()) description->category = boundedText(info.category).trim();
            description->isInstrument = description->category.containsIgnoreCase("Instrument");
            result.add(description.release());
        }
        return true;
    }
private:
    static bool readModuleInfo(const File& file, const File& metadata, OwnedArray<PluginDescription>& result)
    {
        constexpr int maximumBytes = 4 * 1024 * 1024;
        if (!metadata.existsAsFile() || metadata.getSize() <= 0 || metadata.getSize() > maximumBytes) return false;
        FileInputStream input(metadata);
        if (!input.openedOk()) return false;
        MemoryBlock bytes;
        input.readIntoMemoryBlock(bytes, maximumBytes + 1);
        if (bytes.getSize() > maximumBytes) return false;
        const auto parsed = Steinberg::ModuleInfoLib::parseJson({static_cast<const char*>(bytes.getData()), bytes.getSize()}, nullptr);
        if (!parsed || parsed->classes.size() > 4096) return false;
        OwnedArray<PluginDescription> validated;
        for (const auto& entry : parsed->classes)
        {
            if (entry.category != "Audio Module Class") continue;
            if (entry.cid.size() != 32 || entry.name.empty()) return false;
            std::array<unsigned char, 16> cid {};
            bool valid = true;
            for (std::size_t i = 0; i < cid.size(); ++i)
            {
                const auto high = CharacterFunctions::getHexDigitValue(entry.cid[i * 2]);
                const auto low = CharacterFunctions::getHexDigitValue(entry.cid[i * 2 + 1]);
                if (high < 0 || low < 0) { valid = false; break; }
                cid[i] = static_cast<unsigned char>(high * 16 + low);
            }
            if (!valid) return false;
            auto description = std::make_unique<PluginDescription>();
            description->name = String::fromUTF8(entry.name.c_str());
            if (description->name.trim().isEmpty()) return false;
            description->descriptiveName = description->name;
            description->fileOrIdentifier = file.getFullPathName();
            description->lastFileModTime = file.getLastModificationTime();
            description->lastInfoUpdateTime = Time::getCurrentTime();
            description->pluginFormatName = "VST3";
            description->manufacturerName = String::fromUTF8(parsed->factoryInfo.vendor.c_str());
            description->version = String::fromUTF8(entry.version.c_str());
            description->uniqueId = HostRequestPolicy::vstClassUID(cid.data());
            std::uint32_t legacyHash = 0;
            for (const auto byte : cid) legacyHash = legacyHash * 31 + static_cast<std::uint32_t>(static_cast<char>(byte));
            description->deprecatedUid = static_cast<int>(legacyHash);
            StringArray categories;
            for (const auto& category : entry.subCategories) categories.add(String::fromUTF8(category.c_str()));
            description->category = categories.joinIntoString("|");
            description->isInstrument = categories.contains("Instrument");
            validated.add(description.release());
        }
        if (validated.isEmpty()) return false;
        result.addArray(validated);
        validated.clear(false);
        return true;
    }
    MetadataHostContext context;
    CFBundleRef bundle = nullptr;
    bool entered = false;
    Steinberg::IPluginFactory* factory = nullptr;
    Steinberg::IPluginFactory2* factory2 = nullptr;
    Steinberg::IPluginFactory3* factory3 = nullptr;
};

bool enumerateAU(const String& identifier, OwnedArray<PluginDescription>& result)
{
    if (!identifier.startsWithIgnoreCase("AudioUnit:")) return false;
    StringArray tokens;
    tokens.addTokens(identifier.substring(jmax(identifier.lastIndexOfChar(':'), identifier.lastIndexOfChar('/')) + 1), ",", "");
    tokens.removeEmptyStrings();
    if (tokens.size() != 3) return false;
    const auto fourCC = [](String text)
    {
        if (text.trim().length() >= 4) text = text.trim();
        text += "    ";
        return (UInt32(static_cast<unsigned char>(text[0])) << 24) | (UInt32(static_cast<unsigned char>(text[1])) << 16)
             | (UInt32(static_cast<unsigned char>(text[2])) << 8) | UInt32(static_cast<unsigned char>(text[3]));
    };
    AudioComponentDescription componentDescription {fourCC(tokens[0]), fourCC(tokens[1]), fourCC(tokens[2]), 0, 0};
    const auto component = AudioComponentFindNext(nullptr, &componentDescription);
    if (!component) return true;
    auto description = std::make_unique<PluginDescription>();
    CFStringRef name = nullptr;
    if (AudioComponentCopyName(component, &name) == noErr && name)
    {
        description->name = String::fromCFString(name);
        CFRelease(name);
    }
    if (description->name.containsChar(':'))
    {
        description->manufacturerName = description->name.upToFirstOccurrenceOf(":", false, false).trim();
        description->name = description->name.fromFirstOccurrenceOf(":", false, false).trim();
    }
    if (description->name.isEmpty()) description->name = "<Unknown>";
    if (description->manufacturerName.isEmpty()) description->manufacturerName = tokens[2];
    description->descriptiveName = description->name;
    description->pluginFormatName = "AudioUnit";
    const auto type = componentDescription.componentType;
    const String group = type == kAudioUnitType_MusicDevice ? "Synths/"
        : (type == kAudioUnitType_MusicEffect || type == kAudioUnitType_Effect) ? "Effects/"
        : type == kAudioUnitType_Generator ? "Generators/" : type == kAudioUnitType_Panner ? "Panners/"
        : type == kAudioUnitType_Mixer ? "Mixers/" : type == kAudioUnitType_MIDIProcessor ? "MidiEffects/" : "";
    const auto textCC = [](UInt32 code)
    {
        const juce_wchar text[] = {static_cast<juce_wchar>((code >> 24) & 255), static_cast<juce_wchar>((code >> 16) & 255),
                                   static_cast<juce_wchar>((code >> 8) & 255), static_cast<juce_wchar>(code & 255)};
        return String(text, 4);
    };
    description->fileOrIdentifier = "AudioUnit:" + group + textCC(type) + "," + textCC(componentDescription.componentSubType)
        + "," + textCC(componentDescription.componentManufacturer);
    description->uniqueId = description->deprecatedUid = static_cast<int>(type ^ componentDescription.componentSubType ^ componentDescription.componentManufacturer);
    description->isInstrument = type == kAudioUnitType_MusicDevice;
    description->lastInfoUpdateTime = Time::getCurrentTime();
    UInt32 version = 0;
    if (AudioComponentGetVersion(component, &version) == noErr)
        description->version = String(version >> 16) + "." + String((version >> 8) & 255) + "." + String(version & 255);
    result.add(description.release());
    return true;
}

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
        { fail("Invalid launch request", "invalid_request"); return; }
        config = JSON::parse(String::fromUTF8(bytes->data(), static_cast<int>(bytes->size())));
        const auto mode = HostRequestPolicy::parseMode(config["mode"].toString().toStdString());
        scanMode = mode == HostRequestPolicy::Mode::scan;
        if (mode == HostRequestPolicy::Mode::invalid) { fail("Invalid launch mode", "invalid_request"); return; }
        const auto requestedDeadline = config["scanDeadlineSeconds"];
        const bool hasDeadline = !requestedDeadline.isVoid();
        scanDeadlineSeconds = HostRequestPolicy::scanDeadline(double(requestedDeadline), hasDeadline);
        if (scanDeadlineSeconds < 0 || (hasDeadline && !requestedDeadline.isInt() && !requestedDeadline.isInt64() && !requestedDeadline.isDouble()))
        { fail("Invalid scan deadline", "invalid_request"); return; }
        parent = int(config["parentPID"]);
        pluginName = config["name"].toString();
        // A saved PID can be reused after a crash. Our actual parent relationship
        // identifies the launcher's lifetime, without probing/signalling that PID.
        if (parent <= 1 || parent != getppid() || pluginName.isEmpty()) { fail("Invalid launch request", "invalid_request"); return; }
        startWatchdog();
        if (scanMode) PluginAuthLicense::configureBackgroundScan();
        else Process::makeForegroundProcess();
        setPhase("enumerating");
        report("loading", "Reading selected plug-in metadata");
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
        // 250 ms scheduling bounds probe jitter below the parent's 2.5 s grace;
        // heartbeat writes and actual inspections retain their own 1 s / 2 s rate.
        startTimer(250);
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
        else { fail("Unsupported format", "unsupported_format"); return; }

        bool enumerated = false;
        const auto identifier = config["identifier"].toString();
        if (fmt == "VST3" && File::isAbsolutePath(identifier))
        {
            metadataModule = std::make_unique<VSTMetadataModule>();
            enumerated = metadataModule->enumerate(File(identifier), descriptions);
        }
        else if (fmt == "AU") enumerated = enumerateAU(identifier, descriptions);
        if (!enumerated)
        {
            descriptions.clear(); // Never publish an incomplete factory catalog.
            fail("Could not read plug-in class metadata.", "enumeration_failed"); return;
        }
        if (descriptions.isEmpty()) { fail("No compatible plug-in classes were found.", "no_plugin_classes"); return; }

        const auto requestedClass = config["classID"].toString();
        std::vector<std::string> availableClasses;
        for (const auto* description : descriptions)
            availableClasses.push_back(description->createIdentifierString().toStdString());
        const auto selection = HostRequestPolicy::chooseClass(availableClasses, requestedClass.toStdString(), scanMode);
        if (selection >= 0) { instantiate(selection); return; }
        if (selection == -2)
        {
            fail("The requested plug-in class is no longer available. Refresh the plug-in list.", "requested_class_missing");
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
        setPhase("creating_instance");
        report("loading", "Creating selected plug-in");
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
                    fail(error.isNotEmpty() ? error : "Plug-in creation failed", "instance_creation_failed");
                    return;
                }
                plugin = std::move(instance);
                setPhase("creating_editor");
                report("loading", "Creating plug-in window");
                auto* editor = plugin->createEditorAndMakeActive();
                if (!editor) { fail("This plug-in has no custom editor. Use its manufacturer's license app.", "no_custom_editor"); return; }
                window->setName(pluginName + " — Plugin Auth Desk");
                window->setContentOwned(editor, true);
                window->setResizable(editor->isResizable(), false);
                window->centreWithSize(editor->getWidth(), editor->getHeight() + window->getTitleBarHeight());
                window->setVisible(true);
                if (scanMode) keepScanWindowBehind();
                else window->toFront(true);
                readyAt = unixNow();
                setPhase("observing");
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
        if (scanMode) obj->setProperty("scanDeadlineSeconds", scanDeadlineSeconds);
        obj->setProperty("phase", phase);
        obj->setProperty("lastActivePhase", lastActivePhase);
        obj->setProperty("phaseStartedAt", phaseStartedAt);
        obj->setProperty("phaseElapsedSeconds", jmax(0.0, (steadyMilliseconds() - phaseStartedSteady) / 1000.0));
        auto* durations = new DynamicObject();
        for (const auto& item : phaseDurations) durations->setProperty(item.first, item.second);
        obj->setProperty("phaseDurations", var(durations));
        if (readyAt > 0.0) obj->setProperty("readyAt", readyAt);
        if (failureReason.isNotEmpty()) obj->setProperty("failureReason", failureReason);
        if (probeDiagnostic.isNotEmpty()) obj->setProperty("probeDiagnostic", probeDiagnostic);
        obj->setProperty("probeStaticTextNodes", probeStaticTextNodes);
        obj->setProperty("probeMaskedRegions", probeMaskedRegions);
        obj->setProperty("probePending", probePending);
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
    void fail(const String& message, const String& reason)
    {
        clearLicenseCandidate(false);
        lastError = message;
        failureReason = reason;
        setPhase("error");
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
        if (steadyMilliseconds() - lastHeartbeatAt >= 1000.0) writeHeartbeat();
        probeLicenseState();
    }
    void requestQuit()
    {
        if (quitting.exchange(true)) return;
        setPhase("closing");
        report("stopping", "Closing plug-in");
        quit();
    }
    void systemRequestedQuit() override { requestQuit(); }
    void shutdown() override
    {
        quitting.store(true);
        shutdownStarted.store(true);
        stopTimer();
        setPhase("closing");
        report("stopping", "Closing plug-in");
        window.reset(); // editor must die before processor
        controls.clear();
        plugin.reset();
        metadataModule.reset();
        setPhase("closed");
        report("closed", "Window closed");
        stopWatchdog.store(true);
        if (watchdog.joinable()) watchdog.join();
    }
private:
    void setPhase(const String& next)
    {
        if (phase == next) return;
        const auto now = steadyMilliseconds();
        if (phase.isNotEmpty()) phaseDurations[phase] += jmax(0.0, (now - phaseStartedSteady) / 1000.0);
        phase = next;
        phaseStartedAt = unixNow();
        phaseStartedSteady = now;
        if (next == "enumerating" || next == "creating_instance" || next == "creating_editor" || next == "observing")
            lastActivePhase = next;
    }

    void probeLicenseState(bool immediately = false)
    {
        if (quitting.load() || !instantiating || selectedClassID.isEmpty() || !licenseEvidence.isVoid()
            || lastState == "error" || lastState == "closed" || lastState == "stopping") return;
        const auto now = Time::getMillisecondCounterHiRes();
        if (!immediately && now < nextProbeAt) return;
        // The product identity is fixed before asynchronous instantiation, so
        // activation dialogs in its nested native event loop can also be seen.
        // Scanner dialogs before a class is selected remain unattributed/unknown.
        const auto result = PluginAuthLicense::inspectOwnVisibleWindows(pluginName.toStdString(), {}, scanMode);
        // Poll an existing async job promptly. The probe permits one job and
        // one consumed result at a time; completed/native samples resume the
        // ordinary cadence. Frame timestamps still enforce separated evidence.
        nextProbeAt = now + HostRequestPolicy::probePollDelayMilliseconds(result.pending);
        const auto diagnostic = String(result.diagnostic);
        const bool diagnosticChanged = probeDiagnostic != diagnostic || probePending != result.pending || probeStaticTextNodes != result.staticTextNodes
            || probeMaskedRegions != result.maskedRegions;
        probeDiagnostic = diagnostic;
        probeStaticTextNodes = result.staticTextNodes;
        probeMaskedRegions = result.maskedRegions;
        probePending = result.pending;
        if (diagnosticChanged) report(lastState, lastMessage);
        if (result.pending) return; // An in-flight OCR capture is not a negative observation.
        const auto sampledAt = result.sampledAtMilliseconds > 0 ? result.sampledAtMilliseconds : steadyMilliseconds();
        if (!std::isfinite(sampledAt) || sampledAt <= lastProbeSampleAt) return;
        lastProbeSampleAt = sampledAt; // A cached OCR image can never count twice.
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
                candidateProbeAt = sampledAt;
                report(lastState, lastMessage);
                return;
            }
            // A loading/authentication spinner can briefly show "unlicensed".
            // Automatic scans require the same explicit status on two separated
            // observations; absence or a different rule resets the candidate.
            if (sampledAt - candidateProbeAt < 1500.0) return;
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
        lastHeartbeatAt = steadyMilliseconds();
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
            const auto scanDeadline = scanMode ? Clock::now() + std::chrono::seconds(scanDeadlineSeconds) : Clock::time_point::max();
            while (!stopWatchdog.load())
            {
                const auto now = Clock::now();
                // The parent can observe until loadBudget + 6 + 2.5 seconds;
                // hardBudget is loadBudget + 10. Preserve that complete window.
                if (scanMode && now >= scanDeadline - std::chrono::seconds(HostRequestPolicy::scanSoftQuitMarginSeconds)) scanExpiryRequested.store(true);
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
    int scanDeadlineSeconds = 35;
    bool instantiating = false;
    String lastError;
    String selectedClassID, lastState, lastMessage;
    String terminationReason;
    String phase, lastActivePhase, failureReason, probeDiagnostic;
    std::map<String, double> phaseDurations;
    double phaseStartedAt = 0.0, phaseStartedSteady = steadyMilliseconds(), readyAt = 0.0;
    double lastHeartbeatAt = 0.0, lastProbeSampleAt = 0.0;
    int probeStaticTextNodes = 0, probeMaskedRegions = 0;
    bool probePending = false;
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
    std::unique_ptr<VSTMetadataModule> metadataModule;
    std::unique_ptr<AudioPluginInstance> plugin;
    OwnedArray<Component> controls;
    std::unique_ptr<Window> window;
};
JUCE_CREATE_APPLICATION_DEFINE(Host)

int main(int argc, char* argv[])
{
    // OCR work and synthetic model preparation are not JUCE GUI applications.
    // Dispatch before main initializes NSApplication, MessageManager or Host.
    const auto command = argc > 1 && argv[1] != nullptr ? std::string_view(argv[1]) : std::string_view();
    if (command == "--ocr-worker" || command == "--ocr-warmup")
    {
        const auto expectedParent = argc == 3 && argv[2] != nullptr
            ? HostRequestPolicy::workerParentPID(argv[2]) : -1;
        if (expectedParent <= 1 || expectedParent != getppid()) return 2;
        return command == "--ocr-warmup" ? PluginAuthLicense::runNativeOCRWarmup(expectedParent)
                                          : PluginAuthLicense::runNativeOCRWorker(expectedParent);
    }
    juce::JUCEApplicationBase::createInstance = &juce_CreateApplication;
    return juce::JUCEApplicationBase::main(argc, const_cast<const char**>(argv));
}
#else
#include <cassert>
#include <iostream>
int main()
{
    using namespace HostRequestPolicy;
    assert(workerParentPID("2") == 2);
    assert(workerParentPID("123456") == 123456);
    assert(workerParentPID("2147483647") == std::numeric_limits<int>::max());
    for (const auto invalid : {"", "0", "1", "-2", "+2", "02", " 2", "2 ", "2.0", "2e3", "2junk",
                               "2147483648", "999999999999999999999999", "１２３"})
        assert(workerParentPID(invalid) == -1);
    assert(scanDeadline(0, false) == 35);
    assert(scanDeadline(35, true) == 35);
    assert(scanDeadline(70, true) == 70);
    assert(scanDeadline(90, true) == 90);
    assert(scanDeadline(34, true) == -1);
    assert(scanDeadline(91, true) == -1);
    assert(scanDeadline(70.5, true) == -1);
    assert(scanDeadline(std::nan(""), true) == -1);
    assert(scanDeadline(INFINITY, true) == -1);
    const unsigned char identity[] = {0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
                                     0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00};
    const auto expectedHash = ((std::uint32_t(0x11223344) * 31 + 0x55667788) * 31 + 0x99aabbcc) * 31 + 0xddeeff00;
    assert(vstClassUID(identity) == static_cast<int>(expectedHash));
    // Known existing moduleinfo CID / JUCE identifier suffix: preserve saved
    // class-specific inventory and license identities across this migration.
    const unsigned char orraID[] = {0xab, 0xcd, 0xef, 0x01, 0x91, 0x82, 0xfa, 0xeb,
                                    0x4f, 0x72, 0x41, 0x75, 0x4f, 0x72, 0x46, 0x69};
    assert(vstClassUID(orraID) == static_cast<int>(0x3cb0451e));
    assert(probePollDelayMilliseconds(true) == 250.0);
    assert(probePollDelayMilliseconds(false) == 2000.0);
    assert(35 - scanSoftQuitMarginSeconds > 25 + 6 + 2.5);
    assert(70 - scanSoftQuitMarginSeconds > 60 + 6 + 2.5);
    // A 2.1-second async recognition must finish two separated frames before
    // the six-second ready window. At the old 2-second polling cadence this
    // scenario consumed observations only at 4 and 8 seconds.
    const auto simulateAsyncProbe = [](bool fastPendingPoll)
    {
        double nextPoll = 0.0, jobCapture = -1.0, candidateCapture = -1.0;
        for (double clock = 0.0; clock <= 10000.0; clock += 250.0)
        {
            if (clock < nextPoll) continue;
            const bool completed = jobCapture >= 0.0 && clock >= jobCapture + 2100.0;
            if (completed)
            {
                const auto sample = jobCapture;
                jobCapture = clock; // The probe starts at most one successor.
                if (candidateCapture >= 0.0 && sample - candidateCapture >= 1500.0) return clock;
                candidateCapture = sample;
            }
            else if (jobCapture < 0.0) jobCapture = clock;
            nextPoll = clock + probePollDelayMilliseconds(fastPendingPoll && !completed);
        }
        return -1.0;
    };
    assert(simulateAsyncProbe(false) == 8000.0);
    assert(simulateAsyncProbe(true) == 4500.0);
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
    std::cout << "PASS: 64 worker PID, async timing, deadline, class identity, request bounds, mode, exact class-selection, and AU authorization policy cases\n";
}
#endif
