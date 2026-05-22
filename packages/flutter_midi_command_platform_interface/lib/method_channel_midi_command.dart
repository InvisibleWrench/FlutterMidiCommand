import 'dart:async';
import 'dart:typed_data';
import 'flutter_midi_command_platform_interface.dart';
import 'src/pigeon/midi_api.g.dart' as pigeon;

typedef MidiFlutterApiSetUp = void Function(pigeon.MidiFlutterApi? api);

/// Thrown when [MethodChannelMidiCommand] is initialized off the root isolate.
class MidiCommandRootIsolateRequiredError extends UnsupportedError {
  MidiCommandRootIsolateRequiredError()
    : super(
        'MidiCommand must be initialized on the root isolate. '
        'Background isolates cannot register platform callbacks via '
        'setMessageHandler(). Initialize MidiCommand on the root isolate and '
        'forward MIDI events/commands to worker isolates via SendPort.',
      );
}

/// A [MidiCommandPlatform] implementation backed by generated Pigeon APIs.
class MethodChannelMidiCommand extends MidiCommandPlatform
    implements pigeon.MidiFlutterApi {
  MethodChannelMidiCommand({
    pigeon.MidiHostApi? hostApi,
    MidiFlutterApiSetUp? flutterApiSetUp,
  }) : _hostApi = hostApi ?? pigeon.MidiHostApi(),
       _flutterApiSetUp = flutterApiSetUp ?? pigeon.MidiFlutterApi.setUp {
    _registerFlutterApi();
  }

  final pigeon.MidiHostApi _hostApi;
  final MidiFlutterApiSetUp _flutterApiSetUp;
  final StreamController<MidiPacket> _rxStreamController =
      StreamController<MidiPacket>.broadcast();
  final StreamController<MidiSetupChange> _setupStreamController =
      StreamController<MidiSetupChange>.broadcast();
  final Map<String, MidiDevice> _deviceCache = <String, MidiDevice>{};

  void _registerFlutterApi() {
    try {
      _flutterApiSetUp(this);
    } on UnsupportedError catch (error, stackTrace) {
      if (_isBackgroundIsolateMessageHandlerError(error)) {
        Error.throwWithStackTrace(
          MidiCommandRootIsolateRequiredError(),
          stackTrace,
        );
      }
      rethrow;
    }
  }

  bool _isBackgroundIsolateMessageHandlerError(UnsupportedError error) {
    final message = error.message ?? '';
    return message.contains(
          'Background isolates do not support setMessageHandler()',
        ) ||
        message.contains('setMessageHandler');
  }

  /// Returns a list of found MIDI devices.
  @override
  Future<List<MidiDevice>?> get devices async {
    final hostDevices = await _hostApi.listDevices();
    _pruneDeviceCache(
      hostDevices.map((device) => device.id).whereType<String>().toSet(),
    );
    return hostDevices.map(_fromHostDevice).toList(growable: false);
  }

  void _pruneDeviceCache(Set<String> liveIds) {
    final staleIds =
        _deviceCache.keys.where((id) => !liveIds.contains(id)).toList();
    for (final id in staleIds) {
      final staleDevice = _deviceCache.remove(id);
      staleDevice?.setConnectionState(MidiConnectionState.disconnected);
      staleDevice?.dispose();
    }
  }

  List<MidiPort> _fromHostPorts(
    List<pigeon.MidiPort?>? portList,
    MidiPortType fallbackType,
  ) {
    if (portList == null) {
      return <MidiPort>[];
    }
    return portList
        .whereType<pigeon.MidiPort>()
        .map((port) {
          final type =
              (port.isInput ?? (fallbackType == MidiPortType.IN))
                  ? MidiPortType.IN
                  : MidiPortType.OUT;
          final mappedPort = MidiPort((port.id ?? 0).toInt(), type);
          mappedPort.connected = port.connected ?? false;
          return mappedPort;
        })
        .toList(growable: false);
  }

  MidiDevice _fromHostDevice(pigeon.MidiHostDevice hostDevice) {
    final id = hostDevice.id ?? '';
    final cached = id.isEmpty ? null : _deviceCache[id];
    final device =
        cached ??
        MidiDevice(
          id,
          hostDevice.name ?? '-',
          _fromHostDeviceType(hostDevice.type),
          hostDevice.connected ?? false,
        );
    device.name = hostDevice.name ?? '-';
    device.type = _fromHostDeviceType(hostDevice.type);
    device.connected = hostDevice.connected ?? false;
    device.inputPorts = _fromHostPorts(hostDevice.inputs, MidiPortType.IN);
    device.outputPorts = _fromHostPorts(hostDevice.outputs, MidiPortType.OUT);
    if (id.isNotEmpty) {
      _deviceCache[id] = device;
    }
    return device;
  }

  pigeon.MidiPort _toHostPort(MidiPort port, {bool? isInput}) {
    return pigeon.MidiPort(
      id: port.id,
      connected: port.connected,
      isInput: isInput ?? port.type == MidiPortType.IN,
    );
  }

  pigeon.MidiHostDevice _toHostDevice(MidiDevice device) {
    return pigeon.MidiHostDevice(
      id: device.id,
      name: device.name,
      type: _toHostDeviceType(device.type),
      connected: device.connected,
      inputs: device.inputPorts
          .map((port) => _toHostPort(port, isInput: true))
          .toList(growable: false),
      outputs: device.outputPorts
          .map((port) => _toHostPort(port, isInput: false))
          .toList(growable: false),
    );
  }

  MidiDeviceType _fromHostDeviceType(pigeon.MidiDeviceType? type) {
    switch (type) {
      case pigeon.MidiDeviceType.serial:
        return MidiDeviceType.serial;
      case pigeon.MidiDeviceType.ble:
        return MidiDeviceType.ble;
      case pigeon.MidiDeviceType.virtualDevice:
        return MidiDeviceType.virtual;
      case pigeon.MidiDeviceType.ownVirtual:
        return MidiDeviceType.ownVirtual;
      case pigeon.MidiDeviceType.network:
        return MidiDeviceType.network;
      case pigeon.MidiDeviceType.unknown:
      case null:
        return MidiDeviceType.unknown;
    }
  }

  pigeon.MidiDeviceType _toHostDeviceType(MidiDeviceType type) {
    switch (type) {
      case MidiDeviceType.serial:
        return pigeon.MidiDeviceType.serial;
      case MidiDeviceType.ble:
        return pigeon.MidiDeviceType.ble;
      case MidiDeviceType.virtual:
        return pigeon.MidiDeviceType.virtualDevice;
      case MidiDeviceType.ownVirtual:
        return pigeon.MidiDeviceType.ownVirtual;
      case MidiDeviceType.network:
        return pigeon.MidiDeviceType.network;
      case MidiDeviceType.unknown:
        return pigeon.MidiDeviceType.unknown;
    }
  }

  /// Connects to the device.
  @override
  Future<void> connectToDevice(
    MidiDevice device, {
    List<MidiPort>? ports,
  }) async {
    if (device.id.isNotEmpty) {
      _deviceCache[device.id] = device;
    }
    device.setConnectionState(MidiConnectionState.connecting);
    final hostPorts = ports
        ?.map((port) => _toHostPort(port))
        .toList(growable: false);
    await _hostApi.connect(_toHostDevice(device), hostPorts);
  }

  /// Disconnects from the device.
  @override
  void disconnectDevice(MidiDevice device) {
    device.setConnectionState(MidiConnectionState.disconnecting);
    unawaited(
      _hostApi.disconnect(device.id).then((_) {
        if (device.connectionState == MidiConnectionState.disconnecting) {
          device.setConnectionState(MidiConnectionState.disconnected);
        }
        _deviceCache.remove(device.id);
      }),
    );
  }

  /// Disconnects from all devices.
  @override
  void teardown() {
    for (final device in _deviceCache.values) {
      device.setConnectionState(MidiConnectionState.disconnected);
      device.dispose();
    }
    _deviceCache.clear();
    unawaited(_hostApi.teardown());
  }

  /// Sends data to the currently connected device.
  ///
  /// Data is an UInt8List of individual MIDI command bytes.
  @override
  void sendData(Uint8List data, {int? timestamp, String? deviceId}) {
    unawaited(
      _hostApi.sendData(
        pigeon.MidiPacket(
          device:
              deviceId == null
                  ? null
                  : pigeon.MidiHostDevice(
                    id: deviceId,
                    type: pigeon.MidiDeviceType.unknown,
                  ),
          data: data,
          timestamp: timestamp,
        ),
      ),
    );
  }

  /// Stream firing events whenever a midi package is received.
  ///
  /// The event contains the raw bytes contained in the MIDI package.
  @override
  Stream<MidiPacket>? get onMidiDataReceived => _rxStreamController.stream;

  /// Stream firing events whenever a change in the MIDI setup occurs.
  ///
  /// Emits [MidiSetupChange] values for device topology and connection changes.
  @override
  Stream<MidiSetupChange>? get onMidiSetupChanged =>
      _setupStreamController.stream;

  @override
  void onSetupChanged(pigeon.MidiSetupChange setupChange) {
    _setupStreamController.add(_fromPigeonSetupChange(setupChange));
  }

  @override
  void onDataReceived(pigeon.MidiPacket packet) {
    final sourceDevice = packet.device ?? pigeon.MidiHostDevice();
    final midiDevice = _fromHostDevice(sourceDevice);
    _rxStreamController.add(
      MidiPacket(
        packet.data ?? Uint8List(0),
        packet.timestamp ?? 0,
        midiDevice,
      ),
    );
  }

  @override
  void onDeviceConnectionStateChanged(String deviceId, bool connected) {
    if (!connected) {
      final cached = _deviceCache[deviceId];
      cached?.connected = false;
      _deviceCache.remove(deviceId);
      _setupStreamController.add(MidiSetupChange.deviceDisconnected);
      return;
    }

    final cached =
        _deviceCache[deviceId] ??
        MidiDevice(deviceId, deviceId, MidiDeviceType.unknown, true);
    cached.connected = true;
    _deviceCache[deviceId] = cached;
    _setupStreamController.add(MidiSetupChange.deviceConnected);
  }

  /// Creates a virtual MIDI source
  ///
  /// The virtual MIDI source appears as a virtual port in other apps.
  /// Currently only supported on iOS.
  @override
  void addVirtualDevice({String? name}) {
    unawaited(_hostApi.addVirtualDevice(name));
  }

  /// Removes a previously addd virtual MIDI source.
  @override
  void removeVirtualDevice({String? name}) {
    unawaited(_hostApi.removeVirtualDevice(name));
  }

  /// Returns the current state of the network session
  ///
  /// This is functional on iOS only, will return null on other platforms
  @override
  Future<bool?> get isNetworkSessionEnabled {
    return _hostApi.isNetworkSessionEnabled();
  }

  /// Sets the enabled state of the network session
  ///
  /// This is functional on iOS only
  @override
  void setNetworkSessionEnabled(bool enabled) {
    unawaited(_hostApi.setNetworkSessionEnabled(enabled));
  }
}

MidiSetupChange _fromPigeonSetupChange(pigeon.MidiSetupChange setupChange) {
  switch (setupChange) {
    case pigeon.MidiSetupChange.deviceAppeared:
      return MidiSetupChange.deviceAppeared;
    case pigeon.MidiSetupChange.deviceDisappeared:
      return MidiSetupChange.deviceDisappeared;
    case pigeon.MidiSetupChange.deviceStateChanged:
      return MidiSetupChange.deviceStateChanged;
    case pigeon.MidiSetupChange.deviceConnected:
      return MidiSetupChange.deviceConnected;
    case pigeon.MidiSetupChange.deviceDisconnected:
      return MidiSetupChange.deviceDisconnected;
  }
}
