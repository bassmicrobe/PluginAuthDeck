// SPDX-License-Identifier: AGPL-3.0-only
// Synthetic integration fixture. This is not a commercially licensed plug-in.
// It never opens an audio/MIDI device, performs network I/O, or reads licenses.
#include <juce_audio_processors/juce_audio_processors.h>
#include <juce_gui_extra/juce_gui_extra.h>
#include <CoreFoundation/CoreFoundation.h>

namespace
{
void recordFixtureEvent(const char* event)
{
    const auto path = juce::SystemStats::getEnvironmentVariable("PAD_FIXTURE_EVENT_LOG", "");
    if (juce::File::isAbsolutePath(path)) juce::File(path).appendText(juce::String(event) + "\n");
}
}

class FixtureProcessor final : public juce::AudioProcessor
{
public:
    FixtureProcessor() : AudioProcessor(BusesProperties()
        .withInput("Input", juce::AudioChannelSet::stereo(), true)
        .withOutput("Output", juce::AudioChannelSet::stereo(), true)) { recordFixtureEvent("processor_created"); }
    const juce::String getName() const override { return "Plugin Auth Desk Fixture"; }
    void prepareToPlay(double, int) override
    {
        prepared = true; recordFixtureEvent("processor_initialized");
        const auto stopPath = juce::SystemStats::getEnvironmentVariable("PAD_FIXTURE_QUIT_DURING_INITIALIZATION", "");
        if (juce::File::isAbsolutePath(stopPath))
        {
            // Synthetic nested initialization loop. Only the runner's isolated
            // temporary stop file is written; no UI click/license is involved.
            juce::File(stopPath).replaceWithText("synthetic stop during initialization\n");
            recordFixtureEvent("stop_requested_during_initialization");
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.75, false);
            recordFixtureEvent("initialization_returned_after_nested_loop");
        }
    }
    void releaseResources() override { prepared = false; recordFixtureEvent("processor_released"); }
    void processBlock(juce::AudioBuffer<float>& buffer, juce::MidiBuffer&) override { recordFixtureEvent("audio_processed"); buffer.clear(); }
    bool acceptsMidi() const override { return false; }
    bool producesMidi() const override { return false; }
    double getTailLengthSeconds() const override { return 0; }
    int getNumPrograms() override { return 1; }
    int getCurrentProgram() override { return 0; }
    void setCurrentProgram(int) override {}
    const juce::String getProgramName(int) override { return "Fixture"; }
    void changeProgramName(int, const juce::String&) override {}
    void getStateInformation(juce::MemoryBlock&) override {}
    void setStateInformation(const void*, int) override {}
    bool hasEditor() const override { return true; }
    juce::AudioProcessorEditor* createEditor() override;
    bool isInitialized() const { return prepared; }
private:
    bool prepared = false;
};

class FixtureEditor final : public juce::AudioProcessorEditor, private juce::Timer
{
public:
    explicit FixtureEditor(FixtureProcessor& processor) : AudioProcessorEditor(processor)
    {
        recordFixtureEvent("editor_created");
        if (!processor.isInitialized()) recordFixtureEvent("editor_before_initialization");
        paintedOnly = juce::SystemStats::getEnvironmentVariable("PAD_FIXTURE_PAINTED", "0") == "1";
        const int delay = juce::jlimit(0, 15000, juce::SystemStats::getEnvironmentVariable("PAD_FIXTURE_DELAY_MS", "0").getIntValue());
        const auto clearPath = juce::SystemStats::getEnvironmentVariable("PAD_FIXTURE_CLEAR_REQUEST", "");
        if (juce::File::isAbsolutePath(clearPath)) clearRequest = juce::File(clearPath);
        showAt = juce::Time::getMillisecondCounterHiRes() + delay;
        shown = delay == 0;
        displayedText = shown ? statusText : "Fixture status pending";
        label.setText(displayedText, juce::dontSendNotification);
        label.setEditable(false, false, false);
        label.setJustificationType(juce::Justification::centred);
        if (!paintedOnly) addAndMakeVisible(label);
        else setAccessible(false); // No text node: the host must read painted pixels.
        setSize(paintedOnly ? 1080 : 640, paintedOnly ? 200 : 140);
        if (!shown || clearRequest != juce::File()) startTimer(100);
    }
    void resized() override { label.setBounds(getLocalBounds().reduced(16)); }
    void paint(juce::Graphics& graphics) override
    {
        if (!paintedOnly) return;
        graphics.fillAll(juce::Colours::white);
        graphics.setColour(juce::Colours::black);
        graphics.setFont(juce::FontOptions(24.0f));
        graphics.drawText(displayedText, getLocalBounds().reduced(20), juce::Justification::centred, false);
    }
private:
    void timerCallback() override
    {
        // The runner supplies a path inside its temporary test directory. This
        // is a fixture-only control signal, never a vendor/user license file.
        if (clearRequest != juce::File() && clearRequest.existsAsFile())
        {
            displayedText = "Fixture status cleared";
            label.setText(displayedText, juce::dontSendNotification);
            repaint();
            stopTimer();
            return;
        }
        if (!shown && juce::Time::getMillisecondCounterHiRes() >= showAt)
        {
            shown = true;
            displayedText = statusText;
            label.setText(displayedText, juce::dontSendNotification);
            repaint();
            if (clearRequest == juce::File()) stopTimer();
        }
    }
    const juce::String statusText = "Plugin Auth Desk Fixture is not activated on this machine";
    juce::File clearRequest;
    double showAt = 0.0;
    bool shown = false;
    bool paintedOnly = false;
    juce::String displayedText;
    juce::Label label;
};

juce::AudioProcessorEditor* FixtureProcessor::createEditor() { return new FixtureEditor(*this); }
juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter() { return new FixtureProcessor(); }
