library;

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';
import 'package:universal_ble/universal_ble.dart';

const midiServiceId = "03B80E5A-EDE8-4B33-A751-6CE34EC4C700";
const midiCharacteristicId = "7772E5DB-3868-4112-A1A9-F2669D106BF3";

enum _DeviceState { none, interrogating, available, irrelevant }

enum _BleHandlerState {
  header,
  timestamp,
  status,
  statusRunning,
  params,
  systemRt,
  sysex,
  sysexEnd,
  sysexInt,
}

class UniversalBleMidiTransport implements MidiBleTransport {
  UniversalBleMidiTransport() {
    UniversalBle.timeout = const Duration(seconds: 10);
    _registerCallbacks();
  }

  final _rxStreamController = StreamController<MidiPacket>.broadcast();
  final _setupStreamController = StreamController<MidiSetupChange>.broadcast();
  final _bluetoothStateStreamController = StreamController<String>.broadcast();
  final Map<String, _BleMidiDevice> _devices = {};
  String _bleState = "unknown";
  bool _callbacksRegistered = false;
  bool _isTornDown = false;

  void _registerCallbacks() {
    if (_callbacksRegistered) {
      return;
    }
    _callbacksRegistered = true;

    UniversalBle.onAvailabilityChange = (state) {
      _bleState = state.name;
      _bluetoothStateStreamController.add(state.name);
    };

    UniversalBle.onScanResult = (result) {
      if (_devices.containsKey(result.deviceId) || result.name == null) {
        return;
      }
      _devices[result.deviceId] = _BleMidiDevice(
        deviceId: result.deviceId,
        name: result.name!,
        rxStream: _rxStreamController,
      );
      _setupStreamController.add(MidiSetupChange.deviceAppeared);
    };

    UniversalBle.onConnectionChange = (deviceId, isConnected, error) {
      final device = _devices[deviceId];
      if (device == null) {
        return;
      }
      if (isConnected) {
        device.updateConnectionState(BleConnectionState.connected);
      } else {
        device.updateConnectionState(BleConnectionState.disconnected);
        _removeDisconnectedDevice(deviceId);
      }
    };

    UniversalBle.onValueChange = (deviceId, characteristicId, data, _) {
      _devices[deviceId]?.handleData(data);
    };

    UniversalBle.onPairingStateChange = (deviceId, isPaired) {
      _devices[deviceId]?.updatePairingState(isPaired);
    };
  }

  void _unregisterCallbacks() {
    if (!_callbacksRegistered) {
      return;
    }
    UniversalBle.onAvailabilityChange = null;
    UniversalBle.onScanResult = null;
    UniversalBle.onConnectionChange = null;
    UniversalBle.onValueChange = null;
    UniversalBle.onPairingStateChange = (_, __) {};
    _callbacksRegistered = false;
  }

  void _activateIfNeeded() {
    if (!_isTornDown) {
      return;
    }
    _isTornDown = false;
    _registerCallbacks();
  }

  void _removeDisconnectedDevice(String deviceId) {
    final removed = _devices.remove(deviceId);
    if (removed != null) {
      _setupStreamController.add(MidiSetupChange.deviceDisconnected);
    }
  }

  @override
  Future<void> startBluetooth() async {
    _activateIfNeeded();
    // On Apple, when the host app declares the `bluetooth-central` background
    // mode, universal_ble intentionally defers creating the CBCentralManager
    // (and the permission prompt) until a central operation runs. Until then
    // `getBluetoothAvailabilityState()` reports "unknown" without ever
    // initialising CoreBluetooth, so `onAvailabilityChange` never fires and
    // callers waiting for a resolved state deadlock. Requesting permission
    // forces the manager to be created, which makes CoreBluetooth report its
    // real state (and surfaces the OS prompt on first launch).
    try {
      await UniversalBle.requestPermissions();
    } catch (_) {
      // A denial/unsupported result is reflected in the availability state
      // read below; nothing else to do here.
    }
    final state = await UniversalBle.getBluetoothAvailabilityState();
    _bleState = state.name;
    _bluetoothStateStreamController.add(state.name);
  }

  @override
  Future<String> bluetoothState() async => _bleState;

  @override
  Stream<String> get onBluetoothStateChanged =>
      _bluetoothStateStreamController.stream;

  @override
  Future<void> startScanningForBluetoothDevices() async {
    _activateIfNeeded();
    // `onScanResult` only fires for newly-seen peripherals (it ignores ids
    // already in `_devices`). Re-announce connected/known devices so
    // event-driven UIs refresh while scanning; disconnected devices are removed
    // from the cache and must be seen again before they are listed.
    if (_devices.isNotEmpty) {
      _setupStreamController.add(MidiSetupChange.deviceAppeared);
    }
    await UniversalBle.startScan(
      scanFilter: ScanFilter(withServices: [midiServiceId]),
    );
  }

  @override
  void stopScanningForBluetoothDevices() {
    UniversalBle.stopScan();
  }

  @override
  Future<List<MidiDevice>> get devices async => _devices.values.toList();

  @override
  MidiDevice? registerKnownDevice(String id, String name) {
    return _devices.putIfAbsent(
      id,
      () => _BleMidiDevice(
        deviceId: id,
        name: name,
        rxStream: _rxStreamController,
      ),
    );
  }

  @override
  Future<void> connectToDevice(
    MidiDevice device, {
    List<MidiPort>? ports,
    Duration? timeout,
  }) async {
    _activateIfNeeded();
    if (device.type != MidiDeviceType.ble) {
      return;
    }
    // Create the device on demand if we only know it by id (e.g. a bonded
    // peripheral exposed via CoreMIDI that was never scanned in this session).
    // universal_ble can connect to it by UUID via retrievePeripherals.
    final bleDevice =
        _devices[device.id] ??
        _devices.putIfAbsent(
          device.id,
          () => _BleMidiDevice(
            deviceId: device.id,
            name: device.name,
            rxStream: _rxStreamController,
          ),
        );
    try {
      await bleDevice.connect(timeout: timeout);
      if (!identical(bleDevice, device)) {
        device.connected = bleDevice.connected;
      }
      _setupStreamController.add(MidiSetupChange.deviceConnected);
    } catch (_) {
      if (!identical(bleDevice, device)) {
        device.connected = false;
      }
      _removeDisconnectedDevice(bleDevice.deviceId);
      rethrow;
    }
  }

  @override
  void disconnectDevice(MidiDevice device) {
    _activateIfNeeded();
    if (device.type != MidiDeviceType.ble) {
      return;
    }
    final bleDevice = _devices[device.id];
    if (bleDevice == null) {
      return;
    }
    unawaited(
      bleDevice.disconnect().whenComplete(() {
        _removeDisconnectedDevice(device.id);
      }),
    );
  }

  @override
  void sendData(Uint8List data, {int? timestamp, String? deviceId}) {
    _activateIfNeeded();
    if (deviceId != null) {
      _devices[deviceId]?.send(data);
      return;
    }
    for (final device in _devices.values.where((d) => d.connected)) {
      device.send(data);
    }
  }

  @override
  Stream<MidiPacket> get onMidiDataReceived => _rxStreamController.stream;

  @override
  Stream<MidiSetupChange> get onMidiSetupChanged =>
      _setupStreamController.stream;

  @override
  void teardown() {
    if (_isTornDown) {
      return;
    }
    _isTornDown = true;
    _unregisterCallbacks();
    unawaited(UniversalBle.stopScan());
    for (final device in _devices.values) {
      if (device.connectionState != MidiConnectionState.disconnected) {
        unawaited(device.disconnect());
      }
    }
    _devices.clear();
    _bleState = "unknown";
  }
}

class _BleMidiDevice extends MidiDevice {
  _BleMidiDevice({
    required this.deviceId,
    required String name,
    required StreamController<MidiPacket> rxStream,
  }) : _rxStreamCtrl = rxStream,
       super(deviceId, name, MidiDeviceType.ble, false);

  final String deviceId;
  final StreamController<MidiPacket> _rxStreamCtrl;

  _DeviceState _devState = _DeviceState.none;
  BleService? _midiService;
  BleCharacteristic? _midiCharacteristic;
  bool _bleLinkConnected = false;
  bool _readinessInProgress = false;

  void updateConnectionState(BleConnectionState state) {
    final isConnected = state == BleConnectionState.connected;
    _bleLinkConnected = isConnected;
    if (!isConnected) {
      connected = false;
      _devState = _DeviceState.none;
      _midiService = null;
      _midiCharacteristic = null;
      return;
    }

    unawaited(_requestMtu());
    if (!_readinessInProgress &&
        _devState.index < _DeviceState.interrogating.index) {
      unawaited(
        _prepareMidiReadiness().catchError((Object _) {
          connected = false;
        }),
      );
    }
  }

  void updatePairingState(bool value) {
    if (value && !_readinessInProgress) {
      unawaited(
        _startNotify()
            .then((_) {
              _devState = _DeviceState.available;
              connected = true;
            })
            .catchError((Object _) {}),
      );
    }
  }

  Future<void> connect({Duration? timeout}) async {
    if (connected) {
      return;
    }
    _readinessInProgress = true;
    try {
      await _runStage(
        MidiConnectionStage.bluetoothConnect,
        () => UniversalBle.connect(deviceId, timeout: timeout),
        timeout,
      );
      if (!_bleLinkConnected) {
        final connectionState = await _runStage(
          MidiConnectionStage.bluetoothConnect,
          () => UniversalBle.getConnectionState(deviceId, timeout: timeout),
          timeout,
        );
        _bleLinkConnected = connectionState == BleConnectionState.connected;
      }
      if (!_bleLinkConnected) {
        throw MidiConnectionException(
          deviceId: deviceId,
          stage: MidiConnectionStage.bluetoothConnect,
          message: 'BLE link did not reach the connected state.',
        );
      }
      await _prepareMidiReadiness(timeout: timeout);
      connected = true;
    } catch (_) {
      connected = false;
      try {
        await disconnect();
      } catch (_) {}
      rethrow;
    } finally {
      _readinessInProgress = false;
    }
  }

  Future<void> disconnect() async {
    if (_midiService != null && _midiCharacteristic != null) {
      try {
        await UniversalBle.unsubscribe(
          deviceId,
          _midiService!.uuid,
          _midiCharacteristic!.uuid,
        );
      } catch (_) {}
    }
    try {
      await UniversalBle.disconnect(deviceId);
    } catch (_) {
      // Ignore failures on teardown/disconnect path.
    }
    connected = false;
    _bleLinkConnected = false;
    _devState = _DeviceState.none;
    _midiService = null;
    _midiCharacteristic = null;
  }

  Future<void> send(Uint8List bytes) async {
    if (bytes.isEmpty) {
      return;
    }
    if (_midiService == null || _midiCharacteristic == null) {
      return;
    }

    const packetSize = 20;
    var dataBytes = List<int>.from(bytes);

    if (bytes.first == 0xF0 && bytes.last == 0xF7) {
      if (bytes.length > packetSize - 3) {
        var packet = dataBytes.take(packetSize - 2).toList();
        packet.insert(0, 0x80);
        packet.insert(0, 0x80);
        await _sendBytes(packet);
        dataBytes = dataBytes.skip(packetSize - 2).toList();

        while (dataBytes.isNotEmpty) {
          final pickCount = min(dataBytes.length, packetSize - 1);
          packet = dataBytes.getRange(0, pickCount).toList();
          packet.insert(0, 0x80);
          if (packet.length < packetSize) {
            packet.insert(packet.length - 1, 0x80);
          }
          await _sendBytes(packet);
          if (dataBytes.length > packetSize - 2) {
            dataBytes = dataBytes.skip(pickCount).toList();
          } else {
            return;
          }
        }
      } else {
        dataBytes.insert(bytes.length - 1, 0x80);
        dataBytes.insert(0, 0x80);
        dataBytes.insert(0, 0x80);
        await _sendBytes(dataBytes);
      }
      return;
    }

    var currentBuffer = <int>[];
    for (var i = 0; i < dataBytes.length; i++) {
      final byte = dataBytes[i];
      if ((byte & 0x80) != 0) {
        currentBuffer.insert(0, 0x80);
        currentBuffer.insert(0, 0x80);
      }
      currentBuffer.add(byte);

      final endReached = i == (dataBytes.length - 1);
      final isCompleteCommand = endReached || (dataBytes[i + 1] & 0x80) != 0;
      if (isCompleteCommand) {
        await _sendBytes(currentBuffer);
        currentBuffer = [];
      }
    }
  }

  Future<void> _sendBytes(List<int> bytes) async {
    try {
      await UniversalBle.write(
        deviceId,
        _midiService!.uuid,
        _midiCharacteristic!.uuid,
        Uint8List.fromList(bytes),
        withoutResponse: true,
      );
    } catch (_) {}
  }

  Future<void> _requestMtu() async {
    try {
      await UniversalBle.requestMtu(deviceId, 247);
    } catch (_) {}
  }

  Future<void> _prepareMidiReadiness({Duration? timeout}) async {
    await _discoverServices(timeout: timeout);
    await _ensurePaired(timeout: timeout);
    await _startNotify(timeout: timeout);
    _devState = _DeviceState.available;
  }

  Future<void> _discoverServices({Duration? timeout}) async {
    _devState = _DeviceState.interrogating;
    final services = await _runStage(
      MidiConnectionStage.serviceDiscovery,
      () => UniversalBle.discoverServices(deviceId, timeout: timeout),
      timeout,
    );
    _midiService = services
        .where((s) => s.uuid.toUpperCase() == midiServiceId)
        .firstOrNull;
    if (_midiService == null) {
      _devState = _DeviceState.irrelevant;
      throw MidiServiceDiscoveryException(deviceId: deviceId);
    }

    _midiCharacteristic = _midiService!.characteristics
        .where((c) => c.uuid.toUpperCase() == midiCharacteristicId)
        .firstOrNull;
    if (_midiCharacteristic == null) {
      _devState = _DeviceState.irrelevant;
      throw MidiServiceDiscoveryException(deviceId: deviceId);
    }
  }

  Future<void> _ensurePaired({Duration? timeout}) async {
    final isPaired = await _runStage(
      MidiConnectionStage.pairing,
      () => UniversalBle.isPaired(deviceId, timeout: timeout),
      timeout,
    );
    if (isPaired ?? false) {
      return;
    }

    try {
      if (isPaired == null) {
        await _runStage(
          MidiConnectionStage.pairing,
          () => UniversalBle.read(
            deviceId,
            _midiService!.uuid,
            _midiCharacteristic!.uuid,
            timeout: timeout,
          ),
          timeout,
        );
        return;
      }

      await _runStage(
        MidiConnectionStage.pairing,
        () => UniversalBle.pair(deviceId, timeout: timeout),
        timeout,
      );
      final pairedAfterPair = await _runStage(
        MidiConnectionStage.pairing,
        () => UniversalBle.isPaired(deviceId, timeout: timeout),
        timeout,
      );
      if (pairedAfterPair != true) {
        throw MidiPairingRejectedException(deviceId: deviceId);
      }
    } on MidiConnectionException {
      rethrow;
    } on PairingException catch (e) {
      throw MidiPairingRejectedException(deviceId: deviceId, cause: e);
    } catch (e) {
      throw MidiPairingFailedException(deviceId: deviceId, cause: e);
    }
  }

  Future<void> _startNotify({Duration? timeout}) async {
    if (_midiService == null || _midiCharacteristic == null) {
      return;
    }
    try {
      await _runStage(
        MidiConnectionStage.notificationSubscription,
        () => UniversalBle.subscribeNotifications(
          deviceId,
          _midiService!.uuid,
          _midiCharacteristic!.uuid,
          timeout: timeout,
        ),
        timeout,
      );
    } on MidiConnectionException {
      rethrow;
    } catch (e) {
      throw MidiNotificationSubscriptionException(deviceId: deviceId, cause: e);
    }
  }

  Future<T> _runStage<T>(
    MidiConnectionStage stage,
    Future<T> Function() action,
    Duration? timeout,
  ) async {
    try {
      final future = action();
      return timeout == null ? await future : await future.timeout(timeout);
    } on TimeoutException catch (e) {
      throw MidiConnectionTimeoutException(
        deviceId: deviceId,
        stage: stage,
        timeout: timeout,
        cause: e,
      );
    }
  }

  void handleData(Uint8List data) {
    _parseBlePacket(data);
  }

  _BleHandlerState bleHandlerState = _BleHandlerState.header;
  final List<int> _sysExBuffer = [];
  int _timestamp = 0;
  final List<int> _bleMidiBuffer = [];
  int _bleMidiPacketLength = 0;
  bool _bleSysExHasFinished = true;

  void _parseBlePacket(Uint8List packet) {
    if (packet.length <= 1) {
      return;
    }
    bleHandlerState = _BleHandlerState.header;
    final header = packet[0];
    var statusByte = 0;

    for (var i = 1; i < packet.length; i++) {
      final midiByte = packet[i];
      if (((midiByte & 0x80) == 0x80) &&
          bleHandlerState != _BleHandlerState.timestamp &&
          bleHandlerState != _BleHandlerState.sysexInt) {
        bleHandlerState = _bleSysExHasFinished
            ? _BleHandlerState.timestamp
            : _BleHandlerState.sysexInt;
      } else {
        switch (bleHandlerState) {
          case _BleHandlerState.header:
            if (!_bleSysExHasFinished) {
              bleHandlerState = (midiByte & 0x80) == 0x80
                  ? _BleHandlerState.sysexInt
                  : _BleHandlerState.sysex;
            }
            break;
          case _BleHandlerState.timestamp:
            if ((midiByte & 0xFF) == 0xF0) {
              _bleSysExHasFinished = false;
              _sysExBuffer.clear();
              bleHandlerState = _BleHandlerState.sysex;
            } else if ((midiByte & 0x80) == 0x80) {
              bleHandlerState = _BleHandlerState.status;
            } else {
              bleHandlerState = _BleHandlerState.statusRunning;
            }
            break;
          case _BleHandlerState.status:
          case _BleHandlerState.statusRunning:
            bleHandlerState = _BleHandlerState.params;
            break;
          case _BleHandlerState.sysexInt:
            if ((midiByte & 0xFF) == 0xF7) {
              _bleSysExHasFinished = true;
              bleHandlerState = _BleHandlerState.sysexEnd;
            } else {
              bleHandlerState = _BleHandlerState.systemRt;
            }
            break;
          case _BleHandlerState.systemRt:
            if (!_bleSysExHasFinished) {
              bleHandlerState = _BleHandlerState.sysex;
            }
            break;
          case _BleHandlerState.params:
          case _BleHandlerState.sysex:
          case _BleHandlerState.sysexEnd:
            break;
        }
      }

      switch (bleHandlerState) {
        case _BleHandlerState.timestamp:
          final tsHigh = header & 0x3F;
          final tsLow = midiByte & 0x7F;
          _timestamp = tsHigh << 7 | tsLow;
          break;
        case _BleHandlerState.status:
          _bleMidiPacketLength = _lengthOfMessageType(midiByte);
          _bleMidiBuffer
            ..clear()
            ..add(midiByte);
          if (_bleMidiPacketLength == 1) {
            _emit(_bleMidiBuffer, _timestamp);
          }
          statusByte = midiByte;
          break;
        case _BleHandlerState.statusRunning:
          _bleMidiPacketLength = _lengthOfMessageType(statusByte);
          _bleMidiBuffer
            ..clear()
            ..add(statusByte)
            ..add(midiByte);
          if (_bleMidiBuffer.length >= _bleMidiPacketLength) {
            _emit(_bleMidiBuffer, _timestamp);
          }
          break;
        case _BleHandlerState.params:
          _bleMidiBuffer.add(midiByte);
          if (_bleMidiBuffer.length >= _bleMidiPacketLength) {
            _emit(_bleMidiBuffer, _timestamp);
          }
          break;
        case _BleHandlerState.sysex:
        case _BleHandlerState.sysexInt:
          _sysExBuffer.add(midiByte);
          break;
        case _BleHandlerState.sysexEnd:
          _sysExBuffer.add(midiByte);
          _emit(_sysExBuffer, _timestamp);
          _sysExBuffer.clear();
          break;
        case _BleHandlerState.header:
        case _BleHandlerState.systemRt:
          break;
      }
    }
  }

  void _emit(List<int> bytes, int timestamp) {
    _rxStreamCtrl.add(
      MidiPacket(Uint8List.fromList(List<int>.from(bytes)), timestamp, this),
    );
  }

  int _lengthOfMessageType(int status) {
    final high = status & 0xF0;
    if (high == 0xC0 || high == 0xD0) {
      return 2;
    }
    if (high == 0x80 ||
        high == 0x90 ||
        high == 0xA0 ||
        high == 0xB0 ||
        high == 0xE0) {
      return 3;
    }
    return 1;
  }
}
