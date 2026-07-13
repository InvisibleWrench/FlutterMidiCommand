import 'dart:typed_data';

import 'package:flutter_midi_command_ble/flutter_midi_command_ble.dart';
import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

class _FakeUniversalBlePlatform extends UniversalBlePlatform {
  AvailabilityState availabilityState = AvailabilityState.poweredOn;
  final Set<String> failingConnectIds = <String>{};
  final Set<String> failingReadIds = <String>{};
  final Set<String> failingSubscribeIds = <String>{};
  final Set<String> rejectedPairIds = <String>{};
  final Map<String, List<BleService>> servicesByDevice =
      <String, List<BleService>>{};
  final Map<String, bool> _pairedByDevice = <String, bool>{};
  final Map<String, BleConnectionState> _connectionByDevice =
      <String, BleConnectionState>{};

  final List<String> connectCalls = <String>[];
  final List<String> disconnectCalls = <String>[];
  final List<String> pairCalls = <String>[];
  final List<String> readCalls = <String>[];
  final List<String> subscribeCalls = <String>[];
  int startScanCalls = 0;
  int startScanFailures = 0;
  int stopScanCalls = 0;

  @override
  Future<AvailabilityState> getBluetoothAvailabilityState() async {
    return availabilityState;
  }

  @override
  Future<bool> enableBluetooth() async => true;

  @override
  Future<bool> disableBluetooth() async => true;

  @override
  Future<void> startScan({
    ScanFilter? scanFilter,
    PlatformConfig? platformConfig,
  }) async {
    startScanCalls += 1;
    if (startScanFailures > 0) {
      startScanFailures -= 1;
      throw StateError('scan-start-failed');
    }
  }

  @override
  Future<void> stopScan() async {
    stopScanCalls += 1;
  }

  @override
  Future<bool> isScanning() async => false;

  @override
  Future<void> connect(
    String deviceId, {
    Duration? connectionTimeout,
    bool autoConnect = false,
  }) async {
    connectCalls.add(deviceId);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    if (failingConnectIds.contains(deviceId)) {
      updateConnection(deviceId, false, 'connection-failed');
      _connectionByDevice[deviceId] = BleConnectionState.disconnected;
      throw ConnectionException('connection-failed');
    }
    _connectionByDevice[deviceId] = BleConnectionState.connected;
    updateConnection(deviceId, true);
  }

  @override
  Future<void> disconnect(String deviceId) async {
    disconnectCalls.add(deviceId);
    _connectionByDevice[deviceId] = BleConnectionState.disconnected;
    updateConnection(deviceId, false);
  }

  @override
  Future<List<BleService>> discoverServices(
    String deviceId,
    bool withDescriptors,
  ) async {
    return servicesByDevice[deviceId] ?? <BleService>[];
  }

  @override
  Future<void> setNotifiable(
    String deviceId,
    String service,
    String characteristic,
    BleInputProperty bleInputProperty,
  ) async {
    subscribeCalls.add(deviceId);
    if (failingSubscribeIds.contains(deviceId)) {
      throw StateError('subscribe-failed');
    }
  }

  @override
  Future<Uint8List> readValue(
    String deviceId,
    String service,
    String characteristic, {
    Duration? timeout,
  }) async {
    readCalls.add(deviceId);
    if (failingReadIds.contains(deviceId)) {
      throw StateError('read-failed');
    }
    return Uint8List(0);
  }

  @override
  Future<void> writeValue(
    String deviceId,
    String service,
    String characteristic,
    Uint8List value,
    BleOutputProperty bleOutputProperty,
  ) async {}

  @override
  Future<int> requestMtu(String deviceId, int expectedMtu) async {
    return expectedMtu;
  }

  @override
  Future<int> readRssi(String deviceId) async {
    return 0;
  }

  @override
  Future<void> requestConnectionPriority(
    String deviceId,
    BleConnectionPriority priority,
  ) async {}

  @override
  Future<bool> isPaired(String deviceId) async {
    return _pairedByDevice[deviceId] ?? false;
  }

  @override
  Future<bool> pair(String deviceId) async {
    pairCalls.add(deviceId);
    if (rejectedPairIds.contains(deviceId)) {
      return false;
    }
    _pairedByDevice[deviceId] = true;
    updatePairingState(deviceId, true);
    return true;
  }

  @override
  Future<void> unpair(String deviceId) async {
    _pairedByDevice[deviceId] = false;
    updatePairingState(deviceId, false);
  }

  @override
  Future<BleConnectionState> getConnectionState(String deviceId) async {
    return _connectionByDevice[deviceId] ?? BleConnectionState.disconnected;
  }

  @override
  Future<List<BleDevice>> getSystemDevices(List<String>? withServices) async {
    return <BleDevice>[];
  }

  void emitAvailability(AvailabilityState state) {
    availabilityState = state;
    updateAvailability(state);
  }

  void emitScanDevice(BleDevice device) {
    updateScanResult(device);
  }
}

List<BleService> midiServices() {
  return <BleService>[
    BleService(midiServiceId, <BleCharacteristic>[
      BleCharacteristic(midiCharacteristicId, <CharacteristicProperty>[
        CharacteristicProperty.read,
        CharacteristicProperty.notify,
      ], const <BleDescriptor>[]),
    ]),
  ];
}

void main() {
  late _FakeUniversalBlePlatform fakePlatform;
  late UniversalBleMidiTransport transport;
  late bool previousSystemPairingApi;

  setUp(() {
    previousSystemPairingApi = BleCapabilities.hasSystemPairingApi;
    BleCapabilities.hasSystemPairingApi = true;
    fakePlatform = _FakeUniversalBlePlatform();
    UniversalBle.setInstance(fakePlatform);
    transport = UniversalBleMidiTransport();
  });

  tearDown(() {
    BleCapabilities.hasSystemPairingApi = previousSystemPairingApi;
  });

  test(
    'startBluetooth updates and emits bluetooth availability state',
    () async {
      final emittedStates = <String>[];
      final sub = transport.onBluetoothStateChanged.listen(emittedStates.add);

      await transport.startBluetooth();
      fakePlatform.emitAvailability(AvailabilityState.poweredOff);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await sub.cancel();

      expect(await transport.bluetoothState(), 'poweredOff');
      expect(emittedStates, contains('poweredOn'));
      expect(emittedStates, contains('poweredOff'));
    },
  );

  test('startScanningForBluetoothDevices is idempotent', () async {
    await transport.startScanningForBluetoothDevices();
    await transport.startScanningForBluetoothDevices();

    expect(fakePlatform.startScanCalls, 1);
  });

  test('stopScanningForBluetoothDevices is idempotent', () async {
    await transport.startScanningForBluetoothDevices();

    transport.stopScanningForBluetoothDevices();
    transport.stopScanningForBluetoothDevices();
    await Future<void>.delayed(Duration.zero);

    expect(fakePlatform.stopScanCalls, 1);
  });

  test('failed scan start can be retried', () async {
    fakePlatform.startScanFailures = 1;

    await expectLater(
      transport.startScanningForBluetoothDevices(),
      throwsA(isA<StateError>()),
    );
    await transport.startScanningForBluetoothDevices();

    expect(fakePlatform.startScanCalls, 2);
  });

  test('teardown does not stop an inactive scan', () async {
    transport.teardown();
    await Future<void>.delayed(Duration.zero);

    expect(fakePlatform.stopScanCalls, 0);
  });

  test(
    'teardown stops an active scan once and scanning can reactivate',
    () async {
      await transport.startScanningForBluetoothDevices();

      transport.teardown();
      transport.teardown();
      await Future<void>.delayed(Duration.zero);

      expect(fakePlatform.stopScanCalls, 1);

      await transport.startBluetooth();
      await transport.startScanningForBluetoothDevices();

      expect(fakePlatform.startScanCalls, 2);
    },
  );

  test('connectToDevice completes only when BLE connection succeeds', () async {
    fakePlatform.servicesByDevice['ble-1'] = midiServices();

    fakePlatform.emitScanDevice(
      BleDevice(deviceId: 'ble-1', name: 'BLE Device', services: <String>[]),
    );

    final device = (await transport.devices).single;
    expect(device.connected, isFalse);

    await transport.connectToDevice(device);
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(fakePlatform.connectCalls, <String>['ble-1']);
    expect(fakePlatform.pairCalls, <String>['ble-1']);
    expect(fakePlatform.subscribeCalls, <String>['ble-1']);
    expect(device.connected, isTrue);
  });

  test('connectToDevice surfaces BLE connection failures', () async {
    fakePlatform.failingConnectIds.add('ble-2');
    fakePlatform.emitScanDevice(
      BleDevice(
        deviceId: 'ble-2',
        name: 'Failing Device',
        services: <String>[],
      ),
    );
    final device = (await transport.devices).single;

    await expectLater(
      transport.connectToDevice(device),
      throwsA(isA<ConnectionException>()),
    );
    expect(await transport.devices, isEmpty);
  });

  test('disconnectDevice forwards to BLE backend', () async {
    fakePlatform.servicesByDevice['ble-3'] = midiServices();
    fakePlatform.emitScanDevice(
      BleDevice(
        deviceId: 'ble-3',
        name: 'Disconnect Device',
        services: <String>[],
      ),
    );
    final device = (await transport.devices).single;

    await transport.connectToDevice(device);
    transport.disconnectDevice(device);
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(fakePlatform.disconnectCalls, contains('ble-3'));
    expect(device.connected, isFalse);
  });

  test(
    'registerKnownDevice stays hidden until BLE scan rediscovers it',
    () async {
      final registered = transport.registerKnownDevice(
        'ble-known',
        'Known Device',
      );

      expect(registered, isNotNull);
      expect(await transport.devices, isEmpty);

      fakePlatform.emitScanDevice(
        BleDevice(
          deviceId: 'ble-known',
          name: 'Known Device',
          services: <String>[],
        ),
      );

      final devices = await transport.devices;
      expect(devices.single.id, 'ble-known');
    },
  );

  test('connectToDevice makes registered known BLE device visible', () async {
    fakePlatform.servicesByDevice['ble-known-connect'] = midiServices();
    final registered = transport.registerKnownDevice(
      'ble-known-connect',
      'Known Connect Device',
    )!;

    expect(await transport.devices, isEmpty);

    await transport.connectToDevice(registered);

    final devices = await transport.devices;
    expect(devices.single.id, 'ble-known-connect');
    expect(devices.single.connected, isTrue);
  });

  test(
    'disconnectDevice removes stale BLE device until rediscovered',
    () async {
      fakePlatform.servicesByDevice['ble-stale'] = midiServices();
      fakePlatform.emitScanDevice(
        BleDevice(
          deviceId: 'ble-stale',
          name: 'Stale Device',
          services: <String>[],
        ),
      );
      final device = (await transport.devices).single;

      await transport.connectToDevice(device);
      transport.disconnectDevice(device);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(await transport.devices, isEmpty);

      fakePlatform.emitScanDevice(
        BleDevice(
          deviceId: 'ble-stale',
          name: 'Stale Device',
          services: <String>[],
        ),
      );

      expect((await transport.devices).single.id, 'ble-stale');
    },
  );

  test('connectToDevice fails when BLE MIDI service is missing', () async {
    fakePlatform.emitScanDevice(
      BleDevice(
        deviceId: 'ble-no-midi',
        name: 'No MIDI Device',
        services: <String>[],
      ),
    );
    final device = (await transport.devices).single;

    await expectLater(
      transport.connectToDevice(device),
      throwsA(isA<MidiServiceDiscoveryException>()),
    );
    expect(device.connected, isFalse);
  });

  test('connectToDevice surfaces explicit pairing rejection', () async {
    fakePlatform.servicesByDevice['ble-reject'] = midiServices();
    fakePlatform.rejectedPairIds.add('ble-reject');
    fakePlatform.emitScanDevice(
      BleDevice(
        deviceId: 'ble-reject',
        name: 'Reject Device',
        services: <String>[],
      ),
    );
    final device = (await transport.devices).single;

    await expectLater(
      transport.connectToDevice(device),
      throwsA(isA<MidiPairingRejectedException>()),
    );
    expect(device.connected, isFalse);
  });

  test(
    'connectToDevice awaits native-UI pairing trigger when no pairing API',
    () async {
      BleCapabilities.hasSystemPairingApi = false;
      fakePlatform.servicesByDevice['ble-native-ui'] = midiServices();
      fakePlatform.emitScanDevice(
        BleDevice(
          deviceId: 'ble-native-ui',
          name: 'Native UI Device',
          services: <String>[],
        ),
      );
      final device = (await transport.devices).single;

      await transport.connectToDevice(device);

      expect(fakePlatform.readCalls, <String>['ble-native-ui']);
      expect(fakePlatform.pairCalls, isEmpty);
      expect(fakePlatform.subscribeCalls, <String>['ble-native-ui']);
      expect(device.connected, isTrue);
    },
  );

  test('connectToDevice surfaces native-UI pairing trigger failures', () async {
    BleCapabilities.hasSystemPairingApi = false;
    fakePlatform.servicesByDevice['ble-read-fail'] = midiServices();
    fakePlatform.failingReadIds.add('ble-read-fail');
    fakePlatform.emitScanDevice(
      BleDevice(
        deviceId: 'ble-read-fail',
        name: 'Read Fail Device',
        services: <String>[],
      ),
    );
    final device = (await transport.devices).single;

    await expectLater(
      transport.connectToDevice(device),
      throwsA(isA<MidiPairingFailedException>()),
    );
    expect(device.connected, isFalse);
  });

  test('connectToDevice surfaces notification subscription failures', () async {
    fakePlatform.servicesByDevice['ble-subscribe-fail'] = midiServices();
    fakePlatform.failingSubscribeIds.add('ble-subscribe-fail');
    fakePlatform.emitScanDevice(
      BleDevice(
        deviceId: 'ble-subscribe-fail',
        name: 'Subscribe Fail Device',
        services: <String>[],
      ),
    );
    final device = (await transport.devices).single;

    await expectLater(
      transport.connectToDevice(device),
      throwsA(isA<MidiNotificationSubscriptionException>()),
    );
    expect(device.connected, isFalse);
  });

  test('teardown unregisters callbacks and can be reactivated', () async {
    expect(fakePlatform.onScanResultUpdate, isNotNull);
    expect(fakePlatform.onConnectionChange, isNotNull);
    expect(fakePlatform.onValueChange, isNotNull);
    expect(fakePlatform.onAvailabilityChange, isNotNull);

    transport.teardown();

    expect(fakePlatform.onScanResultUpdate, isNull);
    expect(fakePlatform.onConnectionChange, isNull);
    expect(fakePlatform.onValueChange, isNull);
    expect(fakePlatform.onAvailabilityChange, isNull);

    await transport.startBluetooth();

    expect(fakePlatform.onScanResultUpdate, isNotNull);
    expect(fakePlatform.onConnectionChange, isNotNull);
    expect(fakePlatform.onValueChange, isNotNull);
    expect(fakePlatform.onAvailabilityChange, isNotNull);
  });
}
