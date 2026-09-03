library;

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, visibleForTesting;
import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';
import 'package:universal_ble/universal_ble.dart';

const midiServiceId = "03B80E5A-EDE8-4B33-A751-6CE34EC4C700";
const midiCharacteristicId = "7772E5DB-3868-4112-A1A9-F2669D106BF3";

/// Smallest BLE MIDI packet size every peripheral must accept, derived from the
/// 23-byte default ATT MTU (20 = 23 - 3 bytes of ATT write overhead). Used
/// until an MTU exchange tells us we can do better, and as the floor if one
/// reports something implausible.
const _minBleMidiPacketSize = 20;

/// BLE MIDI header and timestamp bytes for timestamp 0.
///
/// The spec encodes a 13-bit millisecond timestamp as `0x80 | (ts >> 7)` in the
/// header and `0x80 | (ts & 0x7F)` in the timestamp byte. This transport does
/// not stamp outgoing messages, so both collapse to `0x80`.
const _bleMidiHeader = 0x80;
const _bleMidiTimestamp = 0x80;

enum _DeviceState { none, interrogating, available, irrelevant }

/// Unwraps this transport's own per-stage exceptions down to the platform
/// error underneath.
///
/// Each readiness stage wraps whatever it caught in a stage-specific
/// [MidiConnectionException], so classifying a failure by its platform cause
/// has to look through that wrapper.
Object _rootCause(Object error) {
  var current = error;
  while (current is MidiConnectionException) {
    final cause = current.cause;
    if (cause == null) {
      return current;
    }
    current = cause;
  }
  return current;
}

/// True when [error] is the universal_ble error surfaced when a peripheral has
/// discarded its side of a previous bond (iOS `CBErrorPeerRemovedPairingInformation`,
/// "Peer removed pairing information"). It arrives as an untyped
/// `UniversalBleException` with `unknownError`, so match on the message.
bool _isPairingInfoRemoved(Object error) =>
    error is UniversalBleException &&
    error.message.toLowerCase().contains('pairing information');

/// True when [error] says the link failed or went away underneath us, rather
/// than the peripheral answering with something meaningful. Such a failure is
/// usually transient, and a second attempt after a short settle succeeds.
///
/// Three shapes reach us.
///
/// `deviceDisconnected` is the least ambiguous: universal_ble fails every
/// in-flight GATT operation with it when an established connection is torn
/// down. It cannot arise from a peripheral that was never reachable — there
/// has to have been a connection to lose — so it always means the link dropped
/// mid-handshake. Platform-independent.
///
/// The other two are Android's generic `GATT_ERROR` (0x85 / 133), which the
/// stack returns for almost any connection that failed or was dropped during
/// the handshake and which universal_ble has no HCI name for. A failure on the
/// connect call itself carries no status of its own and arrives as
/// `UniversalBleException(unknownError, "Unknown Error 133")`. A GATT
/// operation that fails this way is named after the operation instead —
/// "Failed to update subscription state" — and carries the status in
/// `details`.
///
/// The `details` reading is deliberately restricted to Android. GATT status
/// codes are an Android concept, and Apple puts the raw `NSError` code in the
/// same field — where 133 is `0x85`, inside `CBATTError`'s application-defined
/// range, and means something else entirely.
bool _isTransientLinkFailure(Object error) {
  if (error is! UniversalBleException) {
    return false;
  }
  if (error.code == UniversalBleErrorCode.deviceDisconnected) {
    return true;
  }
  if (error.message.contains('Unknown Error 133')) {
    return true;
  }
  if (defaultTargetPlatform != TargetPlatform.android) {
    return false;
  }
  final details = error.details;
  return details == 133 || details == '133';
}

/// How long to let the Android stack settle before retrying through a
/// [_isTransientLinkFailure] failure.
const _gattRetryDelay = Duration(milliseconds: 500);

/// Cap on the opportunistic MTU exchange. Well under the 10 s global
/// universal_ble timeout so a peripheral that never answers cannot hold the
/// shared command queue.
const _mtuTimeout = Duration(seconds: 2);

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
  /// Creates the transport.
  ///
  /// [useNegotiatedMtu] sizes BLE MIDI packets from the negotiated ATT MTU
  /// instead of the 20-byte minimum, as the BLE MIDI specification prescribes.
  /// Set it to `false` for a peripheral that agrees to a large MTU but
  /// mishandles writes above 20 bytes; the symptom is SysEx arriving corrupt or
  /// not at all, appearing only after upgrading this package.
  ///
  /// [requestHighPerformanceConnection] asks for a ~7.5-15 ms connection
  /// interval rather than the OS default of ~30-50 ms, which bounds MIDI
  /// latency. Set it to `false` in battery-sensitive apps that do not need low
  /// latency. Only Android implements the hint.
  ///
  /// Both only matter where this transport carries the data. On iOS and macOS
  /// `MidiCommand` hands a connected device to CoreMIDI, which then owns the
  /// write path.
  UniversalBleMidiTransport({
    this.useNegotiatedMtu = true,
    this.requestHighPerformanceConnection = true,
  }) {
    UniversalBle.timeout = const Duration(seconds: 10);
    _registerCallbacks();
    _reportWriteBacklog();
  }

  /// Highest command queue depth reported since it was last empty.
  int _peakQueueDepth = 0;

  /// Reports when writes back up behind the link, meaning the application is
  /// sending faster than it drains.
  ///
  /// Sampled at powers of four so a bulk transfer cannot flood the log.
  void _reportWriteBacklog() {
    UniversalBle.onQueueUpdate = (String queueId, int pendingCommands) {
      if (pendingCommands == 0) {
        _peakQueueDepth = 0;
        return;
      }
      if (pendingCommands <= _peakQueueDepth) return;
      _peakQueueDepth = pendingCommands;
      if (pendingCommands == 4 ||
          pendingCommands == 16 ||
          pendingCommands == 64 ||
          pendingCommands == 256) {
        _log(
          'write queue depth reached $pendingCommands on "$queueId"; '
          'sends are outrunning the link',
        );
      }
    };
  }

  /// See [UniversalBleMidiTransport.new].
  final bool useNegotiatedMtu;

  /// See [UniversalBleMidiTransport.new].
  final bool requestHighPerformanceConnection;

  /// Optional sink for diagnostics (MTU negotiation, packet sizing, connection
  /// priority, write backlog). Defaults to null (silent).
  ///
  /// `transport.logHandler = (m) => debugPrint(m);`
  void Function(String message)? logHandler;

  void _log(String message) =>
      logHandler?.call('[flutter_midi_command_ble] $message');

  final _rxStreamController = StreamController<MidiPacket>.broadcast();
  final _writeFailureStreamController =
      StreamController<MidiWriteFailure>.broadcast();
  final _setupStreamController = StreamController<MidiSetupChange>.broadcast();
  final _bluetoothStateStreamController = StreamController<String>.broadcast();
  final Map<String, _BleMidiDevice> _devices = {};
  String _bleState = "unknown";
  bool _callbacksRegistered = false;
  bool _isTornDown = false;
  // Tracks whether an OS scan is currently running so that redundant start/stop
  // calls from the host app become no-ops. On Android a duplicate `stopScan`
  // desyncs the platform scanner registration ("could not find callback
  // wrapper"), after which the scanner re-registers but delivers no results
  // until the process is restarted.
  bool _isScanning = false;

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
      if (result.name == null) {
        return;
      }
      final existing = _devices[result.deviceId];
      if (existing != null) {
        existing.name = result.name!;
        if (!existing.visible) {
          existing.visible = true;
          _setupStreamController.add(MidiSetupChange.deviceAppeared);
        }
        return;
      }
      _devices[result.deviceId] = _createDevice(
        deviceId: result.deviceId,
        name: result.name!,
        visible: true,
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
    if (_devices.values.any((device) => device.visible)) {
      _setupStreamController.add(MidiSetupChange.deviceAppeared);
    }
    // Re-issuing an OS scan while one is already running desyncs the Android
    // scanner registration, so skip a redundant start.
    if (_isScanning) {
      return;
    }
    _isScanning = true;
    try {
      await UniversalBle.startScan(
        scanFilter: ScanFilter(withServices: [midiServiceId]),
      );
    } catch (_) {
      _isScanning = false;
      rethrow;
    }
  }

  @override
  void stopScanningForBluetoothDevices() {
    // Only forward a stop when we believe a scan is running. A duplicate
    // stopScan desyncs the Android scanner registration.
    if (!_isScanning) {
      return;
    }
    _isScanning = false;
    unawaited(_stopScanIgnoringFailure());
  }

  /// Stops scanning, absorbing the failure.
  ///
  /// Android rejects a stop when the adapter has been switched off, which is an
  /// ordinary thing for a user to do mid-scan. Both callers are void, so there
  /// is nobody to surface it to, and letting the future reject unhandled turns
  /// it into a crash report.
  Future<void> _stopScanIgnoringFailure() async {
    try {
      await UniversalBle.stopScan();
    } catch (error) {
      _log('stopScan failed: $error');
    }
  }

  @override
  Future<List<MidiDevice>> get devices async =>
      _devices.values.where((device) => device.visible).toList();

  @override
  MidiDevice? registerKnownDevice(String id, String name) {
    return _devices.putIfAbsent(
      id,
      () => _createDevice(deviceId: id, name: name, visible: false),
    );
  }

  _BleMidiDevice _createDevice({
    required String deviceId,
    required String name,
    required bool visible,
  }) {
    return _BleMidiDevice(
      deviceId: deviceId,
      name: name,
      visible: visible,
      rxStream: _rxStreamController,
      writeFailureStream: _writeFailureStreamController,
      useNegotiatedMtu: useNegotiatedMtu,
      requestHighPerformanceConnection: requestHighPerformanceConnection,
      log: _log,
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
          () => _createDevice(
            deviceId: device.id,
            name: device.name,
            visible: true,
          ),
        );
    try {
      await bleDevice.connect(timeout: timeout);
      // A connection attempt that dropped before succeeding (an Android GATT
      // 133 we retried through) reports a disconnect, which evicts the device
      // from the cache. Put it back, or incoming data and by-id sends would
      // have nothing to resolve to.
      _devices[bleDevice.deviceId] = bleDevice;
      bleDevice.visible = true;
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
    unawaited(sendDataAwaitingDelivery(data, deviceId: deviceId));
  }

  @override
  Future<void> sendDataAwaitingDelivery(
    Uint8List data, {
    int? timestamp,
    String? deviceId,
  }) {
    _activateIfNeeded();
    if (deviceId != null) {
      return _devices[deviceId]?.send(data) ?? Future<void>.value();
    }
    return Future.wait([
      for (final device in _devices.values.where((d) => d.connected))
        device.send(data),
    ]);
  }

  @override
  Stream<MidiPacket> get onMidiDataReceived => _rxStreamController.stream;

  @override
  Stream<MidiSetupChange> get onMidiSetupChanged =>
      _setupStreamController.stream;

  @override
  Stream<MidiWriteFailure> get onWriteFailure =>
      _writeFailureStreamController.stream;

  @override
  void teardown() {
    if (_isTornDown) {
      return;
    }
    _isTornDown = true;
    _unregisterCallbacks();
    // Only forward a stop when a scan is actually running. A stopScan with no
    // live scan desyncs the Android scanner registration ("could not find
    // callback wrapper").
    if (_isScanning) {
      _isScanning = false;
      unawaited(_stopScanIgnoringFailure());
    }
    for (final device in _devices.values) {
      if (device.connectionState != MidiConnectionState.disconnected) {
        unawaited(device.disconnect());
      }
    }
    _devices.clear();
    _bleState = "unknown";
  }
}

/// Splits a complete SysEx message into BLE MIDI packets of at most
/// [maxWriteSize] bytes.
///
/// [bytes] must be a full message, `0xF0 ... 0xF7`. The framing follows the
/// MMA BLE MIDI specification, which is what [_BleMidiDevice._parseBlePacket]
/// expects on the way back in:
///
/// - every packet opens with a header byte;
/// - the first packet also carries a timestamp byte before the `0xF0`;
/// - continuation packets carry raw data only;
/// - the closing `0xF7` is always preceded by a timestamp byte.
///
/// [maxWriteSize] is the negotiated ATT MTU minus 3 bytes of write overhead,
/// floored at [_minBleMidiPacketSize].
@visibleForTesting
List<List<int>> buildBleMidiSysExPackets(List<int> bytes, int maxWriteSize) {
  final writeSize = max(_minBleMidiPacketSize, maxWriteSize);

  // header + timestamp + payload + timestamp + 0xF7
  if (bytes.length + 3 <= writeSize) {
    return [
      [
        _bleMidiHeader,
        _bleMidiTimestamp,
        ...bytes.sublist(0, bytes.length - 1),
        _bleMidiTimestamp,
        bytes.last,
      ],
    ];
  }

  // Everything up to but excluding the closing 0xF7. The terminator is emitted
  // with its timestamp byte by whichever packet has room for both.
  final payload = bytes.sublist(0, bytes.length - 1);
  final packets = <List<int>>[];
  var offset = 0;
  var isFirst = true;
  var closed = false;

  while (offset < payload.length) {
    // The first packet spends one extra byte on the timestamp before 0xF0.
    final overhead = isFirst ? 2 : 1;
    final capacity = writeSize - overhead;
    // A packet that also closes the SysEx needs two more bytes for the
    // timestamp and 0xF7.
    final closingCapacity = capacity - 2;
    final remaining = payload.length - offset;

    final canClose = remaining <= closingCapacity;
    final take = canClose ? remaining : min(capacity, remaining);

    final packet = <int>[
      _bleMidiHeader,
      if (isFirst) _bleMidiTimestamp,
      ...payload.getRange(offset, offset + take),
    ];
    if (canClose) {
      packet
        ..add(_bleMidiTimestamp)
        ..add(bytes.last);
      closed = true;
    }
    packets.add(packet);
    offset += take;
    isFirst = false;
  }

  // The payload filled the last packet exactly, leaving no room for the
  // terminator. A packet holding only the terminator is valid framing.
  if (!closed) {
    packets.add([_bleMidiHeader, _bleMidiTimestamp, bytes.last]);
  }

  return packets;
}

class _BleMidiDevice extends MidiDevice {
  _BleMidiDevice({
    required this.deviceId,
    required String name,
    required this.visible,
    required StreamController<MidiPacket> rxStream,
    required StreamController<MidiWriteFailure> writeFailureStream,
    required this.useNegotiatedMtu,
    required this.requestHighPerformanceConnection,
    required void Function(String message) log,
  }) : _rxStreamCtrl = rxStream,
       _writeFailureStreamCtrl = writeFailureStream,
       _log = log,
       super(deviceId, name, MidiDeviceType.ble, false);

  final String deviceId;
  final StreamController<MidiPacket> _rxStreamCtrl;
  final StreamController<MidiWriteFailure> _writeFailureStreamCtrl;
  final bool useNegotiatedMtu;
  final bool requestHighPerformanceConnection;
  final void Function(String message) _log;
  bool visible;

  _DeviceState _devState = _DeviceState.none;
  BleService? _midiService;
  BleCharacteristic? _midiCharacteristic;
  bool _bleLinkConnected = false;
  bool _readinessInProgress = false;

  /// Whether this device is currently held at the high-performance connection
  /// interval, and so has something to hand back on teardown.
  bool _priorityRaised = false;

  /// Largest BLE MIDI packet this link accepts, set from the negotiated MTU in
  /// [_requestMtu]. Reset on every disconnect so a large size cannot survive
  /// into a reconnect that negotiates a smaller MTU.
  int _maxWriteSize = _minBleMidiPacketSize;

  /// Length of the last SysEx whose packet split was logged, so a bulk
  /// transfer reports its shape once instead of once per message.
  int? _loggedSysExLength;

  void updateConnectionState(BleConnectionState state) {
    final isConnected = state == BleConnectionState.connected;
    _bleLinkConnected = isConnected;
    if (!isConnected) {
      connected = false;
      _devState = _DeviceState.none;
      _midiService = null;
      _midiCharacteristic = null;
      _maxWriteSize = _minBleMidiPacketSize;
      _loggedSysExLength = null;
      return;
    }

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

  /// Brings the device to MIDI readiness, retrying the whole sequence once
  /// through a transient Android `GATT_ERROR`.
  ///
  /// [_connectLink] already retries a connect that fails outright, but the link
  /// can also come up and then drop part-way through the handshake — most often
  /// when reconnecting shortly after a disconnect, before the Android stack has
  /// settled. That surfaces as a failed service discovery or subscription
  /// rather than a failed connect, and needs the same treatment: tear the
  /// half-built connection down and start over from a fresh GATT client.
  Future<void> connect({Duration? timeout}) async {
    if (connected) {
      return;
    }
    _readinessInProgress = true;
    try {
      for (var attempt = 0; ; attempt++) {
        try {
          await _connectOnce(timeout: timeout);
          connected = true;
          return;
        } catch (error) {
          connected = false;
          try {
            await disconnect();
          } catch (_) {}
          final cause = _rootCause(error);
          if (_isPairingInfoRemoved(cause)) {
            // Best-effort clear of the stale bond so a later reconnect can
            // re-pair cleanly. Unsupported on iOS (CoreBluetooth has no unpair
            // API), so ignore failures; the surfaced exception tells the user
            // what to do.
            try {
              await UniversalBle.unpair(deviceId);
            } catch (_) {}
            throw MidiPairingInfoRemovedException(
              deviceId: deviceId,
              cause: error,
            );
          }
          if (attempt > 0 || !_isTransientLinkFailure(cause)) {
            rethrow;
          }
          _log('$deviceId: link dropped during setup ($error); retrying once');
        }
        await Future<void>.delayed(_gattRetryDelay);
      }
    } finally {
      _readinessInProgress = false;
    }
  }

  Future<void> _connectOnce({Duration? timeout}) async {
    await _connectLink(timeout: timeout);
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
  }

  /// Brings up the BLE link.
  ///
  /// A transient `GATT_ERROR` here is retried by [connect], which owns the
  /// single retry for the whole sequence — the link and the readiness stages
  /// fail the same way for the same reason, and its teardown already asks the
  /// stack for a fresh GATT client.
  Future<void> _connectLink({Duration? timeout}) async {
    await _runStage(
      MidiConnectionStage.bluetoothConnect,
      () => UniversalBle.connect(deviceId, timeout: timeout),
      timeout,
    );
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
    // Hand the radio back to the default interval before dropping the link.
    // Belt and braces: the OS resets connection parameters when the link goes
    // away, so this only matters if the disconnect itself does not complete.
    // Skipped when we never raised it — on a failed connect there is nothing to
    // hand back, and asking would only log a refusal for a device that is
    // already gone.
    if (_priorityRaised) {
      await _requestConnectionPriority(BleConnectionPriority.balanced);
      _priorityRaised = false;
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
    _maxWriteSize = _minBleMidiPacketSize;
    _loggedSysExLength = null;
  }

  Future<void> _sendChain = Future<void>.value();

  /// Sends [bytes], completing once written.
  ///
  /// Serialized: a SysEx spans several BLE packets that the receiver
  /// reassembles statefully, so two overlapping sends would interleave their
  /// packets in universal_ble's shared queue and the peripheral would
  /// reassemble one message out of two.
  Future<void> send(Uint8List bytes) {
    final delivered = _sendChain.then((_) => _writeMessage(bytes));
    // Absorb errors here, or one failed write stalls every later send.
    _sendChain = delivered.catchError((Object _) {});
    return delivered;
  }

  Future<void> _writeMessage(Uint8List bytes) async {
    if (bytes.isEmpty) {
      return;
    }
    if (_midiService == null || _midiCharacteristic == null) {
      return;
    }

    if (bytes.first == 0xF0 && bytes.last == 0xF7) {
      final packets = buildBleMidiSysExPackets(bytes, _maxWriteSize);
      if (bytes.length != _loggedSysExLength) {
        // Once per distinct SysEx size: a bulk transfer sends thousands of
        // identical-length messages and this is the number that decides how
        // long it takes.
        _loggedSysExLength = bytes.length;
        _log(
          '$deviceId: ${bytes.length}-byte SysEx -> ${packets.length} '
          'write(s) at $_maxWriteSize bytes',
        );
      }
      for (final packet in packets) {
        await _sendBytes(packet);
      }
      return;
    }

    // Channel and system messages are a few bytes each, so they are framed one
    // message per packet and never need splitting.
    final dataBytes = List<int>.from(bytes);
    var currentBuffer = <int>[];
    for (var i = 0; i < dataBytes.length; i++) {
      final byte = dataBytes[i];
      if ((byte & 0x80) != 0) {
        currentBuffer.insert(0, _bleMidiTimestamp);
        currentBuffer.insert(0, _bleMidiHeader);
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

  /// Writes one BLE MIDI packet, reporting rather than rethrowing a failure.
  ///
  /// Aborting mid-SysEx would leave the peripheral parsing a truncated
  /// message, so the remaining packets still go out and callers learn about it
  /// through [UniversalBleMidiTransport.onWriteFailure].
  Future<void> _sendBytes(List<int> bytes) async {
    try {
      await UniversalBle.write(
        deviceId,
        _midiService!.uuid,
        _midiCharacteristic!.uuid,
        Uint8List.fromList(bytes),
        withoutResponse: true,
      );
    } catch (error, stackTrace) {
      if (!_writeFailureStreamCtrl.isClosed) {
        _writeFailureStreamCtrl.add(
          MidiWriteFailure(
            deviceId: deviceId,
            error: error,
            stackTrace: stackTrace,
          ),
        );
      }
    }
  }

  /// Negotiates a larger ATT MTU and sizes outgoing packets from the result.
  ///
  /// `mtu - 3` is what fits in one write on both platforms: Android reports the
  /// ATT MTU, and universal_ble's darwin side returns
  /// `maximumWriteValueLength(.withoutResponse) + 3`.
  ///
  /// Opportunistic — failures are swallowed and leave packets at
  /// [_minBleMidiPacketSize], because an MTU exchange must never cost a
  /// working link.
  Future<void> _requestMtu() async {
    if (!useNegotiatedMtu) {
      _log(
        '$deviceId: MTU sizing disabled, packets stay at '
        '$_minBleMidiPacketSize bytes',
      );
      return;
    }
    try {
      final mtu = await UniversalBle.requestMtu(
        deviceId,
        247,
        timeout: _mtuTimeout,
      );
      _maxWriteSize = max(_minBleMidiPacketSize, mtu - 3);
      _log('$deviceId: negotiated MTU $mtu, packet size $_maxWriteSize bytes');
    } catch (error) {
      _log(
        '$deviceId: MTU negotiation failed ($error), packets stay at '
        '$_maxWriteSize bytes',
      );
    }
  }

  /// Asks for a low-latency connection interval (~7.5-15 ms instead of the
  /// ~30-50 ms default), which is the floor on MIDI latency.
  ///
  /// Best-effort: only Android implements it, and a peripheral can decline.
  Future<void> _requestConnectionPriority(
    BleConnectionPriority priority,
  ) async {
    if (!requestHighPerformanceConnection) {
      return;
    }
    try {
      await UniversalBle.requestConnectionPriority(
        deviceId,
        priority,
        timeout: _mtuTimeout,
      );
      _priorityRaised = priority == BleConnectionPriority.highPerformance;
      _log('$deviceId: connection priority set to ${priority.name}');
    } catch (error) {
      _log(
        '$deviceId: connection priority ${priority.name} refused '
        '($error); the OS interval applies',
      );
    }
  }

  Future<void> _prepareMidiReadiness({Duration? timeout}) async {
    await _discoverServices(timeout: timeout);
    await _ensurePaired(timeout: timeout);
    await _startNotify(timeout: timeout);
    // Deliberately after the MIDI path is live: universal_ble runs GATT
    // commands through one queue, so an MTU request issued on the connection
    // callback sits in front of service discovery and can stall it — long
    // enough on Android that the peripheral drops the link with GATT_ERROR
    // 133 before the MIDI service is ever discovered. The connection priority
    // request shares that queue and so shares the constraint.
    await _requestMtu();
    await _requestConnectionPriority(BleConnectionPriority.highPerformance);
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
          _sysExBuffer.add(midiByte);
          break;
        case _BleHandlerState.sysexInt:
          // Entered by the BLE timestamp byte that precedes an in-SysEx
          // system-real-time message or the closing 0xF7. It is transport
          // framing, not payload, so it must not be appended to the SysEx.
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
