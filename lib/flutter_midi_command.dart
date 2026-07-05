import 'dart:async';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:flutter_midi_command/flutter_midi_command_messages.dart';
import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';
import 'package:flutter_midi_command/src/midi_transports.dart';

export 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart'
    show
        MidiBleTransport,
        MidiDevice,
        MidiDeviceTypeWire,
        MidiPacket,
        MidiPort,
        MidiSetupChange;
export 'package:flutter_midi_command_platform_interface/midi_device.dart'
    show MidiConnectionState, MidiDeviceType;
export 'src/midi_transports.dart';

enum BluetoothState {
  poweredOn,
  poweredOff,
  resetting,
  unauthorized,
  unknown,
  unsupported,
  other,
}

enum _MidiDeviceRoute { platform, bleTransport }

class MidiDataReceivedEvent {
  const MidiDataReceivedEvent({
    required this.message,
    required this.device,
    required this.transport,
    required this.timestamp,
  });

  final MidiMessage message;
  final MidiDevice device;
  final MidiTransport transport;
  final int timestamp;
}

class MidiCommand {
  static const Set<MidiTransport> supportedTransports = {
    MidiTransport.native,
    MidiTransport.ble,
    MidiTransport.network,
    MidiTransport.virtual,
  };

  factory MidiCommand({MidiBleTransport? bleTransport}) {
    if (_instance == null) {
      _instance = MidiCommand._(bleTransport: bleTransport);
    } else if (bleTransport != null) {
      _instance!.configureBleTransport(bleTransport);
    }
    return _instance!;
  }

  MidiCommand._({MidiBleTransport? bleTransport})
    : _bleTransport = bleTransport;

  MidiTransportPolicy _transportPolicy = const MidiTransportPolicy();
  MidiBleTransport? _bleTransport;

  /// Optional sink for internal diagnostic messages (device discovery, BLE/
  /// CoreMIDI merge, connection handoff, disconnect). Defaults to null (silent).
  /// Pipe it into your own logger, e.g.
  /// `MidiCommand().logHandler = (m) => talker.debug(m);`
  void Function(String message)? logHandler;

  void _log(String message) =>
      logHandler?.call('[flutter_midi_command] $message');
  final Expando<_MidiDeviceRoute> _deviceRouteByInstance =
      Expando<_MidiDeviceRoute>('midi_device_route');
  final Map<String, _MidiDeviceRoute> _deviceRouteById =
      <String, _MidiDeviceRoute>{};
  final Map<String, MidiMessageParser> _messageParsersBySource =
      <String, MidiMessageParser>{};
  Expando<MidiMessageParser> _messageParsersByAnonymousDevice =
      Expando<MidiMessageParser>('midi_message_parser');

  Set<MidiTransport> get enabledTransports =>
      _transportPolicy.resolveEnabledTransports(supportedTransports);

  MidiCapabilities get capabilities => MidiCapabilities(
    supportedTransports: supportedTransports,
    enabledTransports: enabledTransports,
  );

  void configureTransportPolicy(MidiTransportPolicy policy) {
    _transportPolicy = policy;
  }

  /// Attaches or detaches the BLE implementation.
  ///
  /// Pass `null` to disable BLE integration entirely for this instance.
  void configureBleTransport(MidiBleTransport? transport) {
    if (identical(_bleTransport, transport)) {
      return;
    }
    _onBluetoothStateChangedStreamSubscription?.cancel();
    _onBluetoothStateChangedStreamSubscription = null;
    _bleTransport?.teardown();
    _bleTransport = transport;
    _bluetoothIsStarted = false;
    _bluetoothState = BluetoothState.unknown;
    _deviceRouteById.clear();
    _resetMessageParsers();
  }

  bool isTransportEnabled(MidiTransport transport) =>
      enabledTransports.contains(transport);

  void _requireTransport(MidiTransport transport, String operation) {
    if (!isTransportEnabled(transport)) {
      throw StateError(
        '$operation requires transport $transport, but it is disabled by policy.',
      );
    }
  }

  void _requireBleTransport(String operation) {
    if (_bleTransport == null) {
      throw StateError(
        '$operation requires a BLE transport implementation. '
        'Add flutter_midi_command_ble and pass UniversalBleMidiTransport() to MidiCommand().',
      );
    }
  }

  void dispose() {
    __platform?.teardown();
    _txStreamCtrl.close();
    _bluetoothStateStream.close();
    _onBluetoothStateChangedStreamSubscription?.cancel();
    _bleTransport?.teardown();
    _bleTransport = null;
    _bluetoothIsStarted = false;
    _bluetoothStartFuture = null;
    _bluetoothState = BluetoothState.unknown;
    _deviceRouteById.clear();
    _resetMessageParsers();
    if (identical(_instance, this)) {
      _instance = null;
    }
  }

  static MidiCommand? _instance;

  static MidiCommandPlatform? __platform;

  static void setPlatformOverride(MidiCommandPlatform platform) {
    __platform = platform;
  }

  static void resetForTest() {
    _instance = null;
    __platform = null;
  }

  final StreamController<Uint8List> _txStreamCtrl =
      StreamController<Uint8List>.broadcast();

  final _bluetoothStateStream = StreamController<BluetoothState>.broadcast();

  var _bluetoothIsStarted = false;
  Future<void>? _bluetoothStartFuture;

  BluetoothState _bluetoothState = BluetoothState.unknown;
  StreamSubscription? _onBluetoothStateChangedStreamSubscription;
  _listenToBluetoothState() async {
    _onBluetoothStateChangedStreamSubscription = _bleTransport
        ?.onBluetoothStateChanged
        .listen((s) {
          _bluetoothState = BluetoothState.values.byName(s);
          _bluetoothStateStream.add(_bluetoothState);
        });

    scheduleMicrotask(() async {
      if (_bluetoothState == BluetoothState.unknown) {
        _bluetoothState = BluetoothState.values.byName(
          await _bleTransport!.bluetoothState(),
        );
        _bluetoothStateStream.add(_bluetoothState);
      }
    });
  }

  /// Get the platform specific implementation
  static MidiCommandPlatform get _platform {
    if (__platform != null) return __platform!;

    __platform = MidiCommandPlatform.instance;

    return __platform!;
  }

  /// Gets a list of available MIDI devices and returns it
  Future<List<MidiDevice>?> get devices async {
    final devices = <MidiDevice>[];
    _deviceRouteById.clear();

    final platformDevices = await _platform.devices ?? <MidiDevice>[];

    final bleActive =
        _bleTransport != null && isTransportEnabled(MidiTransport.ble);
    final bleDevices =
        bleActive ? await _bleTransport!.devices : <MidiDevice>[];
    // BLE-transport devices (advertised name) indexed by id.
    final bleById = <String, MidiDevice>{
      for (final device in bleDevices) device.id: device,
    };
    final platformIds = <String>{};

    for (final device in platformDevices) {
      platformIds.add(device.id);
      // On Apple a bonded BLE peripheral is exposed by the platform (CoreMIDI)
      // under the same id (its CoreBluetooth UUID), and that is the path that
      // carries data once bonded. Show the platform entry (its connection state
      // is authoritative) but prefer the advertised name when we have it.
      if (device.type == MidiDeviceType.ble && bleActive) {
        final advertisedName = bleById[device.id]?.name;
        if (advertisedName != null && advertisedName.isNotEmpty) {
          device.name = advertisedName;
        }
        // Remember the bonded device in the BLE transport so it stays listed
        // and reconnectable by UUID after CoreMIDI drops it on disconnect.
        _bleTransport!.registerKnownDevice(device.id, device.name);
      }
      _rememberDeviceRoute(device, _MidiDeviceRoute.platform);
      devices.add(device);
    }

    // BLE devices not currently exposed by the platform: either not yet bonded
    // (discovery/pairing) or a previously-bonded device that CoreMIDI dropped.
    // Keep them on the BLE transport so the user can (re)connect by UUID.
    for (final device in bleDevices) {
      if (platformIds.contains(device.id)) {
        continue;
      }
      _rememberDeviceRoute(device, _MidiDeviceRoute.bleTransport);
      devices.add(device);
    }

    if (logHandler != null) {
      _log(
        'devices: platform=${platformDevices.map((d) => '${d.name}(${d.id},${d.type.name})').toList()} '
        'ble=${bleDevices.map((d) => '${d.name}(${d.id})').toList()} '
        '=> ${devices.length} merged',
      );
    }

    return devices;
  }

  /// Stream firing events whenever the bluetooth state changes
  Stream<BluetoothState> get onBluetoothStateChanged =>
      _bluetoothStateStream.stream.distinct();

  /// Returns the current Bluetooth state
  BluetoothState get bluetoothState => _bluetoothState;

  /// Starts the Bluetooth subsystem used for BLE MIDI discovery/connection.
  Future<void> startBluetooth() async {
    _requireTransport(MidiTransport.ble, 'startBluetooth');
    _requireBleTransport('startBluetooth');

    if (_bluetoothIsStarted) {
      return;
    }
    if (_bluetoothStartFuture != null) {
      return _bluetoothStartFuture!;
    }

    _bluetoothStartFuture = () async {
      try {
        await _bleTransport!.startBluetooth();
        await _listenToBluetoothState();
        _bluetoothIsStarted = true;
      } catch (_) {
        _bluetoothIsStarted = false;
        rethrow;
      } finally {
        _bluetoothStartFuture = null;
      }
    }();

    return _bluetoothStartFuture!;
  }

  /// Wait for the blueetooth state to be initialized
  ///
  /// Found devices will be included in the list returned by [devices]
  Future<void> waitUntilBluetoothIsInitialized() async {
    _requireTransport(MidiTransport.ble, 'waitUntilBluetoothIsInitialized');
    bool isInitialized() => _bluetoothState != BluetoothState.unknown;

    if (isInitialized()) {
      return;
    }

    await for (final _ in onBluetoothStateChanged) {
      if (isInitialized()) {
        break;
      }
    }
    return;
  }

  /// Starts scanning for BLE MIDI devices
  ///
  /// Found devices will be included in the list returned by [devices]
  Future<void> startScanningForBluetoothDevices() async {
    _requireTransport(MidiTransport.ble, 'startScanningForBluetoothDevices');
    _requireBleTransport('startScanningForBluetoothDevices');
    return _bleTransport!.startScanningForBluetoothDevices();
  }

  /// Stop scanning for BLE MIDI devices
  void stopScanningForBluetoothDevices() {
    _requireTransport(MidiTransport.ble, 'stopScanningForBluetoothDevices');
    _requireBleTransport('stopScanningForBluetoothDevices');
    _bleTransport!.stopScanningForBluetoothDevices();
  }

  /// Connects to the device
  Future<void> connectToDevice(
    MidiDevice device, {
    Duration? awaitConnectionTimeout = const Duration(seconds: 10),
  }) async {
    if (!device.connected) {
      device.setConnectionState(MidiConnectionState.connecting);
    }
    final connectionEstablished = _awaitConnectedOrFailed(device);

    try {
      final route = _resolveDeviceRoute(device);
      if (route == _MidiDeviceRoute.bleTransport) {
        _requireTransport(MidiTransport.ble, 'connectToDevice');
        _requireBleTransport('connectToDevice');
        await _bleTransport!.connectToDevice(device);
        // On Apple platforms a bonded BLE peripheral becomes available through
        // CoreMIDI under the same id (its CoreBluetooth UUID), and that is the
        // path that actually carries MIDI data. Hand the data path over to it
        // once it appears. This is a no-op on platforms where the BLE transport
        // is itself the data path (e.g. Android), where no platform counterpart
        // ever shows up.
        unawaited(_handoffBleToPlatform(device));
      } else {
        await _platform.connectToDevice(device);
      }
    } catch (_) {
      if (device.connectionState == MidiConnectionState.connecting) {
        device.setConnectionState(MidiConnectionState.disconnected);
      }
      rethrow;
    }

    if (device.connected) {
      return;
    }

    if (awaitConnectionTimeout == null) {
      await connectionEstablished;
      return;
    }
    try {
      await connectionEstablished.timeout(awaitConnectionTimeout);
    } on TimeoutException {
      if (device.connectionState == MidiConnectionState.connecting) {
        device.setConnectionState(MidiConnectionState.disconnected);
      }
      rethrow;
    }
  }

  /// Disconnects from the device
  void disconnectDevice(MidiDevice device) {
    if (device.connected) {
      device.setConnectionState(MidiConnectionState.disconnecting);
    }
    final route = _resolveDeviceRoute(device);
    final isBleWithTransport =
        device.type == MidiDeviceType.ble &&
        _bleTransport != null &&
        isTransportEnabled(MidiTransport.ble);
    _log(
      'Disconnect "${device.name}" (${device.id}) route=${route.name} '
      'ble=$isBleWithTransport',
    );

    if (route == _MidiDeviceRoute.platform) {
      _platform.disconnectDevice(device);
      // A bonded BLE device also holds the underlying universal_ble connection
      // that was used to pair/bond; release it too.
      if (isBleWithTransport) {
        _bleTransport!.disconnectDevice(device);
      }
      return;
    }

    // BLE transport route (e.g. not yet bonded, or non-Apple data path).
    if (isBleWithTransport) {
      _bleTransport!.disconnectDevice(device);
      return;
    }
    _platform.disconnectDevice(device);
  }

  /// Disconnects from all devices
  void teardown() {
    _platform.teardown();
    _bleTransport?.teardown();
    _deviceRouteById.clear();
    _resetMessageParsers();
  }

  /// Sends data to the currently connected device
  ///
  /// Data is an UInt8List of individual MIDI command bytes
  void sendData(Uint8List data, {String? deviceId, int? timestamp}) {
    if (deviceId != null) {
      final route = _deviceRouteById[deviceId];
      if (route == _MidiDeviceRoute.platform) {
        _platform.sendData(data, deviceId: deviceId, timestamp: timestamp);
        _txStreamCtrl.add(data);
        return;
      }
      if (route == _MidiDeviceRoute.bleTransport &&
          _bleTransport != null &&
          isTransportEnabled(MidiTransport.ble)) {
        _bleTransport!.sendData(data, deviceId: deviceId, timestamp: timestamp);
        _txStreamCtrl.add(data);
        return;
      }
    }

    _platform.sendData(data, deviceId: deviceId, timestamp: timestamp);
    if (_bleTransport != null && isTransportEnabled(MidiTransport.ble)) {
      _bleTransport!.sendData(data, deviceId: deviceId, timestamp: timestamp);
    }
    _txStreamCtrl.add(data);
  }

  /// Stream firing events whenever a typed MIDI message is received.
  ///
  /// Each event contains the parsed [MidiMessage], source [MidiDevice],
  /// [MidiTransport], and packet timestamp.
  Stream<MidiDataReceivedEvent>? get onMidiDataReceived {
    final streams = <Stream<MidiDataReceivedEvent>>[];
    if (_platform.onMidiDataReceived != null) {
      streams.add(
        _mapPacketsToTypedEvents(
          _platform.onMidiDataReceived!,
          fallbackTransport: MidiTransport.native,
        ),
      );
    }
    if (_bleTransport != null && isTransportEnabled(MidiTransport.ble)) {
      streams.add(
        _mapPacketsToTypedEvents(
          _bleTransportPackets(),
          fallbackTransport: MidiTransport.ble,
        ),
      );
    }
    if (streams.isEmpty) {
      return null;
    }
    if (streams.length == 1) {
      return streams.first;
    }
    return StreamGroup.merge(streams).asBroadcastStream();
  }

  /// Stream firing events whenever a raw MIDI packet is received.
  ///
  /// Prefer [onMidiDataReceived] for parsed message events.
  Stream<MidiPacket>? get onMidiPacketReceived {
    final streams = <Stream<MidiPacket>>[];
    if (_platform.onMidiDataReceived != null) {
      streams.add(_platform.onMidiDataReceived!);
    }
    if (_bleTransport != null && isTransportEnabled(MidiTransport.ble)) {
      streams.add(_bleTransportPackets());
    }
    if (streams.isEmpty) {
      return null;
    }
    if (streams.length == 1) {
      return streams.first;
    }
    return StreamGroup.merge(streams).asBroadcastStream();
  }

  /// Stream firing events whenever a change in the MIDI setup occurs.
  Stream<MidiSetupChange>? get onMidiSetupChanged {
    final streams = <Stream<MidiSetupChange>>[];
    if (_platform.onMidiSetupChanged != null) {
      streams.add(_platform.onMidiSetupChanged!);
    }
    if (_bleTransport != null && isTransportEnabled(MidiTransport.ble)) {
      streams.add(_bleTransport!.onMidiSetupChanged);
    }
    if (streams.isEmpty) {
      return null;
    }
    if (streams.length == 1) {
      return streams.first;
    }
    return StreamGroup.merge(streams).asBroadcastStream();
  }

  /// Stream firing events whenever a midi package is sent
  ///
  /// The event contains the raw bytes contained in the MIDI package
  Stream<Uint8List> get onMidiDataSent {
    return _txStreamCtrl.stream;
  }

  /// Creates a virtual MIDI source
  ///
  /// The virtual MIDI source appears as a virtual port in other apps.
  /// Other apps can receive MIDI from this source.
  /// Currently only supported on iOS.
  void addVirtualDevice({String? name}) {
    _requireTransport(MidiTransport.virtual, 'addVirtualDevice');
    _platform.addVirtualDevice(name: name);
  }

  /// Removes a previously created virtual MIDI source.
  /// Currently only supported on iOS.
  void removeVirtualDevice({String? name}) {
    _requireTransport(MidiTransport.virtual, 'removeVirtualDevice');
    _platform.removeVirtualDevice(name: name);
  }

  /// Returns the current state of the network session
  ///
  /// This is functional on iOS only, will return null on other platforms
  Future<bool?> get isNetworkSessionEnabled {
    _requireTransport(MidiTransport.network, 'isNetworkSessionEnabled');
    return _platform.isNetworkSessionEnabled;
  }

  /// Sets the enabled state of the network session
  ///
  /// This is functional on iOS only
  void setNetworkSessionEnabled(bool enabled) {
    _requireTransport(MidiTransport.network, 'setNetworkSessionEnabled');
    _platform.setNetworkSessionEnabled(enabled);
  }

  Future<void> _awaitConnectedOrFailed(MidiDevice device) {
    if (device.connected) {
      return Future<void>.value();
    }

    final completer = Completer<void>();
    var wasConnecting =
        device.connectionState == MidiConnectionState.connecting;
    late StreamSubscription<MidiConnectionState> sub;

    void completeSuccess() {
      if (!completer.isCompleted) {
        completer.complete();
      }
    }

    void completeFailure() {
      if (!completer.isCompleted) {
        completer.completeError(
          StateError('Failed to connect to MIDI device ${device.id}.'),
        );
      }
    }

    sub = device.onConnectionStateChanged.listen((state) {
      if (state == MidiConnectionState.connecting) {
        wasConnecting = true;
        return;
      }
      if (state == MidiConnectionState.connected) {
        completeSuccess();
        return;
      }
      if (state == MidiConnectionState.disconnected && wasConnecting) {
        completeFailure();
      }
    });

    if (device.connected) {
      completeSuccess();
    } else if (device.connectionState == MidiConnectionState.disconnected &&
        wasConnecting) {
      completeFailure();
    }

    return completer.future.whenComplete(() => sub.cancel());
  }

  void _rememberDeviceRoute(MidiDevice device, _MidiDeviceRoute route) {
    _deviceRouteByInstance[device] = route;
    if (device.id.isNotEmpty) {
      _deviceRouteById.putIfAbsent(device.id, () => route);
    }
  }

  /// Like [_rememberDeviceRoute] but forces the route even if one is already
  /// recorded for this id (used when merging a bonded BLE device onto the
  /// platform/CoreMIDI data path).
  void _setDeviceRoute(MidiDevice device, _MidiDeviceRoute route) {
    _deviceRouteByInstance[device] = route;
    if (device.id.isNotEmpty) {
      _deviceRouteById[device.id] = route;
    }
  }

  /// Waits (in the background) for a freshly bonded BLE peripheral to be exposed
  /// by the platform (CoreMIDI on Apple) under the same id, then opens that
  /// endpoint and switches the device's data route to it. No-op where no
  /// platform counterpart appears (e.g. Android), leaving the BLE transport as
  /// the data path.
  Future<void> _handoffBleToPlatform(MidiDevice device) async {
    const pollInterval = Duration(milliseconds: 500);
    const maxWait = Duration(seconds: 20);
    final deadline = DateTime.now().add(maxWait);

    _log('Handoff: waiting for CoreMIDI counterpart of ${device.id}');
    while (DateTime.now().isBefore(deadline)) {
      final platformDevices = await _platform.devices ?? <MidiDevice>[];
      MidiDevice? match;
      for (final candidate in platformDevices) {
        if (candidate.id == device.id && candidate.type == MidiDeviceType.ble) {
          match = candidate;
          break;
        }
      }
      if (match != null) {
        _setDeviceRoute(device, _MidiDeviceRoute.platform);
        _setDeviceRoute(match, _MidiDeviceRoute.platform);
        // A concurrent devices() refresh may have routed this id already,
        // but routing alone does not open the platform endpoint; skip the
        // connect only when the platform reports it live.
        if (match.connected) {
          _log('Handoff: CoreMIDI endpoint already connected for ${device.id}');
          return;
        }
        try {
          await _platform.connectToDevice(match);
          _log('Handoff: connected CoreMIDI endpoint for ${device.id}');
        } catch (e) {
          // Leave routing on platform; a later devices() refresh/retry can
          // re-attempt. The BLE transport connection remains as a fallback.
          _log('Handoff: platform connect failed for ${device.id}: $e');
        }
        return;
      }
      await Future<void>.delayed(pollInterval);
    }
    _log(
      'Handoff: timed out for ${device.id}; keeping BLE transport data path',
    );
  }

  _MidiDeviceRoute _resolveDeviceRoute(MidiDevice device) {
    final byInstance = _deviceRouteByInstance[device];
    if (byInstance != null) {
      return byInstance;
    }

    final byId = _deviceRouteById[device.id];
    if (byId != null) {
      return byId;
    }

    if (device.type == MidiDeviceType.ble && _bleTransport != null) {
      return _MidiDeviceRoute.bleTransport;
    }

    return _MidiDeviceRoute.platform;
  }

  /// BLE transport packets, excluding devices handed off to the platform
  /// backend (see [_handoffBleToPlatform]), whose CoreMIDI endpoint would
  /// otherwise deliver every message a second time.
  Stream<MidiPacket> _bleTransportPackets() {
    return _bleTransport!.onMidiDataReceived.where(
      (packet) =>
          _deviceRouteById[packet.device.id] != _MidiDeviceRoute.platform,
    );
  }

  Stream<MidiDataReceivedEvent> _mapPacketsToTypedEvents(
    Stream<MidiPacket> packets, {
    required MidiTransport fallbackTransport,
  }) {
    return packets.asyncExpand((packet) {
      final transport = _transportForPacket(
        packet,
        fallbackTransport: fallbackTransport,
      );
      final parser = _parserForPacket(packet, transport);
      final parsedMessages = parser.parse(packet.data, flushPendingNrpn: false);
      if (parsedMessages.isEmpty) {
        return const Stream<MidiDataReceivedEvent>.empty();
      }
      return Stream<MidiDataReceivedEvent>.fromIterable(
        parsedMessages.map(
          (message) => MidiDataReceivedEvent(
            message: message,
            device: packet.device,
            transport: transport,
            timestamp: packet.timestamp,
          ),
        ),
      );
    });
  }

  MidiMessageParser _parserForPacket(
    MidiPacket packet,
    MidiTransport transport,
  ) {
    if (packet.device.id.isNotEmpty) {
      final key = '${transport.name}:${packet.device.id}';
      return _messageParsersBySource.putIfAbsent(key, MidiMessageParser.new);
    }

    final existing = _messageParsersByAnonymousDevice[packet.device];
    if (existing != null) {
      return existing;
    }

    final parser = MidiMessageParser();
    _messageParsersByAnonymousDevice[packet.device] = parser;
    return parser;
  }

  MidiTransport _transportForPacket(
    MidiPacket packet, {
    required MidiTransport fallbackTransport,
  }) {
    switch (packet.device.type) {
      case MidiDeviceType.ble:
        return MidiTransport.ble;
      case MidiDeviceType.network:
        return MidiTransport.network;
      case MidiDeviceType.virtual:
      case MidiDeviceType.ownVirtual:
        return MidiTransport.virtual;
      case MidiDeviceType.serial:
        return MidiTransport.native;
      case MidiDeviceType.unknown:
        return fallbackTransport;
    }
  }

  void _resetMessageParsers() {
    for (final parser in _messageParsersBySource.values) {
      parser.reset();
    }
    _messageParsersBySource.clear();
    _messageParsersByAnonymousDevice = Expando<MidiMessageParser>(
      'midi_message_parser',
    );
  }
}
