import 'dart:typed_data';

import 'package:flutter_midi_command_ble/flutter_midi_command_ble.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

class _FakeUniversalBlePlatform extends UniversalBlePlatform {
  AvailabilityState availabilityState = AvailabilityState.poweredOn;
  final Set<String> failingConnectIds = <String>{};
  final Map<String, List<BleService>> servicesByDevice =
      <String, List<BleService>>{};
  final Map<String, bool> _pairedByDevice = <String, bool>{};
  final Map<String, BleConnectionState> _connectionByDevice =
      <String, BleConnectionState>{};

  final List<String> connectCalls = <String>[];
  final List<String> disconnectCalls = <String>[];
  int startScanCalls = 0;
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
  ) async {}

  @override
  Future<Uint8List> readValue(
    String deviceId,
    String service,
    String characteristic, {
    Duration? timeout,
  }) async {
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

void main() {
  late _FakeUniversalBlePlatform fakePlatform;
  late UniversalBleMidiTransport transport;

  setUp(() {
    fakePlatform = _FakeUniversalBlePlatform();
    UniversalBle.setInstance(fakePlatform);
    transport = UniversalBleMidiTransport();
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

  test('connectToDevice completes only when BLE connection succeeds', () async {
    fakePlatform.servicesByDevice['ble-1'] = <BleService>[
      BleService(midiServiceId, <BleCharacteristic>[
        BleCharacteristic(midiCharacteristicId, <CharacteristicProperty>[
          CharacteristicProperty.notify,
        ], const <BleDescriptor>[]),
      ]),
    ];

    fakePlatform.emitScanDevice(
      BleDevice(deviceId: 'ble-1', name: 'BLE Device', services: <String>[]),
    );

    final device = (await transport.devices).single;
    expect(device.connected, isFalse);

    await transport.connectToDevice(device);
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(fakePlatform.connectCalls, <String>['ble-1']);
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
  });

  test('disconnectDevice forwards to BLE backend', () async {
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
