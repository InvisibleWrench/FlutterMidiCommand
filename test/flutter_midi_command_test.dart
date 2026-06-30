import 'dart:async';
import 'dart:typed_data';

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
    Future<void>.delayed(const Duration(milliseconds: 10), () {
      device.connected = true;
    });
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
  Future<List<MidiDevice>> get devices async => [
    MidiDevice('ble-1', 'BLE', MidiDeviceType.ble, false),
  ];

  @override
  MidiDevice? registerKnownDevice(String id, String name) => null;

  @override
  Future<void> connectToDevice(
    MidiDevice device, {
    List<MidiPort>? ports,
  }) async {
    connected.add(device.id);
    Future<void>.delayed(const Duration(milliseconds: 10), () {
      device.connected = true;
    });
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

void main() {
  setUp(() {
    MidiCommand.resetForTest();
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
      throwsA(isA<TimeoutException>()),
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
      expect(ble.disconnected, isEmpty);
    },
  );

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
