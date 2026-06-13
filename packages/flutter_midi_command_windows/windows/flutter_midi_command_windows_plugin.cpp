#include "include/flutter_midi_command_windows/flutter_midi_command_windows_plugin.h"

#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <optional>

namespace {

constexpr WPARAM kDbtDeviceArrival = 0x8000;
constexpr WPARAM kDbtDeviceRemoveComplete = 0x8004;
constexpr WPARAM kDbtDevNodesChanged = 0x0007;

class FlutterMidiCommandWindowsPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  explicit FlutterMidiCommandWindowsPlugin(
      flutter::PluginRegistrarWindows* registrar);

  ~FlutterMidiCommandWindowsPlugin() override;

 private:
  std::optional<LRESULT> HandleWindowProc(HWND hwnd,
                                          UINT message,
                                          WPARAM wparam,
                                          LPARAM lparam);

  flutter::PluginRegistrarWindows* registrar_;
  int window_proc_id_ = -1;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

void FlutterMidiCommandWindowsPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin =
      std::make_unique<FlutterMidiCommandWindowsPlugin>(registrar);

  plugin->channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(),
          "flutter_midi_command_windows/device_notifications",
          &flutter::StandardMethodCodec::GetInstance());

  registrar->AddPlugin(std::move(plugin));
}

FlutterMidiCommandWindowsPlugin::FlutterMidiCommandWindowsPlugin(
    flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar) {
  window_proc_id_ = registrar_->RegisterTopLevelWindowProcDelegate(
      [this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
        return HandleWindowProc(hwnd, message, wparam, lparam);
      });
}

FlutterMidiCommandWindowsPlugin::~FlutterMidiCommandWindowsPlugin() {
  registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_id_);
}

std::optional<LRESULT> FlutterMidiCommandWindowsPlugin::HandleWindowProc(
    HWND hwnd,
    UINT message,
    WPARAM wparam,
    LPARAM lparam) {
  (void)lparam;
  (void)hwnd;

  switch (message) {
    case WM_DEVICECHANGE:
      if (wparam == kDbtDeviceArrival || wparam == kDbtDevNodesChanged) {
        channel_->InvokeMethod("deviceAdded", nullptr);
      } else if (wparam == kDbtDeviceRemoveComplete) {
        channel_->InvokeMethod("deviceRemoved", nullptr);
      }
      break;
  }

  return std::nullopt;
}

}  // namespace

void FlutterMidiCommandWindowsPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  FlutterMidiCommandWindowsPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
