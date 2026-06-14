//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <flutter_midi_command_windows/flutter_midi_command_windows_plugin.h>
#include <universal_ble/universal_ble_plugin_c_api.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  FlutterMidiCommandWindowsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterMidiCommandWindowsPlugin"));
  UniversalBlePluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("UniversalBlePluginCApi"));
}
