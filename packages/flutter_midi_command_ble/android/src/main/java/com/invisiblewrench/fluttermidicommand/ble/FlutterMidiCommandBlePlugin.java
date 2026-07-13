package com.invisiblewrench.fluttermidicommand.ble;

import androidx.annotation.NonNull;
import io.flutter.embedding.engine.plugins.FlutterPlugin;

/**
 * Registers the Android library so its BLE permissions are merged into the
 * host application. BLE MIDI behavior remains implemented in shared Dart.
 */
public final class FlutterMidiCommandBlePlugin implements FlutterPlugin {
  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {}

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {}
}
