# SPDX-License-Identifier: AGPL-3.0-only
cmake_minimum_required(VERSION 3.22)
project(PluginAuthDeskFixture VERSION 1.0.0)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OSX_DEPLOYMENT_TARGET 12.0)
set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64" CACHE STRING "" FORCE)
add_subdirectory(../../JUCE ${CMAKE_BINARY_DIR}/JUCE EXCLUDE_FROM_ALL)
juce_add_plugin(AuthDetectionFixture
    COMPANY_NAME "Plugin Auth Desk Test"
    BUNDLE_ID "local.plugin-auth-desk.test-fixture"
    PLUGIN_MANUFACTURER_CODE Padf
    PLUGIN_CODE Padf
    IS_SYNTH FALSE NEEDS_MIDI_INPUT FALSE NEEDS_MIDI_OUTPUT FALSE
    IS_MIDI_EFFECT FALSE EDITOR_WANTS_KEYBOARD_FOCUS FALSE
    COPY_PLUGIN_AFTER_BUILD FALSE
    FORMATS VST3
    PRODUCT_NAME "Plugin Auth Desk Fixture"
    NEEDS_WEB_BROWSER FALSE NEEDS_CURL FALSE)
target_sources(AuthDetectionFixture PRIVATE Fixture.cpp)
target_compile_definitions(AuthDetectionFixture PUBLIC
    JUCE_WEB_BROWSER=0 JUCE_USE_CURL=0 JUCE_VST3_CAN_REPLACE_VST2=0)
target_link_libraries(AuthDetectionFixture PRIVATE juce::juce_audio_processors
    juce::juce_gui_extra PUBLIC juce::juce_recommended_config_flags)
