import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_midi_command/flutter_midi_command_messages.dart';
import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakePlatform extends MidiCommandPlatform {
  final _rx = StreamController<MidiPacket>.broadcast();
  final _setup = StreamController<MidiSetupChange>.broadcast();
  final sent = <Uint8List>[];
  final connected = <String>[];
  final disconnected = <String>[];
  var teardownCalls = 0;

  @override
  Future<List<MidiDevice>?> get devices async => [
    MidiDevice('serial-1', 'Serial', MidiDeviceType.serial, false),
  ];

  @override
  Future<void> connectToDevice(
    MidiDevice device, {
    List<MidiPort>? ports,
  }) async {
    connected.add(device.id);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    device.connected = true;
  }

  @override
  void disconnectDevice(MidiDevice device) {
    disconnected.add(device.id);
    device.connected = false;
  }

  @override
  void teardown() {
    teardownCalls += 1;
  }

  @override
  void sendData(Uint8List data, {int? timestamp, String? deviceId}) {
    sent.add(data);
  }

  @override
  Stream<MidiPacket>? get onMidiDataReceived => _rx.stream;

  @override
  Stream<MidiSetupChange>? get onMidiSetupChanged => _setup.stream;

  void emitPacket(MidiPacket packet) {
    _rx.add(packet);
  }

  void emitSetup(MidiSetupChange value) {
    _setup.add(value);
  }
}

class _FakeBleTransport implements MidiBleTransport {
  final _rx = StreamController<MidiPacket>.broadcast();
  final _setup = StreamController<MidiSetupChange>.broadcast();
  final _state = StreamController<String>.broadcast();

  final sent = <Uint8List>[];
  final connected = <String>[];
  final disconnected = <String>[];
  var startBluetoothCalls = 0;
  var startBluetoothFailures = 0;
  var teardownCalls = 0;
  final bleDevice = MidiDevice('ble-1', 'BLE', MidiDeviceType.ble, false);

  @override
  Future<String> bluetoothState() async => 'poweredOn';

  @override
  Future<void> startBluetooth() async {
    startBluetoothCalls += 1;
    if (startBluetoothFailures > 0) {
      startBluetoothFailures -= 1;
      throw StateError('bluetoothStartFailed');
    }
    _state.add('poweredOn');
  }

  @override
  Stream<String> get onBluetoothStateChanged => _state.stream;

  @override
  Future<void> startScanningForBluetoothDevices() async {}

  @override
  void stopScanningForBluetoothDevices() {}

  @override
  Future<List<MidiDevice>> get devices async => <MidiDevice>[bleDevice];

  @override
  MidiDevice? registerKnownDevice(String id, String name) => null;

  @override
  Future<void> connectToDevice(
    MidiDevice device, {
    List<MidiPort>? ports,
    Duration? timeout,
  }) async {
    connected.add(device.id);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    device.connected = true;
  }

  @override
  void disconnectDevice(MidiDevice device) {
    disconnected.add(device.id);
    device.connected = false;
  }

  @override
  void sendData(Uint8List data, {int? timestamp, String? deviceId}) {
    sent.add(data);
  }

  @override
  Stream<MidiPacket> get onMidiDataReceived => _rx.stream;

  @override
  Stream<MidiSetupChange> get onMidiSetupChanged => _setup.stream;

  @override
  void teardown() {
    teardownCalls += 1;
  }

  void emitPacket(MidiPacket packet) {
    _rx.add(packet);
  }

  void emitSetup(MidiSetupChange value) {
    _setup.add(value);
  }
}

class _NeverConnectPlatform extends _FakePlatform {
  @override
  Future<void> connectToDevice(
    MidiDevice device, {
    List<MidiPort>? ports,
  }) async {
    connected.add(device.id);
  }
}

class _FailedConnectPlatform extends _FakePlatform {
  @override
  Future<void> connectToDevice(
    MidiDevice device, {
    List<MidiPort>? ports,
  }) async {
    connected.add(device.id);
    Future<void>.delayed(const Duration(milliseconds: 10), () {
      device.connected = false;
    });
  }
}

class _FakePlatformWithBleHost extends _FakePlatform {
  @override
  Future<List<MidiDevice>?> get devices async => [
    MidiDevice('host-ble-1', 'Host BLE', MidiDeviceType.ble, false),
  ];
}

class _ToggleBleHostPlatform extends _FakePlatform {
  bool showBleHost = false;
  bool failConnect = false;
  Completer<void>? connectGate;
  final connectStarted = Completer<void>();
  final coreMidiDevice = MidiDevice(
    'ble-1',
    'Host BLE',
    MidiDeviceType.ble,
    false,
  );

  @override
  Future<List<MidiDevice>?> get devices async =>
      showBleHost ? <MidiDevice>[coreMidiDevice] : <MidiDevice>[];

  @override
  Future<void> connectToDevice(
    MidiDevice device, {
    List<MidiPort>? ports,
  }) async {
    connected.add(device.id);
    if (!connectStarted.isCompleted) {
      connectStarted.complete();
    }
    if (failConnect) {
      throw StateError('coreMidiConnectFailed');
    }
    await connectGate?.future;
    device.connected = true;
  }
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final stopwatch = Stopwatch()..start();
  while (!condition()) {
    if (stopwatch.elapsed >= timeout) {
      throw TimeoutException('Condition was not met within $timeout.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    MidiCommand.resetForTest();
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('BLE APIs require BLE transport implementation', () async {
    final platform = _FakePlatform();
    MidiCommand.setPlatformOverride(platform);
    final midi = MidiCommand();

    expect(() => midi.startBluetooth(), throwsA(isA<StateError>()));
  });

  test('BLE policy exclusion blocks BLE operations', () async {
    final platform = _FakePlatform();
    final ble = _FakeBleTransport();
    MidiCommand.setPlatformOverride(platform);

    final midi = MidiCommand(bleTransport: ble)..configureTransportPolicy(
      const MidiTransportPolicy(excludedTransports: {MidiTransport.ble}),
    );

    expect(
      () => midi.startScanningForBluetoothDevices(),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'device list combines platform and BLE devices when BLE is enabled',
    () async {
      final platform = _FakePlatform();
      final ble = _FakeBleTransport();
      MidiCommand.setPlatformOverride(platform);

      final midi = MidiCommand(bleTransport: ble);
      final devices = await midi.devices;

      expect(devices, isNotNull);
      expect(devices!.length, 2);
      expect(devices.any((d) => d.type == MidiDeviceType.serial), isTrue);
      expect(devices.any((d) => d.type == MidiDeviceType.ble), isTrue);
    },
  );

  test('sendData fans out to both platform and BLE backends', () {
    final platform = _FakePlatform();
    final ble = _FakeBleTransport();
    MidiCommand.setPlatformOverride(platform);

    final midi = MidiCommand(bleTransport: ble);
    final data = Uint8List.fromList([0x90, 0x3C, 0x64]);
    midi.sendData(data);

    expect(platform.sent.length, 1);
    expect(ble.sent.length, 1);
  });

  test('connectToDevice waits for connection establishment', () async {
    final platform = _FakePlatform();
    MidiCommand.setPlatformOverride(platform);
    final midi = MidiCommand();

    final device = (await midi.devices)!.first;
    expect(device.connected, isFalse);

    await midi.connectToDevice(
      device,
      awaitConnectionTimeout: const Duration(seconds: 1),
    );

    expect(device.connected, isTrue);
  });

  test('connectToDevice times out when device never connects', () async {
    final platform = _NeverConnectPlatform();
    MidiCommand.setPlatformOverride(platform);
    final midi = MidiCommand();

    final device = (await midi.devices)!.first;
    expect(
      () => midi.connectToDevice(
        device,
        awaitConnectionTimeout: const Duration(milliseconds: 25),
      ),
      throwsA(isA<MidiConnectionTimeoutException>()),
    );
  });

  test(
    'onMidiDataReceived returns typed events with source metadata',
    () async {
      final platform = _FakePlatform();
      final ble = _FakeBleTransport();
      MidiCommand.setPlatformOverride(platform);
      final midi = MidiCommand(bleTransport: ble);

      final received = <MidiDataReceivedEvent>[];
      final sub = midi.onMidiDataReceived!.listen(received.add);

      platform.emitPacket(
        MidiPacket(
          Uint8List.fromList([0x90, 0x3C, 0x64]),
          123,
          MidiDevice('serial-1', 'Serial', MidiDeviceType.serial, true),
        ),
      );
      ble.emitPacket(
        MidiPacket(
          Uint8List.fromList([0x80, 0x3C, 0x00]),
          456,
          MidiDevice('ble-1', 'BLE', MidiDeviceType.ble, true),
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));
      await sub.cancel();

      expect(received.length, 2);

      final serialEvent = received.firstWhere(
        (event) => event.transport == MidiTransport.native,
      );
      expect(serialEvent.device.id, 'serial-1');
      expect(serialEvent.timestamp, 123);
      expect(serialEvent.message, isA<NoteOnMessage>());

      final bleEvent = received.firstWhere(
        (event) => event.transport == MidiTransport.ble,
      );
      expect(bleEvent.device.id, 'ble-1');
      expect(bleEvent.timestamp, 456);
      expect(bleEvent.message, isA<NoteOffMessage>());
    },
  );

  test('onMidiDataReceived emits one event per parsed MIDI message', () async {
    final platform = _FakePlatform();
    MidiCommand.setPlatformOverride(platform);
    final midi = MidiCommand();

    final received = <MidiDataReceivedEvent>[];
    final sub = midi.onMidiDataReceived!.listen(received.add);

    platform.emitPacket(
      MidiPacket(
        Uint8List.fromList([0x90, 0x3C, 0x64, 0x80, 0x3C, 0x00]),
        99,
        MidiDevice('serial-1', 'Serial', MidiDeviceType.serial, true),
      ),
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));
    await sub.cancel();

    expect(received.length, 2);
    expect(received[0].message, isA<NoteOnMessage>());
    expect(received[1].message, isA<NoteOffMessage>());
    expect(received[0].timestamp, 99);
    expect(received[1].timestamp, 99);
  });

  test('onMidiSetupChanged merges platform and BLE streams', () async {
    final platform = _FakePlatform();
    final ble = _FakeBleTransport();
    MidiCommand.setPlatformOverride(platform);
    final midi = MidiCommand(bleTransport: ble);

    final received = <MidiSetupChange>[];
    final sub = midi.onMidiSetupChanged!.listen(received.add);

    platform.emitSetup(MidiSetupChange.deviceAppeared);
    ble.emitSetup(MidiSetupChange.deviceConnected);

    await Future<void>.delayed(const Duration(milliseconds: 10));
    await sub.cancel();

    expect(
      received,
      containsAll(<MidiSetupChange>[
        MidiSetupChange.deviceAppeared,
        MidiSetupChange.deviceConnected,
      ]),
    );
  });

  test('startBluetooth is idempotent', () async {
    final platform = _FakePlatform();
    final ble = _FakeBleTransport();
    MidiCommand.setPlatformOverride(platform);
    final midi = MidiCommand(bleTransport: ble);

    await midi.startBluetooth();
    await midi.startBluetooth();

    expect(ble.startBluetoothCalls, 1);
  });

  test('concurrent startBluetooth calls share one initialization', () async {
    final platform = _FakePlatform();
    final ble = _FakeBleTransport();
    MidiCommand.setPlatformOverride(platform);
    final midi = MidiCommand(bleTransport: ble);

    await Future.wait<void>(<Future<void>>[
      midi.startBluetooth(),
      midi.startBluetooth(),
    ]);

    expect(ble.startBluetoothCalls, 1);
  });

  test(
    'waitUntilBluetoothIsInitialized returns when state is already resolved',
    () async {
      final platform = _FakePlatform();
      final ble = _FakeBleTransport();
      MidiCommand.setPlatformOverride(platform);
      final midi = MidiCommand(bleTransport: ble);

      await midi.startBluetooth();
      await midi.waitUntilBluetoothIsInitialized();

      await midi.waitUntilBluetoothIsInitialized().timeout(
        const Duration(milliseconds: 100),
      );
      expect(midi.bluetoothState, BluetoothState.poweredOn);
    },
  );

  test('second startBluetooth retains state without re-emitting it', () async {
    final platform = _FakePlatform();
    final ble = _FakeBleTransport();
    MidiCommand.setPlatformOverride(platform);
    final midi = MidiCommand(bleTransport: ble);

    await midi.startBluetooth();
    await midi.waitUntilBluetoothIsInitialized();

    final states = <BluetoothState>[];
    final sub = midi.onBluetoothStateChanged.listen(states.add);
    await midi.startBluetooth();
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(ble.startBluetoothCalls, 1);
    expect(midi.bluetoothState, BluetoothState.poweredOn);
    expect(states, isEmpty);
  });

  test('startBluetooth can be retried after failure', () async {
    final platform = _FakePlatform();
    final ble = _FakeBleTransport()..startBluetoothFailures = 1;
    MidiCommand.setPlatformOverride(platform);
    final midi = MidiCommand(bleTransport: ble);

    await expectLater(midi.startBluetooth(), throwsA(isA<StateError>()));
    await midi.startBluetooth();

    expect(ble.startBluetoothCalls, 2);
  });

  test('connectToDevice fails fast on explicit disconnection event', () async {
    final platform = _FailedConnectPlatform();
    MidiCommand.setPlatformOverride(platform);
    final midi = MidiCommand();

    final device = (await midi.devices)!.first;
    await expectLater(
      midi.connectToDevice(
        device,
        awaitConnectionTimeout: const Duration(seconds: 1),
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('dispose releases singleton and allows creating a new instance', () {
    final platform = _FakePlatform();
    MidiCommand.setPlatformOverride(platform);
    final midi1 = MidiCommand();

    midi1.dispose();

    final midi2 = MidiCommand();
    expect(identical(midi1, midi2), isFalse);
    expect(platform.teardownCalls, 1);
  });

  test('configureBleTransport(null) removes BLE devices from list', () async {
    final platform = _FakePlatform();
    final ble = _FakeBleTransport();
    MidiCommand.setPlatformOverride(platform);
    final midi = MidiCommand(bleTransport: ble);

    expect((await midi.devices)!.length, 2);

    midi.configureBleTransport(null);

    final devices = await midi.devices;
    expect(devices!.length, 1);
    expect(devices.first.type, MidiDeviceType.serial);
  });

  test('disconnect routes by device type', () async {
    final platform = _FakePlatform();
    final ble = _FakeBleTransport();
    MidiCommand.setPlatformOverride(platform);
    final midi = MidiCommand(bleTransport: ble);

    final serial = MidiDevice(
      'serial-1',
      'Serial',
      MidiDeviceType.serial,
      true,
    );
    final bleDevice = MidiDevice('ble-1', 'BLE', MidiDeviceType.ble, true);

    midi.disconnectDevice(serial);
    midi.disconnectDevice(bleDevice);

    expect(platform.disconnected, contains('serial-1'));
    expect(ble.disconnected, contains('ble-1'));
  });

  test(
    'host BLE devices keep ble type and still route via platform backend',
    () async {
      final platform = _FakePlatformWithBleHost();
      final ble = _FakeBleTransport();
      MidiCommand.setPlatformOverride(platform);
      final midi = MidiCommand(bleTransport: ble);

      final device = (await midi.devices)!.first;
      expect(device.type, MidiDeviceType.ble);

      await midi.connectToDevice(device);
      expect(platform.connected, contains('host-ble-1'));
      expect(ble.connected, isEmpty);

      midi.sendData(
        Uint8List.fromList([0x90, 0x3C, 0x64]),
        deviceId: device.id,
      );
      expect(platform.sent.length, 1);
      expect(ble.sent, isEmpty);

      midi.disconnectDevice(device);
      expect(platform.disconnected, contains('host-ble-1'));
      // A bonded BLE device also holds the underlying universal_ble link used
      // to pair/bond, so disconnect releases it too (a no-op when none is held).
      expect(ble.disconnected, contains('host-ble-1'));
    },
  );

  test('Apple BLE connect succeeds without a CoreMIDI counterpart', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final platform = _ToggleBleHostPlatform();
    final ble = _FakeBleTransport();
    MidiCommand.setPlatformOverride(platform);
    final midi = MidiCommand(bleTransport: ble);

    final device = (await midi.devices)!.single;

    await midi.connectToDevice(
      device,
      awaitConnectionTimeout: const Duration(milliseconds: 100),
    );

    expect(ble.connected, contains('ble-1'));
    expect(platform.connected, isEmpty);
    expect(device.connected, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(device.connected, isTrue);

    midi.disconnectDevice(device);
  });

  test('null readiness timeout does not make Apple handoff blocking', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final platform = _ToggleBleHostPlatform();
    final ble = _FakeBleTransport();
    MidiCommand.setPlatformOverride(platform);
    final midi = MidiCommand(bleTransport: ble);
    final device = (await midi.devices)!.single;

    await midi
        .connectToDevice(device, awaitConnectionTimeout: null)
        .timeout(const Duration(milliseconds: 250));

    expect(device.connected, isTrue);
    expect(platform.connected, isEmpty);
    midi.disconnectDevice(device);
  });

  test('Apple BLE keeps routing data until CoreMIDI is connected', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final platform = _ToggleBleHostPlatform();
    platform.connectGate = Completer<void>();
    final ble = _FakeBleTransport();
    MidiCommand.setPlatformOverride(platform);
    final midi = MidiCommand(bleTransport: ble);

    final device = (await midi.devices)!.single;
    await midi.connectToDevice(device);

    final first = Uint8List.fromList(<int>[0x90, 0x3c, 0x64]);
    midi.sendData(first, deviceId: device.id);
    expect(ble.sent, hasLength(1));
    expect(platform.sent, isEmpty);

    platform.showBleHost = true;
    await platform.connectStarted.future.timeout(const Duration(seconds: 1));

    // A list refresh must keep the currently-live BLE object authoritative
    // while CoreMIDI is visible but not connected yet.
    final refreshed = (await midi.devices)!.single;
    expect(identical(refreshed, device), isTrue);
    expect(refreshed.connected, isTrue);

    midi.sendData(first, deviceId: device.id);
    expect(ble.sent, hasLength(2));
    expect(platform.sent, isEmpty);

    platform.connectGate!.complete();
    await _waitUntil(() => platform.coreMidiDevice.connected);
    await Future<void>.delayed(Duration.zero);

    midi.sendData(first, deviceId: device.id);
    expect(ble.sent, hasLength(2));
    expect(platform.sent, hasLength(1));

    midi.disconnectDevice(device);
    expect(platform.disconnected, contains('ble-1'));
    expect(ble.disconnected, contains('ble-1'));
  });

  test('Apple BLE retains its route when CoreMIDI connect fails', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final platform = _ToggleBleHostPlatform()..failConnect = true;
    final ble = _FakeBleTransport();
    MidiCommand.setPlatformOverride(platform);
    final midi = MidiCommand(bleTransport: ble);

    final device = (await midi.devices)!.single;
    platform.showBleHost = true;

    await midi.connectToDevice(device);
    await platform.connectStarted.future.timeout(const Duration(seconds: 1));
    await Future<void>.delayed(Duration.zero);

    midi.sendData(
      Uint8List.fromList(<int>[0x90, 0x3c, 0x64]),
      deviceId: device.id,
    );
    expect(device.connected, isTrue);
    expect(ble.sent, hasLength(1));
    expect(platform.sent, isEmpty);

    midi.disconnectDevice(device);
  });

  test('disconnect cancels an in-flight Apple CoreMIDI handoff', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final platform = _ToggleBleHostPlatform();
    platform.connectGate = Completer<void>();
    final ble = _FakeBleTransport();
    MidiCommand.setPlatformOverride(platform);
    final midi = MidiCommand(bleTransport: ble);

    final device = (await midi.devices)!.single;
    platform.showBleHost = true;

    await midi.connectToDevice(device);
    await platform.connectStarted.future.timeout(const Duration(seconds: 1));
    midi.disconnectDevice(device);
    platform.connectGate!.complete();

    await _waitUntil(() => platform.disconnected.contains('ble-1'));
    expect(device.connected, isFalse);
    expect(ble.disconnected, contains('ble-1'));
  });

  test('BLE transport packets are suppressed for devices routed to the '
      'platform backend', () async {
    final platform = _FakePlatformWithBleHost();
    final ble = _FakeBleTransport();
    MidiCommand.setPlatformOverride(platform);
    final midi = MidiCommand(bleTransport: ble);

    // Connecting the host device makes the platform backend its active route.
    final hostDevice = (await midi.devices)!.firstWhere(
      (device) => device.id == 'host-ble-1',
    );
    await midi.connectToDevice(hostDevice);

    final received = <MidiDataReceivedEvent>[];
    final sub = midi.onMidiDataReceived!.listen(received.add);

    // The same peripheral seen through both paths (e.g. after the CoreMIDI
    // handoff); only the platform copy should surface.
    ble.emitPacket(
      MidiPacket(
        Uint8List.fromList([0x90, 0x3C, 0x64]),
        1,
        MidiDevice('host-ble-1', 'Host BLE', MidiDeviceType.ble, true),
      ),
    );
    platform.emitPacket(
      MidiPacket(
        Uint8List.fromList([0x90, 0x3C, 0x64]),
        2,
        MidiDevice('host-ble-1', 'Host BLE', MidiDeviceType.ble, true),
      ),
    );
    // A device still owned by the BLE transport is unaffected.
    ble.emitPacket(
      MidiPacket(
        Uint8List.fromList([0x80, 0x3C, 0x00]),
        3,
        MidiDevice('ble-1', 'BLE', MidiDeviceType.ble, true),
      ),
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));
    await sub.cancel();

    expect(received.length, 2);
    expect(received.map((event) => event.timestamp), containsAll(<int>[2, 3]));
  });

  test('sendData does not fan out to BLE when BLE transport is excluded', () {
    final platform = _FakePlatform();
    final ble = _FakeBleTransport();
    MidiCommand.setPlatformOverride(platform);
    final midi = MidiCommand(bleTransport: ble)..configureTransportPolicy(
      const MidiTransportPolicy(excludedTransports: {MidiTransport.ble}),
    );

    final data = Uint8List.fromList([0x90, 0x3C, 0x64]);
    midi.sendData(data);

    expect(platform.sent.length, 1);
    expect(ble.sent, isEmpty);
  });
}
