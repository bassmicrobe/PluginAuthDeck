# SPDX-License-Identifier: AGPL-3.0-only
cmake_minimum_required(VERSION 3.22)
project(PluginAuthDesk VERSION 1.3.3)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OSX_DEPLOYMENT_TARGET 12.0)
add_subdirectory(JUCE EXCLUDE_FROM_ALL)
juce_add_gui_app(AuthPluginHost PRODUCT_NAME "AuthPluginHost"
    BUNDLE_ID "local.plugin-auth-desk.host" COMPANY_NAME "Local Tools"
    NEEDS_WEB_BROWSER FALSE NEEDS_CURL FALSE)
target_sources(AuthPluginHost PRIVATE Host.cpp LicenseProbe.mm)
target_compile_definitions(AuthPluginHost PRIVATE JUCE_PLUGINHOST_VST3=1
    JUCE_PLUGINHOST_AU=1 JUCE_PLUGINHOST_VST=0 JUCE_PLUGINHOST_LADSPA=0
    JUCE_PLUGINHOST_LV2=0 JUCE_WEB_BROWSER=0 JUCE_USE_CURL=0
    JUCE_APPLICATION_NAME_STRING="AuthPluginHost"
    JUCE_APPLICATION_VERSION_STRING="1.3.3")
target_link_libraries(AuthPluginHost PRIVATE juce::juce_audio_processors
    juce::juce_gui_extra juce::juce_recommended_config_flags "-framework CoreAudioKit")
