// SPDX-License-Identifier: AGPL-3.0-only
// Synthetic integration fixture. This is not a commercially licensed plug-in.
// It never opens an audio/MIDI device, performs network I/O, or reads licenses.
#include <juce_audio_processors/juce_audio_processors.h>
#include <juce_gui_extra/juce_gui_extra.h>

class FixtureProcessor final : public juce::AudioProcessor
{
public:
    FixtureProcessor() : AudioProcessor(BusesProperties()
        .withInput("Input", juce::AudioChannelSet::stereo(), true)
        .withOutput("Output", juce::AudioChannelSet::stereo(), true)) {}
    const juce::String getName() const override { return "Plugin Auth Desk Fixture"; }
    void prepareToPlay(double, int) override {}
    void releaseResources() override {}
    void processBlock(juce::AudioBuffer<float>& buffer, juce::MidiBuffer&) override { buffer.clear(); }
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
};

class FixtureEditor final : public juce::AudioProcessorEditor, private juce::Timer
{
public:
    explicit FixtureEditor(FixtureProcessor& processor) : AudioProcessorEditor(processor)
    {
        const int delay = juce::jlimit(0, 15000, juce::SystemStats::getEnvironmentVariable("PAD_FIXTURE_DELAY_MS", "0").getIntValue());
        const auto clearPath = juce::SystemStats::getEnvironmentVariable("PAD_FIXTURE_CLEAR_REQUEST", "");
        if (juce::File::isAbsolutePath(clearPath)) clearRequest = juce::File(clearPath);
        showAt = juce::Time::getMillisecondCounterHiRes() + delay;
        shown = delay == 0;
        label.setText(shown ? statusText : "Fixture status pending", juce::dontSendNotification);
        label.setEditable(false, false, false);
        label.setJustificationType(juce::Justification::centred);
        addAndMakeVisible(label);
        setSize(640, 140);
        if (!shown || clearRequest != juce::File()) startTimer(100);
    }
    void resized() override { label.setBounds(getLocalBounds().reduced(16)); }
private:
    void timerCallback() override
    {
        // The runner supplies a path inside its temporary test directory. This
        // is a fixture-only control signal, never a vendor/user license file.
        if (clearRequest != juce::File() && clearRequest.existsAsFile())
        {
            label.setText("Fixture status cleared", juce::dontSendNotification);
            stopTimer();
            return;
        }
        if (!shown && juce::Time::getMillisecondCounterHiRes() >= showAt)
        {
            shown = true;
            label.setText(statusText, juce::dontSendNotification);
            if (clearRequest == juce::File()) stopTimer();
        }
    }
    const juce::String statusText = "Plugin Auth Desk Fixture is not activated on this machine";
    juce::File clearRequest;
    double showAt = 0.0;
    bool shown = false;
    juce::Label label;
};

juce::AudioProcessorEditor* FixtureProcessor::createEditor() { return new FixtureEditor(*this); }
juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter() { return new FixtureProcessor(); }
