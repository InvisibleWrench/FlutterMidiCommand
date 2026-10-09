library;

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';
import 'package:universal_ble/universal_ble.dart';

const midiServiceId = "03B80E5A-EDE8-4B33-A751-6CE34EC4C700";
const midiCharacteristicId = "7772E5DB-3868-4112-A1A9-F2669D106BF3";

/// Whether [uuid] is the BLE MIDI service, whatever case it was reported in.
///
/// Every universal_ble platform reports 128-bit UUIDs lowercase and hyphenated,
/// both from advertisements and from service discovery, while [midiServiceId] is
/// uppercase. The MIDI service is a vendor UUID, so it is never abbreviated to a
/// 16-bit form and a case-folded comparison is enough — no UUID parse per
/// advertised service, which matters because Apple scans with duplicates
/// allowed and so delivers a result per advertising packet.
bool _isMidiServiceUuid(String uuid) => uuid.toUpperCase() == midiServiceId;

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

/// True when [error] is a peripheral refusing the subscription for want of an
/// encrypted link, rather than for a reason a bond cannot fix.
///
/// This transport subscribes first and bonds only on demand
/// ([_BleMidiDevice._openMidiPath]), so this predicate is what decides whether
/// the user is shown a system pairing dialog. It therefore errs towards not
/// escalating: a dialog for a peripheral that was never going to work is worse
/// than a typed subscription error.
///
/// Two shapes qualify. The first is a security status the peripheral returned
/// against the CCCD write — Insufficient Authentication (ATT 0x05),
/// Authorization (0x08), Encryption Key Size (0x0C) or Encryption (0x0F),
/// which Android maps to typed codes on the descriptor-write callback, plus
/// the pairing-state codes other platforms use to say the same thing.
///
/// The second is an error whose code is itself an admission that the stack
/// does not know what went wrong: `failed` and `unknownError`, where Android's
/// unmapped ATT statuses land. Without these, a peripheral that refuses for
/// want of a bond but whose status got mangled would be a regression against
/// the bond-first sequence this replaced; with them, such a peripheral reaches
/// exactly the outcome it used to, dialog and all.
///
/// Everything else is excluded deliberately, and each exclusion is a failure
/// a bond cannot help with: `characteristicDoesNotSupportNotify` and the
/// not-found codes (not a working BLE MIDI peripheral),
/// `bluetoothNotAllowed` (the app is missing `BLUETOOTH_CONNECT`, and `pair`
/// would fail the same way while hiding the real cause), `notPairable`,
/// `pairingNotAllowed` and `alreadyPaired` (the platform has already said what
/// is on offer), and anything that is not a [UniversalBleException] at all —
/// in particular a [TimeoutException], where escalating would spend the
/// caller's readiness budget twice over on a peripheral that is not answering.
///
/// A link that dropped is classified by [_isTransientLinkFailure] before this
/// is consulted. A peer that discarded its side of an existing bond is
/// excluded here explicitly: it arrives as an untyped `unknownError` that the
/// second clause would otherwise swallow, and it needs the stale bond cleared,
/// which [_BleMidiDevice.connect] does, rather than a new one created.
bool _refusedForWantOfBond(Object error) {
  if (error is! UniversalBleException || _isPairingInfoRemoved(error)) {
    return false;
  }
  switch (error.code) {
    case UniversalBleErrorCode.insufficientAuthentication:
    case UniversalBleErrorCode.insufficientAuthorization:
    case UniversalBleErrorCode.insufficientEncryption:
    case UniversalBleErrorCode.insufficientKeySize:
    case UniversalBleErrorCode.authenticationFailure:
    case UniversalBleErrorCode.protectionLevelNotMet:
    case UniversalBleErrorCode.accessDenied:
    case UniversalBleErrorCode.notPaired:
    case UniversalBleErrorCode.failed:
    case UniversalBleErrorCode.unknownError:
      return true;
    default:
      return false;
  }
}

/// How long to let the Android stack settle before each retry through a
/// [_isTransientLinkFailure] failure, and by its length how many retries there
/// are.
///
/// Growing rather than fixed, because the two cases behind these failures
/// settle on different timescales. A link dropped mid-handshake while
/// reconnecting is usually ready again almost immediately, which the first
/// delay covers. A peripheral that has only just powered on is not: it answers
/// `connect` with a generic `GATT_ERROR` until its radio is ready, and
/// observed against one such peripheral, two attempts half a second apart both
/// failed where an attempt two and a half seconds in succeeded.
///
/// The cost is borne by a peripheral that is genuinely absent, which now takes
/// the sum of these before it is reported — so they are kept short enough to
/// stay inside a default `awaitConnectionTimeout` alongside the attempts
/// themselves.
const _gattRetryDelays = <Duration>[
  Duration(milliseconds: 500),
  Duration(seconds: 2),
];

/// Cap on the opportunistic MTU exchange. Well under the 10 s global
/// universal_ble timeout so a peripheral that never answers cannot hold the
/// shared command queue.
const _mtuTimeout = Duration(seconds: 2);

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
  ///
  /// [requireAdvertisedMidiService] makes a peripheral this transport has not
  /// seen before advertise the BLE MIDI service to be listed. universal_ble
  /// delivers every scan result to every listener, whoever started the scan and
  /// whatever filter they used, so an app that also scans for its own
  /// peripherals would otherwise fill `MidiCommand.devices` with headphones and
  /// watches. Defaults to `false` on web, where a scan is the browser's device
  /// chooser and the chosen device carries no advertisement to read.
  ///
  /// A peripheral that does not advertise the service can still be used: pass it
  /// to [registerKnownDevice], or connect to it by id. Devices this transport
  /// already knows are never filtered.
  /// [hideUnseenPeripheralsAfter] is how long a peripheral stays listed after
  /// its last advertisement while a scan is running. A peripheral that is
  /// switched off or carried out of range stops advertising but says nothing,
  /// so without this it stays in [devices] until it is connected and
  /// disconnected again, or the transport is torn down. Set it to null to keep
  /// every peripheral that has ever been seen.
  ///
  /// Aging only runs while scanning, because a peripheral cannot be expected to
  /// advertise when nobody is listening, and it never applies to a peripheral
  /// that is connected or on its way there — most stop advertising once
  /// connected, and hiding the device an application is using would be worse
  /// than the stale entry this removes.
  UniversalBleMidiTransport({
    this.useNegotiatedMtu = true,
    this.requestHighPerformanceConnection = true,
    this.requireAdvertisedMidiService = !kIsWeb,
    this.hideUnseenPeripheralsAfter = const Duration(seconds: 10),
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
  final bool requireAdvertisedMidiService;

  /// See [UniversalBleMidiTransport.new].
  final bool requestHighPerformanceConnection;

  /// See [UniversalBleMidiTransport.new].
  final Duration? hideUnseenPeripheralsAfter;

  /// Optional sink for diagnostics (MTU negotiation, packet sizing, connection
  /// priority, write backlog, and incoming framing this transport could not
  /// use). Defaults to null (silent).
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
  StreamSubscription<BleDevice>? _scanSubscription;
  // Peripherals already reported as carrying no BLE MIDI service, so the log
  // line is written once per device rather than once per advertising packet.
  // Deliberately not a short-circuit: a device whose MIDI service arrives in a
  // later advertisement is still picked up.
  final Set<String> _nonMidiDeviceIds = {};

  /// Sweeps [_devices] for peripherals that have stopped advertising. Runs only
  /// while a scan is running.
  Timer? _agingTimer;

  void _registerCallbacks() {
    if (_callbacksRegistered) {
      return;
    }
    _callbacksRegistered = true;

    UniversalBle.onAvailabilityChange = (state) {
      _bleState = state.name;
      _bluetoothStateStreamController.add(state.name);
    };

    // Deliberately the stream rather than `UniversalBle.onScanResult`: that is a
    // single app-wide slot with no getter, so taking it would silently stop the
    // host app's own scan handling, and the host app assigning it after this
    // transport was constructed would silently stop MIDI discovery. The stream
    // carries the same results, in the same order, to every listener.
    _scanSubscription = UniversalBle.scanStream.listen((result) {
      if (result.name == null) {
        return;
      }
      final existing = _devices[result.deviceId];
      if (existing == null && !_advertisesMidiService(result)) {
        if (_nonMidiDeviceIds.add(result.deviceId)) {
          _log(
            'ignoring "${result.name}" (${result.deviceId}): no BLE MIDI '
            'service in its advertisement',
          );
        }
        return;
      }
      if (existing != null) {
        existing.name = result.name!;
        existing.lastSeen = DateTime.now();
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
      )..lastSeen = DateTime.now();
      _setupStreamController.add(MidiSetupChange.deviceAppeared);
    });

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

  /// Whether a scan result looks like a BLE MIDI peripheral.
  ///
  /// Gates on the advertisement rather than on this transport's own
  /// [ScanFilter], because the scan results reaching us are not necessarily from
  /// our scan. It asks exactly what universal_ble's `withServices` filter asks
  /// natively on Android, Apple, Windows and Linux, so a result our own scan
  /// produced always passes.
  bool _advertisesMidiService(BleDevice result) =>
      !requireAdvertisedMidiService || result.services.any(_isMidiServiceUuid);

  void _unregisterCallbacks() {
    if (!_callbacksRegistered) {
      return;
    }
    unawaited(_scanSubscription?.cancel());
    _scanSubscription = null;
    _stopAging();
    _nonMidiDeviceIds.clear();
    UniversalBle.onAvailabilityChange = null;
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

  /// Starts the aging sweep, if it is enabled and not already running.
  void _startAging() {
    final window = hideUnseenPeripheralsAfter;
    if (window == null || _agingTimer != null) {
      return;
    }
    // Sweep at half the window, so the worst-case delay before a peripheral
    // drops out is one and a half windows rather than two. Guarded against a
    // zero period only — a window short enough to make this hot is the
    // caller's choice, and clamping it would make the knob mean something
    // other than what it says.
    final half = window ~/ 2;
    final period = half > Duration.zero
        ? half
        : const Duration(milliseconds: 1);
    _agingTimer = Timer.periodic(period, (_) => _hideUnseenPeripherals(window));
  }

  void _stopAging() {
    _agingTimer?.cancel();
    _agingTimer = null;
  }

  /// Hides peripherals that have not advertised within [window].
  ///
  /// Hidden rather than removed, so the [MidiDevice] an application is holding
  /// stays the same object when the peripheral comes back; [devices] already
  /// filters on [MidiDevice.visible]. A peripheral that is connected or on its
  /// way there is never hidden, because most stop advertising once connected.
  void _hideUnseenPeripherals(Duration window) {
    final cutoff = DateTime.now().subtract(window);
    var hidAny = false;
    for (final device in _devices.values) {
      if (!device.visible ||
          device.connectionState != MidiConnectionState.disconnected) {
        continue;
      }
      final lastSeen = device.lastSeen;
      if (lastSeen == null || lastSeen.isAfter(cutoff)) {
        continue;
      }
      device.visible = false;
      hidAny = true;
      _log(
        '${device.deviceId}: no advertisement for '
        '${window.inSeconds}s, hiding it',
      );
    }
    if (hidAny) {
      _setupStreamController.add(MidiSetupChange.deviceDisappeared);
    }
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
    _startAging();
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
    _stopAging();
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
/// MMA BLE MIDI specification, which is what [BleMidiFramer] expects on the
/// way back in:
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

/// A slice of MIDI bytes carved out of a BLE MIDI packet, with the transport's
/// framing removed.
///
/// [bytes] are pure MIDI — they still have to be assembled into messages, which
/// is [MidiMessageSplitter]'s job. [timestamp] is the 13-bit millisecond value
/// of the BLE MIDI timestamp byte that introduced the run.
@visibleForTesting
class BleMidiRun {
  const BleMidiRun(this.timestamp, this.bytes);

  final int timestamp;
  final List<int> bytes;

  @override
  String toString() => 'BleMidiRun($timestamp, $bytes)';
}

/// Strips BLE MIDI framing from an incoming packet, leaving runs of MIDI bytes.
///
/// This is the inverse of [buildBleMidiSysExPackets] and the first of the two
/// receive stages; [MidiMessageSplitter] is the second. Splitting them keeps
/// the transport's framing rules out of the MIDI-assembly rules, which is what
/// the single nine-state machine this replaced got wrong.
///
/// The framing, per the MMA BLE MIDI specification:
///
/// - a packet opens with a header byte carrying the timestamp's high 6 bits;
/// - a timestamp byte (high bit set) carries the low 7 bits and introduces a
///   MIDI message, whose first byte follows unconditionally — that byte may be
///   a status byte, and must not be mistaken for another timestamp;
/// - further bytes with the high bit clear continue the run, which is how a
///   device sends several running-status messages under one timestamp;
/// - inside a SysEx a timestamp byte introduces either the closing `0xF7` or a
///   System Real-Time message, and is itself payload-free framing;
/// - a SysEx continuation packet carries raw data with no timestamp at all.
///
/// Whether a SysEx is open is the only state that has to survive a packet
/// boundary, and it is kept in step with the splitter's own view by the same
/// rules ([_trackSysEx]).
@visibleForTesting
class BleMidiFramer {
  BleMidiFramer({this.onFramingWarning});

  /// Reports framing this parser could not use, so a peripheral that frames
  /// its MIDI in a way the specification does not allow can be identified from
  /// a log rather than from the absence of messages.
  ///
  /// Diagnostics only: nothing here changes what is parsed.
  final void Function(String message)? onFramingWarning;

  /// Whether a SysEx is open, which is what tells a continuation packet's
  /// leading data bytes apart from stray junk.
  bool _inSysEx = false;

  /// Timestamp carried over for a continuation packet, which has none of its
  /// own.
  int _lastTimestamp = 0;

  /// Carves [packet] into runs of MIDI bytes. Returns an empty list for a
  /// packet too short to hold anything (header only, or empty).
  List<BleMidiRun> parse(List<int> packet) {
    if (packet.length <= 1) {
      return const [];
    }

    final runs = <BleMidiRun>[];
    final timestampHigh = packet[0] & 0x3F;
    var current = <int>[];
    var currentTimestamp = _lastTimestamp;

    void flush() {
      if (current.isNotEmpty) {
        runs.add(BleMidiRun(currentTimestamp, current));
        current = <int>[];
      }
    }

    var i = 1;
    while (i < packet.length) {
      final byte = packet[i];

      if ((byte & 0x80) == 0) {
        // A data byte continues the run in progress. With no run and no SysEx
        // open it is framing junk — a packet may not start with payload.
        if (current.isNotEmpty || _inSysEx) {
          current.add(byte);
        }
        i++;
        continue;
      }

      // A timestamp byte. The byte after it belongs to the message it
      // introduces, whatever its high bit says.
      _lastTimestamp = timestampHigh << 7 | byte & 0x7F;
      i++;
      if (i >= packet.length) {
        if (_inSysEx && byte == 0xF7) {
          // Almost certainly a SysEx terminator sent without the timestamp
          // byte the specification requires before it, which leaves this
          // parser reading it as the timestamp and the message unterminated.
          // 0xF7 is also a legal timestamp value, so this cannot be told apart
          // with certainty and nothing is parsed differently — but a
          // peripheral that frames this way loses every SysEx it sends, and
          // that is worth saying out loud rather than leaving as silence.
          onFramingWarning?.call(
            'a SysEx ended with 0xF7 and no timestamp byte before it, so the '
            'message was dropped; the MMA BLE MIDI specification requires a '
            'timestamp byte ahead of the terminator',
          );
        }
        break;
      }
      flush();
      currentTimestamp = _lastTimestamp;
      final first = packet[i];
      current.add(first);
      _trackSysEx(first);
      i++;
    }

    flush();
    return runs;
  }

  /// Forgets any SysEx in progress. Called when the link drops, so a partial
  /// message cannot bleed into the next connection.
  void reset() {
    _inSysEx = false;
    _lastTimestamp = 0;
  }

  /// Mirrors [MidiMessageSplitter]'s rules 1, 4 and 5 for the one bit of state
  /// the two stages share.
  void _trackSysEx(int byte) {
    if (byte >= 0xF8 || (byte & 0x80) == 0) {
      // System Real-Time and data bytes leave a SysEx open.
      return;
    }
    // 0xF0 opens one; 0xF7 closes it, and any other status byte aborts it.
    _inSysEx = byte == 0xF0;
  }
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

  /// When this peripheral last turned up in a scan result, or null if it has
  /// never been seen — a device registered through
  /// [UniversalBleMidiTransport.registerKnownDevice] rather than discovered.
  /// Read by the aging sweep, which leaves a never-seen device alone.
  DateTime? lastSeen;

  _DeviceState _devState = _DeviceState.none;
  BleService? _midiService;
  BleCharacteristic? _midiCharacteristic;
  bool _bleLinkConnected = false;
  bool _readinessInProgress = false;

  /// Whether this device is currently held at the high-performance connection
  /// interval, and so has something to hand back on teardown.
  bool _priorityRaised = false;

  /// Whether a bond has already been asked for during the current [connect].
  ///
  /// Reset once per [connect] rather than per attempt — deliberately not in
  /// [disconnect], which runs between those attempts — so the whole-sequence
  /// retry cannot put a second pairing dialog in front of the user for a
  /// question they have already answered.
  bool _bondAttempted = false;

  /// Whether a bonding attempt has been observed to end without a bond during
  /// the current [connect] — in practice, the user declining.
  ///
  /// This is the only way to know that the *stack* asked and was refused.
  /// Android bonds of its own accord when a subscription needs an encrypted
  /// link, so the dialog the user declines is often one this transport never
  /// requested and [_bondAttempted] therefore knows nothing about. Without
  /// this, a decline is followed by an explicit [UniversalBle.pair] — or by a
  /// reconnect that provokes the stack again — and the user is asked a second
  /// time immediately after saying no.
  ///
  /// Reset once per [connect], like [_bondAttempted].
  bool _bondDeclined = false;

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
      _framer.reset();
      _splitter.reset();
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

  /// Finishes an out-of-band bond by bringing the MIDI path up behind it.
  ///
  /// A bond reported before service discovery has run leaves [_startNotify]
  /// nothing to subscribe to; it throws, and the `catchError` below leaves the
  /// device alone rather than marking it connected with no subscription.
  void updatePairingState(bool value) {
    if (!value && _readinessInProgress) {
      // A bond attempt that ended without a bond, while we were bringing the
      // device up: the user declined, or the stack gave up. Either way the
      // question has been put to them once and must not be put again.
      _bondDeclined = true;
      return;
    }
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

  /// Brings the device to MIDI readiness, retrying the whole sequence through a
  /// transient Android `GATT_ERROR` on a growing delay ([_gattRetryDelays]).
  ///
  /// Two different failures arrive this way. The link can come up and then drop
  /// part-way through the handshake — most often when reconnecting shortly
  /// after a disconnect, before the Android stack has settled — which surfaces
  /// as a failed service discovery or subscription rather than a failed
  /// connect, and needs the half-built connection torn down and a fresh GATT
  /// client. And `connect` itself can be refused outright by a peripheral that
  /// has only just powered on, for as long as its radio takes to become
  /// ready, which is why the delays grow instead of being tried once and given
  /// up on.
  Future<void> connect({Duration? timeout}) async {
    if (connected) {
      return;
    }
    _readinessInProgress = true;
    _bondAttempted = false;
    _bondDeclined = false;
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
          if (_bondDeclined) {
            // A declined bond commonly takes the link down with it, which is
            // indistinguishable from a transient fault. Retrying would
            // reconnect, re-subscribe, and provoke the stack into asking
            // again — so stop, and report the refusal rather than the drop.
            // Already the right type if the subscription stage got there
            // first; do not wrap it in a second copy of itself.
            if (error is MidiPairingRejectedException) {
              rethrow;
            }
            throw MidiPairingRejectedException(
              deviceId: deviceId,
              cause: error,
            );
          }
          if (attempt >= _gattRetryDelays.length ||
              !_isTransientLinkFailure(cause)) {
            rethrow;
          }
          if (await _subscriptionMayHavePrompted(error, cause)) {
            // Same situation as above, reached without the pairing callback
            // having told us so. Reported as a refusal rather than as the
            // subscription error it arrived as, because the alternative is
            // that one user action produces two different messages depending
            // on whether the callback had already been spent — and of the
            // two, "pairing was rejected or did not complete" is the one that
            // tells someone who just dismissed a pairing dialog what
            // happened.
            _log(
              '$deviceId: the subscription took the link down and the device '
              'is still unbonded; not retrying, because retrying would ask '
              'again',
            );
            throw MidiPairingRejectedException(
              deviceId: deviceId,
              cause: error,
            );
          }
          _log('$deviceId: link dropped during setup ($error); retrying once');
        }
        await Future<void>.delayed(_gattRetryDelays[attempt]);
      }
    } finally {
      _readinessInProgress = false;
    }
  }

  /// Whether [error] is a subscription that took the link down on a device
  /// that is still unbonded — the shape a declined pairing dialog arrives in,
  /// and therefore one that must not be retried.
  ///
  /// This exists because the direct signal cannot be relied on. universal_ble
  /// publishes a failed bond through `onPairingStateChange`, but
  /// `updatePairingState` de-duplicates against a process-wide map that is
  /// never cleared — so the first decline is delivered and every later one in
  /// the same run is swallowed. [_bondDeclined] therefore catches the first
  /// decline only, and this catches the rest.
  ///
  /// The discrimination is `deviceDisconnected` against a GATT status. On
  /// Android the stack raises its own bonding prompt from the CCCD write, and
  /// declining it tears the connection down, which universal_ble reports by
  /// failing the in-flight subscription with `deviceDisconnected`. A
  /// subscription that instead fails with a GATT status — the generic 133 of
  /// a link that died mid-handshake — is a genuine transient fault and keeps
  /// its retry.
  ///
  /// The bond state is what separates a declined prompt from a peripheral
  /// that never prompts at all: a bond already in place means the drop cannot
  /// have been a prompt, so the retry is safe and is what recovers the common
  /// case of Android dropping the link behind a successful `createBond`.
  ///
  /// The cost is narrow and deliberate: a peripheral that needs no bond, and
  /// whose link genuinely dies during the subscription, loses its one
  /// automatic retry and is reported as a refused bond rather than as the drop
  /// it was. Both are the wrong answer for that peripheral, and both are worth
  /// it against an unbounded dialog loop for every peripheral that does need a
  /// bond.
  Future<bool> _subscriptionMayHavePrompted(Object error, Object cause) async {
    if (cause is! UniversalBleException ||
        cause.code != UniversalBleErrorCode.deviceDisconnected) {
      return false;
    }
    if (error is! MidiConnectionException ||
        error.stage != MidiConnectionStage.notificationSubscription) {
      return false;
    }
    try {
      final isPaired = await UniversalBle.isPaired(deviceId);
      return !(isPaired ?? false);
    } catch (_) {
      // Cannot tell, so assume the cautious answer.
      return true;
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
    _framer.reset();
    _splitter.reset();
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
    await _openMidiPath(timeout: timeout);
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
        .where((s) => _isMidiServiceUuid(s.uuid))
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

  /// Brings up the MIDI notification path, bonding only if the peripheral
  /// refuses to serve it without a bond.
  ///
  /// BLE MIDI does not require a bond. The MMA specification puts no security
  /// requirement on the MIDI service, and plenty of peripherals expose it
  /// openly. Some go further and accept Android's bonding request without
  /// ever completing the bond, while carrying MIDI and SysEx perfectly over
  /// the unbonded link. Bonding up front therefore cost a system dialog
  /// nobody needed and then failed the whole connection for a
  /// link that worked, which is what drove one application to fork this
  /// package and skip pairing for a hardcoded device name.
  ///
  /// So the subscription is the test and an explicit bond is the fallback:
  /// subscribe, and escalate only when the peripheral turns the subscription
  /// down for want of one ([_refusedForWantOfBond]).
  ///
  /// On Android the escalation is genuinely a fallback, because the stack
  /// usually bonds without being asked. Observed against a peripheral that
  /// requires encryption: the CCCD write is held while the system puts up its
  /// own pairing dialog — around ten seconds of it, with the app losing and
  /// regaining focus — a bond appears with nobody having called
  /// [UniversalBle.pair], and the write then completes. The subscription
  /// simply succeeds, slowly, and nothing here runs at all. That is
  /// [BleCapabilities.triggersConfirmOnlyPairing] in action, and it turns out
  /// to cover the CCCD write and not just a read or write of the
  /// characteristic itself.
  ///
  /// The escalation exists for when that does not happen: the peripheral
  /// answers the CCCD write with `GATT_INSUFFICIENT_AUTHENTICATION` instead,
  /// which leaves the link up, so the bond and the second attempt run on the
  /// same connection.
  ///
  /// Two consequences of the stack's own dialog landing inside the
  /// subscription. It is spent against the caller's readiness budget under
  /// [MidiConnectionStage.notificationSubscription] rather than
  /// [MidiConnectionStage.pairing], so a budget that does not allow for human
  /// response time fails there. And the bond completes mid-readiness, so
  /// `onPairingStateChange` fires while [connect] is in flight —
  /// [updatePairingState]'s `_readinessInProgress` guard is what keeps that
  /// from starting a second, concurrent subscription.
  ///
  /// The invariant this establishes: a connected device is one whose
  /// notifications are flowing, not one the OS has bonded.
  Future<void> _openMidiPath({Duration? timeout}) async {
    try {
      await _startNotify(timeout: timeout);
      return;
    } catch (refusal) {
      final cause = _rootCause(refusal);
      if (_bondDeclined) {
        // The stack already asked during the subscription and was refused.
        // Asking again explicitly is the same question, and the answer is the
        // reason the subscription failed, so report that rather than the
        // subscription error it arrived as.
        throw MidiPairingRejectedException(deviceId: deviceId, cause: cause);
      }
      // Order matters. A link that went away is [connect]'s business, and
      // asking for a bond would put a dialog in front of the user for a
      // peripheral that is no longer there.
      if (_bondAttempted ||
          _isTransientLinkFailure(cause) ||
          !_refusedForWantOfBond(cause)) {
        rethrow;
      }
      _log(
        '$deviceId: subscription refused (${cause is UniversalBleException ? cause.code.name : cause}); obtaining a bond and retrying it once',
      );
      if (!await _establishBond(timeout: timeout)) {
        // A bond already exists and the peripheral refused anyway, so a bond
        // is not what it wanted. Report the refusal we actually got rather
        // than inventing a pairing failure.
        rethrow;
      }
    }
    // Second and last attempt. If the peripheral still refuses, that is
    // reported as the subscription failure it is. If the link dropped while
    // bonding — which the Android stack does behind a successful
    // `createBond` — the error reaches [connect], whose whole-sequence retry
    // reconnects and subscribes again; by then the bond exists, so the user is
    // not asked twice.
    await _startNotify(timeout: timeout);
  }

  /// Gets a bond in place after the peripheral refused to subscribe without
  /// one. Returns whether a new bond was established; `false` means one
  /// already existed and nothing was done.
  ///
  /// Attempted at most once per [connect] ([_bondAttempted]): every path out of
  /// here either produces a bond or fails terminally, so a second attempt
  /// could only ask the user a question they have already answered.
  ///
  /// How a bond is requested depends on the platform, and the two ways are not
  /// interchangeable. Android, Windows and Linux have a system pairing API, so
  /// ask for a bond and then verify it took — [UniversalBle.pair] resolving
  /// does not prove a bond exists, and a bond reported established can be lost
  /// again moments later, which is how such a peripheral fails. Apple and
  /// web have no such API, and there the lever is the access itself: reading
  /// the MIDI characteristic makes the OS start "Just Works" pairing and
  /// completes once the user accepts
  /// ([BleCapabilities.triggersConfirmOnlyPairing], which universal_ble
  /// documents for a read or write of an encrypted characteristic — a CCCD
  /// write is neither, so the subscription cannot be relied on to trigger it).
  /// That read is the same provocation this transport used to perform up
  /// front; it is unchanged, only deferred to the point where the peripheral
  /// has actually asked for it.
  Future<bool> _establishBond({Duration? timeout}) async {
    _bondAttempted = true;
    try {
      if (!BleCapabilities.hasSystemPairingApi) {
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
        return true;
      }

      final alreadyBonded = await _runStage(
        MidiConnectionStage.pairing,
        () => UniversalBle.isPaired(deviceId, timeout: timeout),
        timeout,
      );
      if (alreadyBonded == true) {
        // Asking to pair an already-bonded device succeeds without changing
        // anything, so there is nothing to escalate to.
        _log('$deviceId: already bonded and still refused; not re-pairing');
        return false;
      }

      await _runStage(
        MidiConnectionStage.pairing,
        () => UniversalBle.pair(deviceId, timeout: timeout),
        timeout,
      );
      final bonded = await _runStage(
        MidiConnectionStage.pairing,
        () => UniversalBle.isPaired(deviceId, timeout: timeout),
        timeout,
      );
      if (bonded != true) {
        // Deliberately without a cause: [connect] classifies by root cause,
        // and a refused bond must not be able to look like a transient link
        // fault, or the sequence would be retried and the user asked again.
        throw MidiPairingRejectedException(deviceId: deviceId);
      }
      return true;
    } on MidiConnectionException {
      rethrow;
    } on PairingException catch (e) {
      throw MidiPairingRejectedException(deviceId: deviceId, cause: e);
    } catch (e) {
      throw MidiPairingFailedException(deviceId: deviceId, cause: e);
    }
  }

  Future<void> _startNotify({Duration? timeout}) async {
    final service = _midiService;
    final characteristic = _midiCharacteristic;
    if (service == null || characteristic == null) {
      // Unreachable from the readiness sequence, where [_discoverServices] has
      // already thrown if either is missing. Reachable from
      // [updatePairingState], which fires on a bond established outside this
      // transport and used to return silently here — and then mark the device
      // available and connected with no subscription behind it.
      throw MidiNotificationSubscriptionException(deviceId: deviceId);
    }
    try {
      await _runStage(
        MidiConnectionStage.notificationSubscription,
        () => UniversalBle.subscribeNotifications(
          deviceId,
          service.uuid,
          characteristic.uuid,
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

  /// The two receive stages: [BleMidiFramer] removes the BLE framing, and
  /// [MidiMessageSplitter] turns the resulting bytes into complete MIDI
  /// messages. Both are per-device and both are reset when the link drops.
  late final BleMidiFramer _framer = BleMidiFramer(
    onFramingWarning: (message) => _log('$deviceId: $message'),
  );
  late final MidiMessageSplitter _splitter = MidiMessageSplitter(
    onMessage: _emit,
  );

  void handleData(Uint8List data) {
    for (final run in _framer.parse(data)) {
      _splitter.parse(run.bytes, run.timestamp);
    }
  }

  void _emit(Uint8List message, int timestamp) {
    _rxStreamCtrl.add(MidiPacket(message, timestamp, this));
  }
}
