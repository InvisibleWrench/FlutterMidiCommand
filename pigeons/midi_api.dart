import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut:
        'packages/flutter_midi_command_platform_interface/lib/src/pigeon/midi_api.g.dart',
    dartOptions: DartOptions(),
    kotlinOut:
        'packages/flutter_midi_command_android/android/src/main/kotlin/com/invisiblewrench/fluttermidicommand/pigeon/MidiApi.g.kt',
    kotlinOptions: KotlinOptions(
      package: 'com.invisiblewrench.fluttermidicommand.pigeon',
    ),
    swiftOut:
        'packages/flutter_midi_command_darwin/darwin/flutter_midi_command_darwin/Sources/flutter_midi_command_darwin/pigeon/MidiApi.g.swift',
    swiftOptions: SwiftOptions(),
  ),
)
class MidiHostDevice {
  String? id;
  String? name;
  MidiDeviceType? type;
  bool? connected;
  List<MidiPort?>? inputs;
  List<MidiPort?>? outputs;
}

enum MidiDeviceType { serial, ble, virtualDevice, ownVirtual, network, unknown }

enum MidiSetupChange {
  deviceAppeared,
  deviceDisappeared,
  deviceStateChanged,
  deviceConnected,
  deviceDisconnected,
}

class MidiPort {
  int? id;
  bool? connected;
  bool? isInput;
}

class MidiPacket {
  MidiHostDevice? device;
  Uint8List? data;
  int? timestamp;
}

@HostApi()
abstract class MidiHostApi {
  List<MidiHostDevice> listDevices();
  void connect(MidiHostDevice device, List<MidiPort>? ports);
  void disconnect(String deviceId);
  void teardown();
  void sendData(MidiPacket packet);
  void addVirtualDevice(String? name);
  void removeVirtualDevice(String? name);
  bool? isNetworkSessionEnabled();
  void setNetworkSessionEnabled(bool enabled);
}

@FlutterApi()
abstract class MidiFlutterApi {
  void onSetupChanged(MidiSetupChange setupChange);
  void onDataReceived(MidiPacket packet);
  void onDeviceConnectionStateChanged(String deviceId, bool connected);
}
