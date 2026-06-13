import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';
import 'package:flutter_midi_command_windows/src/windows_device_discovery.dart';
import 'package:flutter_midi_command_windows/windows_midi_device.dart';
import 'package:win32/win32.dart';

typedef WindowsMidiDeviceDiscovery = List<MidiDevice> Function();
typedef WindowsMidiDeviceMonitor = Stream<void> Function();

class FlutterMidiCommandWindows extends MidiCommandPlatform {
  factory FlutterMidiCommandWindows({
    WindowsMidiDeviceDiscovery? deviceDiscovery,
    WindowsMidiDeviceMonitor? deviceMonitor,
    Duration deviceMonitorDebounce = const Duration(milliseconds: 250),
  }) {
    if (deviceDiscovery != null ||
        deviceMonitor != null ||
        deviceMonitorDebounce != const Duration(milliseconds: 250)) {
      return FlutterMidiCommandWindows._(
        deviceDiscovery: deviceDiscovery,
        deviceMonitor: deviceMonitor,
        deviceMonitorDebounce: deviceMonitorDebounce,
      );
    }

    _instance ??= FlutterMidiCommandWindows._();
    return _instance!;
  }

  FlutterMidiCommandWindows._({
    WindowsMidiDeviceDiscovery? deviceDiscovery,
    WindowsMidiDeviceMonitor? deviceMonitor,
    Duration deviceMonitorDebounce = const Duration(milliseconds: 250),
  }) : _deviceDiscovery = deviceDiscovery,
       _deviceMonitor = deviceMonitor,
       _deviceMonitorDebounce = deviceMonitorDebounce {
    _setupStreamController = StreamController<MidiSetupChange>.broadcast(
      onListen: _startDeviceMonitor,
      onCancel: _stopDeviceMonitorIfIdle,
    );
    _setupStream = _setupStreamController.stream;
    _rxStream = _rxStreamController.stream;
  }

  final StreamController<MidiPacket> _rxStreamController =
      StreamController<MidiPacket>.broadcast();
  late final Stream<MidiPacket> _rxStream;

  late final StreamController<MidiSetupChange> _setupStreamController;
  late final Stream<MidiSetupChange> _setupStream;

  final Map<String, WindowsMidiDevice> _connectedDevices =
      <String, WindowsMidiDevice>{};

  static FlutterMidiCommandWindows? _instance;
  final WindowsMidiDeviceDiscovery? _deviceDiscovery;
  final WindowsMidiDeviceMonitor? _deviceMonitor;
  final Duration _deviceMonitorDebounce;
  final Map<String, _WindowsMidiDeviceSnapshot> _knownDeviceSnapshots =
      <String, _WindowsMidiDeviceSnapshot>{};
  StreamSubscription<void>? _deviceMonitorSubscription;
  Timer? _deviceMonitorTimer;
  bool _hasKnownDeviceSnapshot = false;
  bool _tearingDown = false;

  Stream<void> _defaultDeviceMonitor() {
    return _WindowsDeviceNotificationMonitor.instance.stream;
  }

  static void registerWith() {
    MidiCommandPlatform.instance = FlutterMidiCommandWindows();
  }

  @override
  Future<List<MidiDevice>> get devices async {
    final discoveredDevices =
        _deviceDiscovery?.call() ?? _discoverWindowsMidiDevices();
    _rememberDevices(discoveredDevices);
    return discoveredDevices;
  }

  List<MidiDevice> _discoverWindowsMidiDevices() {
    final inputs = <WindowsMidiEndpointDescriptor>[];

    final inCaps = malloc<MIDIINCAPS>();
    var nMidiDeviceNum = midiInGetNumDevs();

    for (var i = 0; i < nMidiDeviceNum; ++i) {
      final result = midiInGetDevCaps(i, inCaps, sizeOf<MIDIINCAPS>());
      if (result != MMSYSERR_NOERROR) {
        continue;
      }
      inputs.add(
        WindowsMidiEndpointDescriptor(id: i, name: inCaps.ref.szPname),
      );
    }

    free(inCaps);

    final outputs = <WindowsMidiEndpointDescriptor>[];
    final outCaps = malloc<MIDIOUTCAPS>();
    nMidiDeviceNum = midiOutGetNumDevs();

    for (var i = 0; i < nMidiDeviceNum; ++i) {
      final result = midiOutGetDevCaps(i, outCaps, sizeOf<MIDIOUTCAPS>());
      if (result != MMSYSERR_NOERROR) {
        continue;
      }
      outputs.add(
        WindowsMidiEndpointDescriptor(id: i, name: outCaps.ref.szPname),
      );
    }

    free(outCaps);

    return buildWindowsMidiDevices(
      inputs: inputs,
      outputs: outputs,
      rxStreamController: _rxStreamController,
      setupStreamController: _setupStreamController,
      callbackAddress: _midiCB.nativeFunction.address,
      connectedDeviceIds: _connectedDevices.keys.toSet(),
    );
  }

  @override
  Future<void> connectToDevice(
    MidiDevice device, {
    List<MidiPort>? ports,
  }) async {
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
      if (remove) {
        _connectedDevices.remove(device.id);
        _setupStreamController.add(MidiSetupChange.deviceDisconnected);
      }
    }
  }

  @override
  void teardown() {
    _tearingDown = true;
    _deviceMonitorTimer?.cancel();
    _deviceMonitorTimer = null;
    unawaited(_deviceMonitorSubscription?.cancel());
    _deviceMonitorSubscription = null;
    _midiCB.close();

    for (final device in _connectedDevices.values.toList(growable: false)) {
      disconnectDevice(device, remove: false);
    }
    _connectedDevices.clear();
    _setupStreamController.add(MidiSetupChange.deviceDisconnected);
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
  Stream<MidiSetupChange>? get onMidiSetupChanged => _setupStream;

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

  void _startDeviceMonitor() {
    if (_tearingDown || _deviceMonitorSubscription != null) {
      return;
    }
    final discoveredDevices =
        _deviceDiscovery?.call() ?? _discoverWindowsMidiDevices();
    _rememberDevices(discoveredDevices);
    _deviceMonitorSubscription =
        (_deviceMonitor?.call() ?? _defaultDeviceMonitor()).listen((_) {
          _scheduleDeviceRefresh();
        });
  }

  void _stopDeviceMonitorIfIdle() {
    if (_setupStreamController.hasListener) {
      return;
    }
    _deviceMonitorTimer?.cancel();
    _deviceMonitorTimer = null;
    unawaited(_deviceMonitorSubscription?.cancel());
    _deviceMonitorSubscription = null;
  }

  void _scheduleDeviceRefresh() {
    if (_tearingDown) {
      return;
    }
    _deviceMonitorTimer?.cancel();
    _deviceMonitorTimer = Timer(_deviceMonitorDebounce, () {
      _deviceMonitorTimer = null;
      final discoveredDevices =
          _deviceDiscovery?.call() ?? _discoverWindowsMidiDevices();
      _applyDeviceSnapshot(discoveredDevices);
    });
  }

  void _rememberDevices(List<MidiDevice> devices) {
    _knownDeviceSnapshots
      ..clear()
      ..addEntries(
        devices.map(
          (device) => MapEntry(device.id, _WindowsMidiDeviceSnapshot(device)),
        ),
      );
    _hasKnownDeviceSnapshot = true;
  }

  void _applyDeviceSnapshot(List<MidiDevice> devices) {
    final nextSnapshots = <String, _WindowsMidiDeviceSnapshot>{
      for (final device in devices)
        device.id: _WindowsMidiDeviceSnapshot(device),
    };
    if (!_hasKnownDeviceSnapshot) {
      _knownDeviceSnapshots
        ..clear()
        ..addAll(nextSnapshots);
      _hasKnownDeviceSnapshot = true;
      return;
    }

    final previousSnapshots = Map<String, _WindowsMidiDeviceSnapshot>.of(
      _knownDeviceSnapshots,
    );
    final previousIds = previousSnapshots.keys.toSet();
    final nextIds = nextSnapshots.keys.toSet();
    final disappearedIds = previousIds.difference(nextIds);
    final appearedIds = nextIds.difference(previousIds);
    final retainedIds = previousIds.intersection(nextIds);
    var stateChanged = false;

    _knownDeviceSnapshots
      ..clear()
      ..addAll(nextSnapshots);

    for (final id in disappearedIds) {
      final connectedDevice = _connectedDevices.remove(id);
      if (connectedDevice != null) {
        connectedDevice.disconnect();
      }
      _setupStreamController.add(MidiSetupChange.deviceDisappeared);
    }

    for (final _ in appearedIds) {
      _setupStreamController.add(MidiSetupChange.deviceAppeared);
    }

    for (final id in retainedIds) {
      if (previousSnapshots[id] != nextSnapshots[id]) {
        stateChanged = true;
        break;
      }
    }
    if (stateChanged && appearedIds.isEmpty && disappearedIds.isEmpty) {
      _setupStreamController.add(MidiSetupChange.deviceStateChanged);
    }
  }
}

class _WindowsDeviceNotificationMonitor {
  _WindowsDeviceNotificationMonitor._() {
    _streamController = StreamController<void>.broadcast(
      onListen: _ensureInitialized,
    );
  }

  static final _WindowsDeviceNotificationMonitor instance =
      _WindowsDeviceNotificationMonitor._();
  static const MethodChannel _channel = MethodChannel(
    'flutter_midi_command_windows/device_notifications',
  );

  late final StreamController<void> _streamController;
  bool _initialized = false;

  Stream<void> get stream => _streamController.stream;

  void _ensureInitialized() {
    if (_initialized) {
      return;
    }
    _initialized = true;
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  Future<Object?> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'deviceAdded':
      case 'deviceRemoved':
        if (!_streamController.isClosed) {
          _streamController.add(null);
        }
        break;
    }
    return null;
  }
}

class _WindowsMidiDeviceSnapshot {
  _WindowsMidiDeviceSnapshot(MidiDevice device)
    : id = device.id,
      name = device.name,
      type = device.type,
      inputs = device.inputPorts.map((port) => port.id).toList(growable: false),
      outputs = device.outputPorts
          .map((port) => port.id)
          .toList(growable: false);

  final String id;
  final String name;
  final MidiDeviceType type;
  final List<int> inputs;
  final List<int> outputs;

  @override
  bool operator ==(Object other) {
    return other is _WindowsMidiDeviceSnapshot &&
        other.id == id &&
        other.name == name &&
        other.type == type &&
        _intListsEqual(other.inputs, inputs) &&
        _intListsEqual(other.outputs, outputs);
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    type,
    Object.hashAll(inputs),
    Object.hashAll(outputs),
  );
}

bool _intListsEqual(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
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
  int hMidiIn,
  int wMsg,
  int dwInstance,
  int dwParam1,
  int dwParam2,
) {
  final dev = FlutterMidiCommandWindows().findMidiDeviceForSource(hMidiIn);

  switch (wMsg) {
    case MM_MIM_OPEN:
      dev?.connected = true;
      break;
    case MM_MIM_CLOSE:
      dev?.connected = false;
      break;
    case MM_MIM_DATA:
      final data = _shortMidiMessageBytes(dwParam1);
      dev?.handleData(data, dwParam2);
      break;
    case MM_MIM_LONGDATA:
      final midiHdrPointer = Pointer<MIDIHDR>.fromAddress(dwParam1);
      final midiHdr = midiHdrPointer.ref;
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

Uint8List _shortMidiMessageBytes(int packedMessage) {
  final status = packedMessage & 0xFF;
  final data1 = (packedMessage >> 8) & 0xFF;
  final data2 = (packedMessage >> 16) & 0xFF;
  final length = _shortMidiMessageLength(status);

  switch (length) {
    case 1:
      return Uint8List.fromList([status]);
    case 2:
      return Uint8List.fromList([status, data1]);
    case 3:
      return Uint8List.fromList([status, data1, data2]);
    default:
      return Uint8List(0);
  }
}

int _shortMidiMessageLength(int status) {
  if (status >= 0xF8) {
    return 1;
  }

  switch (status & 0xF0) {
    case 0x80:
    case 0x90:
    case 0xA0:
    case 0xB0:
    case 0xE0:
      return 3;
    case 0xC0:
    case 0xD0:
      return 2;
  }

  switch (status) {
    case 0xF1:
    case 0xF3:
      return 2;
    case 0xF2:
      return 3;
    case 0xF6:
      return 1;
    default:
      return 1;
  }
}
