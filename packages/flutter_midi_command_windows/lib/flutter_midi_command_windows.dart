import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:device_manager/device_event.dart';
import 'package:device_manager/device_manager.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';
import 'package:flutter_midi_command_windows/windows_midi_device.dart';
import 'package:win32/win32.dart';

class FlutterMidiCommandWindows extends MidiCommandPlatform {
  final StreamController<MidiPacket> _rxStreamController =
      StreamController<MidiPacket>.broadcast();
  late final Stream<MidiPacket> _rxStream;

  final StreamController<String> _setupStreamController =
      StreamController<String>.broadcast();
  late final Stream<String> _setupStream;

  final Map<String, WindowsMidiDevice> _connectedDevices =
      <String, WindowsMidiDevice>{};

  factory FlutterMidiCommandWindows() {
    _instance ??= FlutterMidiCommandWindows._();
    return _instance!;
  }

  static FlutterMidiCommandWindows? _instance;

  FlutterMidiCommandWindows._() {
    _setupStream = _setupStreamController.stream;
    _rxStream = _rxStreamController.stream;
    _setupDeviceManager();
  }

  Future<void> _setupDeviceManager() async {
    await Future.delayed(const Duration(seconds: 3));
    DeviceManager().addListener(() {
      final event = DeviceManager().lastEvent;
      if (event == null) {
        return;
      }
      if (event.eventType == EventType.add) {
        _setupStreamController.add("deviceAppeared");
      } else if (event.eventType == EventType.remove) {
        _setupStreamController.add("deviceDisappeared");
      }
    });
  }

  static void registerWith() {
    MidiCommandPlatform.instance = FlutterMidiCommandWindows();
  }

  @override
  Future<List<MidiDevice>> get devices async {
    final devices = <String, MidiDevice>{};

    final inCaps = malloc<MIDIINCAPS>();
    var nMidiDeviceNum = midiInGetNumDevs();
    final deviceInputs = <String, int>{};

    for (var i = 0; i < nMidiDeviceNum; ++i) {
      midiInGetDevCaps(i, inCaps, sizeOf<MIDIINCAPS>());
      final name = inCaps.ref.szPname;
      var id = name;

      if (!deviceInputs.containsKey(name)) {
        deviceInputs[name] = 0;
      } else {
        deviceInputs[name] = deviceInputs[name]! + 1;
      }

      if (deviceInputs[name]! > 0) {
        id = "$id (${deviceInputs[name]})";
      }

      final isConnected = _connectedDevices.containsKey(id);
      devices[id] = WindowsMidiDevice(
        id,
        name,
        _rxStreamController,
        _setupStreamController,
        _midiCB.nativeFunction.address,
      )
        ..addInput(i, inCaps.ref)
        ..connected = isConnected;
    }

    free(inCaps);

    final outCaps = malloc<MIDIOUTCAPS>();
    nMidiDeviceNum = midiOutGetNumDevs();
    final deviceOutputs = <String, int>{};

    for (var i = 0; i < nMidiDeviceNum; ++i) {
      midiOutGetDevCaps(i, outCaps, sizeOf<MIDIOUTCAPS>());
      final name = outCaps.ref.szPname;
      var id = name;

      if (!deviceOutputs.containsKey(name)) {
        deviceOutputs[name] = 0;
      } else {
        deviceOutputs[name] = deviceOutputs[name]! + 1;
      }

      if (deviceOutputs[name]! > 0) {
        id = "$id (${deviceOutputs[name]})";
      }

      if (devices.containsKey(id)) {
        devices[id]! as WindowsMidiDevice..addOutput(i, outCaps.ref);
      } else {
        final isConnected = _connectedDevices.containsKey(id);
        devices[id] = WindowsMidiDevice(
          id,
          name,
          _rxStreamController,
          _setupStreamController,
          _midiCB.nativeFunction.address,
        )
          ..addOutput(i, outCaps.ref)
          ..connected = isConnected;
      }
    }

    free(outCaps);

    return devices.values.toList();
  }

  @override
  Future<void> connectToDevice(MidiDevice device,
      {List<MidiPort>? ports}) async {
    if (device is! WindowsMidiDevice) {
      return;
    }

    final success = device.connect();
    if (success) {
      _connectedDevices[device.id] = device;
    }
  }

  @override
  void disconnectDevice(MidiDevice device, {bool remove = true}) {
    if (device is! WindowsMidiDevice) {
      return;
    }

    final windowsDevice = _connectedDevices[device.id];
    if (windowsDevice == null) {
      return;
    }

    final result = windowsDevice.disconnect();
    if (result) {
      _connectedDevices.remove(device.id);
      _setupStreamController.add("deviceDisconnected");
    }
  }

  @override
  void teardown() {
    _midiCB.close();

    for (final device in _connectedDevices.values) {
      disconnectDevice(device, remove: false);
    }
    _connectedDevices.clear();
    _setupStreamController.add("deviceDisconnected");
    _rxStreamController.close();
  }

  @override
  void sendData(Uint8List data, {int? timestamp, String? deviceId}) {
    if (deviceId != null) {
      _connectedDevices[deviceId]?.send(data);
      return;
    }

    for (final device in _connectedDevices.values) {
      device.send(data);
    }
  }

  @override
  Stream<MidiPacket>? get onMidiDataReceived => _rxStream;

  @override
  Stream<String>? get onMidiSetupChanged => _setupStream;

  @override
  void addVirtualDevice({String? name}) {}

  @override
  void removeVirtualDevice({String? name}) {}

  @override
  Future<bool?> get isNetworkSessionEnabled async => false;

  @override
  void setNetworkSessionEnabled(bool enabled) {}

  WindowsMidiDevice? findMidiDeviceForSource(int src) {
    for (final wmd in _connectedDevices.values) {
      if (wmd.containsMidiIn(src)) {
        return wmd;
      }
    }
    return null;
  }
}

String midiErrorMessage(int status) {
  switch (status) {
    case MMSYSERR_ALLOCATED:
      return "Resource already allocated";
    case MMSYSERR_BADDEVICEID:
      return "Device ID out of range";
    case MMSYSERR_INVALFLAG:
      return "Invalid dwFlags";
    case MMSYSERR_INVALPARAM:
      return 'Invalid pointer or structure';
    case MMSYSERR_NOMEM:
      return "Unable to allocate memory";
    case MMSYSERR_INVALHANDLE:
      return "Invalid handle";
    default:
      return "Status $status";
  }
}

final NativeCallable<Void Function(IntPtr, Uint32, IntPtr, IntPtr, IntPtr)>
    _midiCB = NativeCallable<MIDIINPROC>.listener(_onMidiData);

const int mHdrDone = 0x00000001;
const int mHdrPrepared = 0x00000002;
const int mHdrInQueue = 0x00000004;

final List<int> partialSysExBuffer = [];

void _onMidiData(
    int hMidiIn, int wMsg, int dwInstance, int dwParam1, int dwParam2) {
  final dev = FlutterMidiCommandWindows().findMidiDeviceForSource(hMidiIn);
  final midiHdrPointer = Pointer<MIDIHDR>.fromAddress(dwParam1);
  final midiHdr = midiHdrPointer.ref;

  switch (wMsg) {
    case MM_MIM_OPEN:
      dev?.connected = true;
      break;
    case MM_MIM_CLOSE:
      dev?.connected = false;
      break;
    case MM_MIM_DATA:
      final data = Uint32List.fromList([dwParam1]).buffer.asUint8List();
      dev?.handleData(data, dwParam2);
      break;
    case MM_MIM_LONGDATA:
      if ((midiHdr.dwFlags & mHdrDone) != 0) {
        final dataPointer = midiHdr.lpData.cast<Uint8>();
        final messageData = dataPointer.asTypedList(midiHdr.dwBytesRecorded);

        if (messageData.isNotEmpty && messageData.first == 0xF0) {
          partialSysExBuffer.clear();
        }

        partialSysExBuffer.addAll(messageData);

        if (partialSysExBuffer.isNotEmpty && partialSysExBuffer.last == 0xF7) {
          dev?.handleSysexData(messageData, midiHdrPointer);
          partialSysExBuffer.clear();
        }
      } else {
        if ((midiHdr.dwFlags & mHdrPrepared) != 0) {
          print('MHDR_PREPARED is set');
        }
        if ((midiHdr.dwFlags & mHdrInQueue) != 0) {
          print('MHDR_INQUEUE is set');
        }
      }
      break;
    case MM_MIM_MOREDATA:
      print("More data - unhandled!");
      break;
    case MM_MIM_ERROR:
      print("Error");
      break;
    case MM_MIM_LONGERROR:
      print("Long error");
      break;
  }
}
