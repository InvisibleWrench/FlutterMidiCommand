import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_midi_command_ble/flutter_midi_command_ble.dart';
import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

class _FakeUniversalBlePlatform extends UniversalBlePlatform {
  AvailabilityState availabilityState = AvailabilityState.poweredOn;
  final Set<String> failingConnectIds = <String>{};
  final Set<String> pairingRemovedConnectIds = <String>{};
  final Set<String> failingReadIds = <String>{};
  final Set<String> failingSubscribeIds = <String>{};

  /// Devices whose `setNotifiable` fails because the peer discarded its bond,
  /// rather than the connect call failing that way.
  final Set<String> pairingRemovedSubscribeIds = <String>{};
  final Set<String> failingWriteIds = <String>{};

  /// MTU handed back from `requestMtu`, or null to echo what was asked for.
  int? negotiatedMtu;
  bool failMtu = false;

  /// Simulated time for one BLE write, so overlapping sends can be observed.
  Duration writeDelay = Duration.zero;

  /// Payloads passed to `writeValue`, in order.
  final List<List<int>> writtenPackets = <List<int>>[];
  final List<BleConnectionPriority> priorityRequests =
      <BleConnectionPriority>[];
  final Set<String> rejectedPairIds = <String>{};

  /// Peripherals that will not serve the MIDI characteristic until the link is
  /// encrypted: `setNotifiable` is refused with the code Android reports for a
  /// CCCD write rejected as `GATT_INSUFFICIENT_AUTHENTICATION`, and succeeds
  /// once a bond exists. A genuinely locked peripheral, as opposed to the
  /// bonding-optional kind that is the common case.
  final Set<String> bondRequiredSubscribeIds = <String>{};

  /// Peripherals whose `pair` reports success without a bond ever landing —
  /// the PP-2's failure mode, and why the bond state is re-read rather than
  /// trusting `pair`.
  final Set<String> pairWithoutBondingIds = <String>{};

  /// Peripherals that refuse the subscription however often it is asked for,
  /// bond or no bond.
  final Set<String> alwaysRefusingSubscribeIds = <String>{};

  /// Peripherals the Android stack bonds *inside* the CCCD write: the write is
  /// held while the system pairing dialog is up, a bond appears without anyone
  /// calling `pair`, and then the write succeeds. Observed in the field, and
  /// the primary path on Android for a peripheral that requires encryption.
  final Set<String> bondsDuringSubscribeIds = <String>{};

  /// Code the two refusal fixtures report. Defaults to what Android maps an
  /// ATT 0x05 Insufficient Authentication descriptor write to.
  UniversalBleErrorCode subscribeRefusalCode =
      UniversalBleErrorCode.insufficientAuthentication;

  /// Remaining `setNotifiable` attempts that fail the way Android does when
  /// `createBond` tore the link down behind a successful bond. Only consulted
  /// once bonded, so it composes with [bondRequiredSubscribeIds] to model the
  /// whole locked-peripheral sequence: refuse, bond, link drop, reconnect,
  /// subscribe.
  final Map<String, int> postBondSubscribeLinkDrops = <String, int>{};

  /// Peripherals whose `setNotifiable` never answers, for the timeout path.
  final Set<String> hangingSubscribeIds = <String>{};

  final Map<String, List<BleService>> servicesByDevice =
      <String, List<BleService>>{};
  final Map<String, bool> _pairedByDevice = <String, bool>{};
  final Map<String, BleConnectionState> _connectionByDevice =
      <String, BleConnectionState>{};

  /// Seeds the OS bond state, for a device paired before this connect.
  void seedPaired(String deviceId) => _pairedByDevice[deviceId] = true;

  /// Reports a bond established outside this transport, as the OS does when
  /// the user pairs from system settings.
  void emitPairingState(String deviceId, bool paired) {
    _pairedByDevice[deviceId] = paired;
    updatePairingState(deviceId, paired);
  }

  /// Number of remaining `connect` attempts that fail with Android's generic
  /// GATT_ERROR, keyed by device id.
  final Map<String, int> transientGattFailures = <String, int>{};

  /// Number of remaining `setNotifiable` attempts that fail the way Android
  /// does when the link drops mid-handshake: named after the operation, with
  /// the GATT status carried in `details` as a string.
  final Map<String, int> transientGattSubscribeFailures = <String, int>{};

  /// Number of remaining `discoverServices` attempts that fail because the
  /// link was torn down with the operation in flight.
  final Map<String, int> disconnectedDiscoverFailures = <String, int>{};

  /// GATT operations in the order the transport issued them.
  final List<String> gattCalls = <String>[];

  final List<String> connectCalls = <String>[];
  final List<String> disconnectCalls = <String>[];
  final List<String> pairCalls = <String>[];
  final List<String> unpairCalls = <String>[];
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
    ConnectionPlatformConfig? platformConfig,
  }) async {
    connectCalls.add(deviceId);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    final remainingGattFailures = transientGattFailures[deviceId] ?? 0;
    if (remainingGattFailures > 0) {
      transientGattFailures[deviceId] = remainingGattFailures - 1;
      updateConnection(deviceId, false, 'Unknown Error 133');
      _connectionByDevice[deviceId] = BleConnectionState.disconnected;
      throw ConnectionException('Unknown Error 133');
    }
    if (pairingRemovedConnectIds.contains(deviceId)) {
      updateConnection(deviceId, false, 'Peer removed pairing information');
      _connectionByDevice[deviceId] = BleConnectionState.disconnected;
      // Shaped as universal_ble really reports it: a connection-state failure
      // goes through `ConnectionException(reason)`, which puts the reason
      // string in `details` as well as the message.
      throw UniversalBleException(
        code: UniversalBleErrorCode.unknownError,
        message: 'Peer removed pairing information',
        details: 'Peer removed pairing information',
      );
    }
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
    gattCalls.add('discover');
    final remaining = disconnectedDiscoverFailures[deviceId] ?? 0;
    if (remaining > 0) {
      disconnectedDiscoverFailures[deviceId] = remaining - 1;
      updateConnection(deviceId, false);
      _connectionByDevice[deviceId] = BleConnectionState.disconnected;
      // universal_ble fails every in-flight GATT operation this way when the
      // link is torn down underneath it.
      throw UniversalBleException(
        code: UniversalBleErrorCode.deviceDisconnected,
        message: 'Device Disconnected',
        details: 'DEVICE_DISCONNECTED',
      );
    }
    return servicesByDevice[deviceId] ?? <BleService>[];
  }

  @override
  Future<void> setNotifiable(
    String deviceId,
    String service,
    String characteristic,
    BleInputProperty bleInputProperty,
  ) async {
    gattCalls.add('subscribe');
    subscribeCalls.add(deviceId);
    if (hangingSubscribeIds.contains(deviceId)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      return;
    }
    final remainingGattFailures = transientGattSubscribeFailures[deviceId] ?? 0;
    if (remainingGattFailures > 0) {
      transientGattSubscribeFailures[deviceId] = remainingGattFailures - 1;
      updateConnection(deviceId, false);
      _connectionByDevice[deviceId] = BleConnectionState.disconnected;
      throw UniversalBleException(
        code: UniversalBleErrorCode.unknownError,
        message: 'Failed to update subscription state',
        details: '133',
      );
    }
    if (pairingRemovedSubscribeIds.contains(deviceId)) {
      updateConnection(deviceId, false, 'Peer removed pairing information');
      _connectionByDevice[deviceId] = BleConnectionState.disconnected;
      throw UniversalBleException(
        code: UniversalBleErrorCode.unknownError,
        message: 'Peer removed pairing information',
        details: 'Peer removed pairing information',
      );
    }
    if (bondsDuringSubscribeIds.contains(deviceId) &&
        _pairedByDevice[deviceId] != true) {
      // The stack bonds under us and the write then succeeds. The pairing
      // state lands mid-subscription, which is the interesting part.
      _pairedByDevice[deviceId] = true;
      updatePairingState(deviceId, true);
      return;
    }
    final bonded = _pairedByDevice[deviceId] ?? false;
    if (alwaysRefusingSubscribeIds.contains(deviceId) ||
        (bondRequiredSubscribeIds.contains(deviceId) && !bonded)) {
      // Android's shape for a CCCD write refused for want of encryption: named
      // after the operation, with the ATT status in `details`. Note `details`
      // is '5', not '133', which is what keeps it clear of the transient-link
      // classification. The link stays up, as it does on the real stack.
      throw UniversalBleException(
        code: subscribeRefusalCode,
        message: 'Failed to update subscription state',
        details: '5',
      );
    }
    final remainingPostBondDrops = postBondSubscribeLinkDrops[deviceId] ?? 0;
    if (remainingPostBondDrops > 0 && bonded) {
      postBondSubscribeLinkDrops[deviceId] = remainingPostBondDrops - 1;
      updateConnection(deviceId, false);
      _connectionByDevice[deviceId] = BleConnectionState.disconnected;
      throw UniversalBleException(
        code: UniversalBleErrorCode.deviceDisconnected,
        message: 'Device Disconnected',
        details: 'DEVICE_DISCONNECTED',
      );
    }
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
    // Apple and web have no pairing API: the access itself starts "Just Works"
    // pairing and the read completes once the bond has taken.
    if (bondRequiredSubscribeIds.contains(deviceId)) {
      _pairedByDevice[deviceId] = true;
      updatePairingState(deviceId, true);
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
  ) async {
    if (writeDelay > Duration.zero) {
      await Future<void>.delayed(writeDelay);
    }
    writtenPackets.add(value.toList());
    if (failingWriteIds.contains(deviceId)) {
      throw StateError('write-failed');
    }
  }

  @override
  Future<int> requestMtu(String deviceId, int expectedMtu) async {
    gattCalls.add('mtu');
    if (failMtu) {
      throw StateError('mtu-failed');
    }
    return negotiatedMtu ?? expectedMtu;
  }

  @override
  Future<int> readRssi(String deviceId) async {
    return 0;
  }

  @override
  Future<void> requestConnectionPriority(
    String deviceId,
    BleConnectionPriority priority,
  ) async {
    gattCalls.add('priority');
    priorityRequests.add(priority);
  }

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
    if (pairWithoutBondingIds.contains(deviceId)) {
      // Reports success, but no bond lands and no pairing state is published.
      return true;
    }
    _pairedByDevice[deviceId] = true;
    updatePairingState(deviceId, true);
    return true;
  }

  @override
  Future<void> unpair(String deviceId) async {
    unpairCalls.add(deviceId);
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
    expect(fakePlatform.subscribeCalls, <String>['ble-1']);
    // BLE MIDI carries no security requirement, so a peripheral that serves
    // the characteristic is never asked to bond and the user never sees a
    // pairing dialog they did not need.
    expect(fakePlatform.pairCalls, isEmpty);
    expect(device.connected, isTrue);
  });

  test(
    'a peripheral that demands encryption is bonded, then connects',
    () async {
      fakePlatform.servicesByDevice['ble-locked'] = midiServices();
      fakePlatform.bondRequiredSubscribeIds.add('ble-locked');
      fakePlatform.emitScanDevice(
        BleDevice(
          deviceId: 'ble-locked',
          name: 'Locked Device',
          services: <String>[],
        ),
      );
      final device = (await transport.devices).single;

      await transport.connectToDevice(device);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      // Refused, bonded, and served on the second attempt — all on one link.
      expect(fakePlatform.subscribeCalls, <String>['ble-locked', 'ble-locked']);
      expect(fakePlatform.pairCalls, <String>['ble-locked']);
      // Not a transient fault, so the whole sequence was never restarted.
      expect(fakePlatform.connectCalls, <String>['ble-locked']);
      expect(device.connected, isTrue);
    },
  );

  test('bonding refused by a peripheral that demands it is reported', () async {
    fakePlatform.servicesByDevice['ble-locked-reject'] = midiServices();
    fakePlatform.bondRequiredSubscribeIds.add('ble-locked-reject');
    fakePlatform.rejectedPairIds.add('ble-locked-reject');
    fakePlatform.emitScanDevice(
      BleDevice(
        deviceId: 'ble-locked-reject',
        name: 'Locked Reject',
        services: <String>[],
      ),
    );
    final device = (await transport.devices).single;

    await expectLater(
      transport.connectToDevice(device),
      throwsA(isA<MidiPairingRejectedException>()),
    );
    expect(device.connected, isFalse);
    // Asked once. A refusal is not retried into a second dialog.
    expect(fakePlatform.pairCalls, <String>['ble-locked-reject']);
  });

  test('a bond that reports success but never lands is rejected', () async {
    // The PP-2's own failure mode: pair() resolves, the user accepts, and no
    // bond exists afterwards.
    fakePlatform.servicesByDevice['ble-phantom'] = midiServices();
    fakePlatform.bondRequiredSubscribeIds.add('ble-phantom');
    fakePlatform.pairWithoutBondingIds.add('ble-phantom');
    fakePlatform.emitScanDevice(
      BleDevice(
        deviceId: 'ble-phantom',
        name: 'Phantom Bond',
        services: <String>[],
      ),
    );
    final device = (await transport.devices).single;

    await expectLater(
      transport.connectToDevice(device),
      throwsA(isA<MidiPairingRejectedException>()),
    );
    expect(fakePlatform.pairCalls, <String>['ble-phantom']);
    expect(device.connected, isFalse);
  });

  test('a bond is asked for once across the connection retry', () async {
    // The central real-world path for a locked peripheral: Android brings the
    // bond up and drops the link behind it. The re-subscribe fails as a
    // transient fault, the whole sequence is retried — and the second pass
    // finds the bond already there, so the user is asked exactly once.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    fakePlatform.servicesByDevice['ble-bond-drop'] = midiServices();
    fakePlatform.bondRequiredSubscribeIds.add('ble-bond-drop');
    fakePlatform.postBondSubscribeLinkDrops['ble-bond-drop'] = 1;
    fakePlatform.emitScanDevice(
      BleDevice(
        deviceId: 'ble-bond-drop',
        name: 'Bond Drops Link',
        services: <String>[],
      ),
    );
    final device = (await transport.devices).single;

    await transport.connectToDevice(device);
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(fakePlatform.connectCalls, <String>[
      'ble-bond-drop',
      'ble-bond-drop',
    ]);
    // One dialog, not two.
    expect(fakePlatform.pairCalls, <String>['ble-bond-drop']);
    expect(device.connected, isTrue);
  });

  group('a refusal a bond cannot fix is not escalated', () {
    // Why the escalation reads the code rather than treating every refusal as
    // a bonding problem: for each of these a bond cannot help, and a pairing
    // dialog would be noise on top of an error the application needs to see.
    for (final code in <UniversalBleErrorCode>[
      UniversalBleErrorCode.characteristicDoesNotSupportNotify,
      UniversalBleErrorCode.bluetoothNotAllowed,
      UniversalBleErrorCode.notPairable,
      UniversalBleErrorCode.pairingNotAllowed,
    ]) {
      test(code.name, () async {
        fakePlatform.servicesByDevice['ble-$code'] = midiServices();
        fakePlatform.alwaysRefusingSubscribeIds.add('ble-$code');
        fakePlatform.subscribeRefusalCode = code;
        fakePlatform.emitScanDevice(
          BleDevice(
            deviceId: 'ble-$code',
            name: 'Refusing Device',
            services: <String>[],
          ),
        );
        final device = (await transport.devices).single;

        await expectLater(
          transport.connectToDevice(device),
          throwsA(isA<MidiNotificationSubscriptionException>()),
        );
        expect(fakePlatform.pairCalls, isEmpty);
        expect(device.connected, isFalse);
      });
    }
  });

  test('an unnamed refusal is still escalated to a bond', () async {
    // Android's catch-all. A peripheral that wants a bond but whose ATT status
    // did not survive the trip must still reach the outcome it used to.
    fakePlatform.servicesByDevice['ble-unnamed'] = midiServices();
    fakePlatform.bondRequiredSubscribeIds.add('ble-unnamed');
    fakePlatform.subscribeRefusalCode = UniversalBleErrorCode.unknownError;
    fakePlatform.emitScanDevice(
      BleDevice(
        deviceId: 'ble-unnamed',
        name: 'Unnamed Refusal',
        services: <String>[],
      ),
    );
    final device = (await transport.devices).single;

    await transport.connectToDevice(device);
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(fakePlatform.pairCalls, <String>['ble-unnamed']);
    expect(device.connected, isTrue);
  });

  test('a subscription timeout is not escalated to a bond', () async {
    // A timeout unwraps to a TimeoutException, not a platform error, so it
    // says nothing about encryption. Escalating would spend the caller's
    // readiness budget twice over and put a dialog in front of a peripheral
    // that is not answering at all.
    fakePlatform.servicesByDevice['ble-hang'] = midiServices();
    fakePlatform.hangingSubscribeIds.add('ble-hang');
    fakePlatform.emitScanDevice(
      BleDevice(deviceId: 'ble-hang', name: 'Hanging', services: <String>[]),
    );
    final device = (await transport.devices).single;

    await expectLater(
      transport.connectToDevice(
        device,
        timeout: const Duration(milliseconds: 20),
      ),
      throwsA(
        isA<MidiConnectionTimeoutException>().having(
          (e) => e.stage,
          'stage',
          MidiConnectionStage.notificationSubscription,
        ),
      ),
    );
    expect(fakePlatform.pairCalls, isEmpty);
    expect(device.connected, isFalse);
  });

  test(
    'an out-of-band bond cannot mark an unprepared device connected',
    () async {
      // onPairingStateChange fires for a bond made in system settings, before
      // this transport has discovered anything. There is nothing to subscribe
      // to, so the device must be left alone rather than reported connected.
      fakePlatform.servicesByDevice['ble-oob'] = midiServices();
      fakePlatform.emitScanDevice(
        BleDevice(
          deviceId: 'ble-oob',
          name: 'Out Of Band',
          services: <String>[],
        ),
      );
      final device = (await transport.devices).single;

      fakePlatform.emitPairingState('ble-oob', true);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(device.connected, isFalse);
      expect(fakePlatform.subscribeCalls, isEmpty);
    },
  );

  test('an already-bonded device is not asked to bond again', () async {
    fakePlatform.servicesByDevice['ble-bonded'] = midiServices();
    fakePlatform.seedPaired('ble-bonded');
    fakePlatform.emitScanDevice(
      BleDevice(
        deviceId: 'ble-bonded',
        name: 'Bonded Device',
        services: <String>[],
      ),
    );
    final device = (await transport.devices).single;

    await transport.connectToDevice(device);
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(fakePlatform.pairCalls, isEmpty);
    expect(device.connected, isTrue);
  });

  test(
    'a bonded device\'s subscribe failure is surfaced, not re-bonded',
    () async {
      // Nothing a bond could fix: the OS already has one, so the refusal is
      // reported as what it is rather than provoking a pointless dialog.
      fakePlatform.servicesByDevice['ble-bonded-fail'] = midiServices();
      fakePlatform.seedPaired('ble-bonded-fail');
      fakePlatform.failingSubscribeIds.add('ble-bonded-fail');
      fakePlatform.emitScanDevice(
        BleDevice(
          deviceId: 'ble-bonded-fail',
          name: 'Bonded Failing',
          services: <String>[],
        ),
      );
      final device = (await transport.devices).single;

      await expectLater(
        transport.connectToDevice(device),
        throwsA(isA<MidiNotificationSubscriptionException>()),
      );
      expect(fakePlatform.pairCalls, isEmpty);
      expect(device.connected, isFalse);
    },
  );

  test('MTU negotiation runs after the MIDI path is live', () async {
    fakePlatform.servicesByDevice['ble-mtu'] = midiServices();
    fakePlatform.emitScanDevice(
      BleDevice(deviceId: 'ble-mtu', name: 'MTU Device', services: <String>[]),
    );

    await transport.connectToDevice((await transport.devices).single);
    await Future<void>.delayed(const Duration(milliseconds: 5));

    // Both the MTU exchange and the connection priority request share
    // universal_ble's single command queue, so both must come after discovery
    // and subscription or they can stall the link into Android's GATT 133.
    expect(fakePlatform.gattCalls, <String>[
      'discover',
      'subscribe',
      'mtu',
      'priority',
    ]);
  });

  test('connectToDevice retries once through a transient GATT 133', () async {
    fakePlatform.servicesByDevice['ble-133'] = midiServices();
    fakePlatform.transientGattFailures['ble-133'] = 1;
    fakePlatform.emitScanDevice(
      BleDevice(
        deviceId: 'ble-133',
        name: 'Flaky Device',
        services: <String>[],
      ),
    );
    final device = (await transport.devices).single;

    await transport.connectToDevice(device);
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(fakePlatform.connectCalls, <String>['ble-133', 'ble-133']);
    expect(device.connected, isTrue);
    // The failed attempt reported a disconnect; the device must survive it so
    // received data still resolves to it.
    expect((await transport.devices).single.id, 'ble-133');
  });

  test('connectToDevice retries when the link drops during subscribe', () async {
    // The link comes up, then goes away part-way through the handshake. Android
    // names that failure after the operation rather than reporting a plain
    // GATT_ERROR, so it only gets classified as transient if the status in
    // `details` is read through the stage wrapper.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    fakePlatform.servicesByDevice['ble-sub-133'] = midiServices();
    fakePlatform.transientGattSubscribeFailures['ble-sub-133'] = 1;
    fakePlatform.emitScanDevice(
      BleDevice(
        deviceId: 'ble-sub-133',
        name: 'Flaky Handshake',
        services: <String>[],
      ),
    );
    final device = (await transport.devices).single;

    await transport.connectToDevice(device);
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(fakePlatform.connectCalls, <String>['ble-sub-133', 'ble-sub-133']);
    expect(fakePlatform.subscribeCalls, <String>['ble-sub-133', 'ble-sub-133']);
    expect(device.connected, isTrue);
    expect((await transport.devices).single.id, 'ble-sub-133');
    // A link that went away says nothing about encryption, so it must not put
    // a pairing dialog in front of the user on its way to being retried.
    expect(fakePlatform.pairCalls, isEmpty);
  });

  test(
    'a bond the stack makes inside the subscribe needs no escalation',
    () async {
      // What Android actually does for a peripheral that requires encryption,
      // confirmed in the field against a GEWA_Mid: the CCCD write is held while
      // the system puts up its own pairing dialog, a bond appears with nobody
      // having called pair(), and the write then completes. The escalation in
      // this transport is the fallback for when that does not happen.
      //
      // The subscription count is the assertion that matters. The bond lands
      // mid-readiness, so onPairingStateChange fires while connect() is in
      // flight — and that must not start a second, concurrent subscribe into
      // universal_ble's shared command queue.
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      fakePlatform.servicesByDevice['ble-stack-bond'] = midiServices();
      fakePlatform.bondsDuringSubscribeIds.add('ble-stack-bond');
      fakePlatform.emitScanDevice(
        BleDevice(
          deviceId: 'ble-stack-bond',
          name: 'Stack Bonds',
          services: <String>[],
        ),
      );
      final device = (await transport.devices).single;

      await transport.connectToDevice(device);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(fakePlatform.subscribeCalls, <String>['ble-stack-bond']);
      expect(fakePlatform.pairCalls, isEmpty);
      expect(fakePlatform.connectCalls, <String>['ble-stack-bond']);
      expect(device.connected, isTrue);
    },
  );

  test('a link drop on the first subscribe still reaches the bond', () async {
    // Observed in the field on Android: the first subscribe of a never-bonded
    // peripheral came back as a generic GATT 133 rather than a security
    // status. That is a transient link fault as far as this transport can
    // tell, so it is retried — and the retry has to be able to recognise the
    // refusal for what it is and escalate, or a peripheral that needs a bond
    // would never be offered one.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    fakePlatform.servicesByDevice['ble-133-then-bond'] = midiServices();
    fakePlatform.transientGattSubscribeFailures['ble-133-then-bond'] = 1;
    fakePlatform.bondRequiredSubscribeIds.add('ble-133-then-bond');
    fakePlatform.emitScanDevice(
      BleDevice(
        deviceId: 'ble-133-then-bond',
        name: 'Dropped Then Locked',
        services: <String>[],
      ),
    );
    final device = (await transport.devices).single;

    await transport.connectToDevice(device);
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(fakePlatform.connectCalls, <String>[
      'ble-133-then-bond',
      'ble-133-then-bond',
    ]);
    // One dialog, on the attempt that got a real answer out of the peripheral.
    expect(fakePlatform.pairCalls, <String>['ble-133-then-bond']);
    expect(device.connected, isTrue);
  });

  test('connectToDevice retries a link torn down during discovery', () async {
    // The observed Android failure: the link comes up, discovery is issued, and
    // the link drops with it in flight. universal_ble reports it as
    // deviceDisconnected rather than a GATT status, so it is only classified as
    // transient by the error code. Not platform-specific — the code means the
    // same thing everywhere, so pin the platform to iOS to prove it.
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    fakePlatform.servicesByDevice['ble-disc-drop'] = midiServices();
    fakePlatform.disconnectedDiscoverFailures['ble-disc-drop'] = 1;
    fakePlatform.emitScanDevice(
      BleDevice(
        deviceId: 'ble-disc-drop',
        name: 'Dropped Discovery',
        services: <String>[],
      ),
    );
    final device = (await transport.devices).single;

    await transport.connectToDevice(device);
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(fakePlatform.connectCalls, <String>[
      'ble-disc-drop',
      'ble-disc-drop',
    ]);
    expect(device.connected, isTrue);
    expect((await transport.devices).single.id, 'ble-disc-drop');
  });

  test('removed pairing is typed even when a later stage reports it', () async {
    // The peer can discard its bond at a stage past the connect, where the
    // failure arrives wrapped in that stage's exception. Unwrapped, it is the
    // same condition and must reach the application as the same typed error —
    // otherwise a caller retrying on it never sees it.
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    fakePlatform.servicesByDevice['ble-late-bond'] = midiServices();
    fakePlatform.pairingRemovedSubscribeIds.add('ble-late-bond');
    fakePlatform.emitScanDevice(
      BleDevice(
        deviceId: 'ble-late-bond',
        name: 'Late Stale Bond',
        services: <String>[],
      ),
    );
    final device = (await transport.devices).single;

    await expectLater(
      transport.connectToDevice(device),
      throwsA(isA<MidiPairingInfoRemovedException>()),
    );
    expect(device.connected, isFalse);
    expect(fakePlatform.unpairCalls, contains('ble-late-bond'));
    // Surfaced, not retried: a discarded bond is not a transient link fault.
    expect(fakePlatform.connectCalls, <String>['ble-late-bond']);
  });

  test('a 133 in details is not treated as a GATT error off Android', () async {
    // Apple puts the raw NSError code in the same field, and 133 is 0x85 —
    // inside CBATTError's application-defined range, where it means something
    // unrelated. Reading it as an Android GATT status there would retry a
    // failure that is not transient.
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    fakePlatform.servicesByDevice['ble-att-85'] = midiServices();
    fakePlatform.transientGattSubscribeFailures['ble-att-85'] = 1;
    // Already bonded, so the refusal cannot be answered with a bond and this
    // test is about the `details` classification alone.
    fakePlatform.seedPaired('ble-att-85');
    fakePlatform.emitScanDevice(
      BleDevice(
        deviceId: 'ble-att-85',
        name: 'Apple Peripheral',
        services: <String>[],
      ),
    );
    final device = (await transport.devices).single;

    await expectLater(
      transport.connectToDevice(device),
      throwsA(isA<MidiNotificationSubscriptionException>()),
    );

    // One attempt only: the failure was surfaced rather than retried.
    expect(fakePlatform.connectCalls, <String>['ble-att-85']);
    expect(fakePlatform.subscribeCalls, <String>['ble-att-85']);
    expect(fakePlatform.pairCalls, isEmpty);
    expect(fakePlatform.readCalls, isEmpty);
  });

  test('connectToDevice gives up after one subscribe-drop retry', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    fakePlatform.servicesByDevice['ble-sub-hard'] = midiServices();
    fakePlatform.transientGattSubscribeFailures['ble-sub-hard'] = 5;
    fakePlatform.emitScanDevice(
      BleDevice(
        deviceId: 'ble-sub-hard',
        name: 'Dead Handshake',
        services: <String>[],
      ),
    );
    final device = (await transport.devices).single;

    await expectLater(
      transport.connectToDevice(device),
      throwsA(isA<MidiNotificationSubscriptionException>()),
    );

    expect(fakePlatform.connectCalls, <String>['ble-sub-hard', 'ble-sub-hard']);
    expect(device.connected, isFalse);
  });

  test('connectToDevice gives up after one GATT 133 retry', () async {
    fakePlatform.servicesByDevice['ble-133-hard'] = midiServices();
    fakePlatform.transientGattFailures['ble-133-hard'] = 5;
    fakePlatform.emitScanDevice(
      BleDevice(
        deviceId: 'ble-133-hard',
        name: 'Dead Device',
        services: <String>[],
      ),
    );
    final device = (await transport.devices).single;

    await expectLater(
      transport.connectToDevice(device),
      throwsA(isA<ConnectionException>()),
    );

    expect(fakePlatform.connectCalls, <String>['ble-133-hard', 'ble-133-hard']);
    expect(device.connected, isFalse);
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

  test(
    'connectToDevice maps removed pairing information to a typed exception',
    () async {
      // iOS is where this error actually occurs, and it must be classified as
      // a removed bond rather than as a transient failure to retry blindly.
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      fakePlatform.servicesByDevice['ble-stale-bond'] = midiServices();
      fakePlatform.pairingRemovedConnectIds.add('ble-stale-bond');
      fakePlatform.emitScanDevice(
        BleDevice(
          deviceId: 'ble-stale-bond',
          name: 'Stale Bond Device',
          services: <String>[],
        ),
      );
      final device = (await transport.devices).single;

      await expectLater(
        transport.connectToDevice(device),
        throwsA(isA<MidiPairingInfoRemovedException>()),
      );
      expect(device.connected, isFalse);
      // The stale bond is cleared best-effort so a later reconnect re-pairs.
      expect(fakePlatform.unpairCalls, contains('ble-stale-bond'));
    },
  );

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
    // The peripheral has to actually want a bond for one to be asked for, so
    // refusing to pair is only reachable behind a refused subscription.
    fakePlatform.servicesByDevice['ble-reject'] = midiServices();
    fakePlatform.bondRequiredSubscribeIds.add('ble-reject');
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
    // Asked once. A refusal is not retried into a second dialog.
    expect(fakePlatform.pairCalls, <String>['ble-reject']);
    // Surfaced, not retried from scratch.
    expect(fakePlatform.connectCalls, <String>['ble-reject']);
  });

  test(
    'no pairing API and no refusal means no pairing trigger at all',
    () async {
      // The Apple half of the change: a peripheral that serves the
      // characteristic is never provoked into pairing, so no OS pairing UI
      // appears for a device that did not need it.
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

      expect(fakePlatform.readCalls, isEmpty);
      expect(fakePlatform.pairCalls, isEmpty);
      expect(fakePlatform.subscribeCalls, <String>['ble-native-ui']);
      expect(device.connected, isTrue);
    },
  );

  test('no pairing API escalates a refusal to a characteristic read', () async {
    // Where there is no pair() to call, the read is the lever: universal_ble
    // triggers "Just Works" pairing from a read or write of an encrypted
    // characteristic, and a CCCD write is neither — so the subscription
    // cannot be relied on to provoke it.
    BleCapabilities.hasSystemPairingApi = false;
    fakePlatform.servicesByDevice['ble-native-locked'] = midiServices();
    fakePlatform.bondRequiredSubscribeIds.add('ble-native-locked');
    fakePlatform.emitScanDevice(
      BleDevice(
        deviceId: 'ble-native-locked',
        name: 'Native Locked',
        services: <String>[],
      ),
    );
    final device = (await transport.devices).single;

    await transport.connectToDevice(device);

    expect(fakePlatform.readCalls, <String>['ble-native-locked']);
    expect(fakePlatform.pairCalls, isEmpty);
    expect(fakePlatform.subscribeCalls, <String>[
      'ble-native-locked',
      'ble-native-locked',
    ]);
    expect(device.connected, isTrue);
  });

  test('connectToDevice surfaces native-UI pairing trigger failures', () async {
    BleCapabilities.hasSystemPairingApi = false;
    fakePlatform.servicesByDevice['ble-read-fail'] = midiServices();
    // Refuse the subscription so the read trigger is actually reached.
    fakePlatform.bondRequiredSubscribeIds.add('ble-read-fail');
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

  // A GEWA firmware data packet: F0 7E 10 07 02 <seq> <size> + 128 encoded
  // bytes + checksum + F7. This is the message whose packet count decides how
  // long a firmware transfer takes.
  Uint8List firmwareSysEx([int marker = 0x00]) {
    return Uint8List.fromList(<int>[
      0xF0,
      0x7E,
      0x10,
      0x07,
      0x02,
      0x00,
      0x7F,
      ...List<int>.filled(128, marker),
      0x2A,
      0xF7,
    ]);
  }

  Future<MidiDevice> connectDevice(
    UniversalBleMidiTransport target,
    String deviceId,
  ) async {
    fakePlatform.servicesByDevice[deviceId] = midiServices();
    fakePlatform.emitScanDevice(
      BleDevice(deviceId: deviceId, name: deviceId, services: <String>[]),
    );
    final device = (await target.devices).firstWhere((d) => d.id == deviceId);
    await target.connectToDevice(device);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return device;
  }

  test('a large MTU sends a firmware SysEx as a single write', () async {
    fakePlatform.negotiatedMtu = 247;
    await connectDevice(transport, 'ble-mtu-large');
    fakePlatform.writtenPackets.clear();

    transport.sendData(firmwareSysEx(), deviceId: 'ble-mtu-large');
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(fakePlatform.writtenPackets, hasLength(1));
    expect(fakePlatform.writtenPackets.single, hasLength(137 + 3));
  });

  test('the default 23-byte MTU still sends 20-byte packets', () async {
    fakePlatform.negotiatedMtu = 23;
    await connectDevice(transport, 'ble-mtu-small');
    fakePlatform.writtenPackets.clear();

    transport.sendData(firmwareSysEx(), deviceId: 'ble-mtu-small');
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(fakePlatform.writtenPackets, hasLength(8));
    for (final packet in fakePlatform.writtenPackets) {
      expect(packet.length, lessThanOrEqualTo(20));
    }
  });

  test('a failed MTU exchange falls back to 20-byte packets', () async {
    fakePlatform.failMtu = true;
    await connectDevice(transport, 'ble-mtu-failed');
    fakePlatform.writtenPackets.clear();

    transport.sendData(firmwareSysEx(), deviceId: 'ble-mtu-failed');
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(fakePlatform.writtenPackets, hasLength(8));
  });

  test('useNegotiatedMtu: false pins packets to 20 bytes', () async {
    final pinned = UniversalBleMidiTransport(useNegotiatedMtu: false);
    fakePlatform.negotiatedMtu = 247;
    await connectDevice(pinned, 'ble-mtu-opt-out');
    fakePlatform.writtenPackets.clear();

    pinned.sendData(firmwareSysEx(), deviceId: 'ble-mtu-opt-out');
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(fakePlatform.writtenPackets, hasLength(8));
    expect(fakePlatform.gattCalls, isNot(contains('mtu')));
    pinned.teardown();
  });

  test('a reconnect does not inherit the previous link packet size', () async {
    fakePlatform.negotiatedMtu = 247;
    final device = await connectDevice(transport, 'ble-mtu-reconnect');

    // Drop the link, then bring it back with a peripheral that only offers the
    // default MTU. A stale 244-byte write size would corrupt every SysEx.
    transport.disconnectDevice(device);
    await Future<void>.delayed(const Duration(milliseconds: 5));

    fakePlatform.negotiatedMtu = 23;
    await connectDevice(transport, 'ble-mtu-reconnect');
    fakePlatform.writtenPackets.clear();

    transport.sendData(firmwareSysEx(), deviceId: 'ble-mtu-reconnect');
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(fakePlatform.writtenPackets, hasLength(8));
  });

  test('connection priority goes high on connect, balanced on '
      'disconnect', () async {
    final device = await connectDevice(transport, 'ble-priority');

    expect(fakePlatform.priorityRequests, <BleConnectionPriority>[
      BleConnectionPriority.highPerformance,
    ]);

    transport.disconnectDevice(device);
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(fakePlatform.priorityRequests, <BleConnectionPriority>[
      BleConnectionPriority.highPerformance,
      BleConnectionPriority.balanced,
    ]);
  });

  test(
    'requestHighPerformanceConnection: false requests no priority',
    () async {
      final relaxed = UniversalBleMidiTransport(
        requestHighPerformanceConnection: false,
      );
      final device = await connectDevice(relaxed, 'ble-priority-opt-out');
      relaxed.disconnectDevice(device);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(fakePlatform.priorityRequests, isEmpty);
      relaxed.teardown();
    },
  );

  test('overlapping sends do not interleave their SysEx packets', () async {
    fakePlatform.negotiatedMtu = 23; // Force multi-packet SysEx.
    fakePlatform.writeDelay = const Duration(milliseconds: 2);
    await connectDevice(transport, 'ble-interleave');
    fakePlatform.writtenPackets.clear();

    // Two SysEx messages sent back to back without awaiting the first, which
    // is what a bulk transfer paced by a timer does. Their BLE packets must
    // not interleave: the peripheral reassembles a SysEx statefully across
    // packets, so interleaving silently merges two messages into garbage.
    transport.sendData(firmwareSysEx(0x01), deviceId: 'ble-interleave');
    transport.sendData(firmwareSysEx(0x02), deviceId: 'ble-interleave');
    await Future<void>.delayed(const Duration(milliseconds: 200));

    // Every packet of the first message must precede every packet of the
    // second. Payload bytes carry the message marker.
    final markers = fakePlatform.writtenPackets
        .map((packet) => packet.contains(0x01) ? 1 : 2)
        .toList();
    final firstTwo = markers.indexOf(2);
    expect(firstTwo, greaterThan(0), reason: 'no packets for message 1');
    expect(
      markers.sublist(0, firstTwo).every((m) => m == 1),
      isTrue,
      reason: 'interleaved packet ordering: $markers',
    );
    expect(
      markers.sublist(firstTwo).every((m) => m == 2),
      isTrue,
      reason: 'interleaved packet ordering: $markers',
    );
  });

  test(
    'sendDataAwaitingDelivery completes only after the writes land',
    () async {
      fakePlatform.negotiatedMtu = 23;
      fakePlatform.writeDelay = const Duration(milliseconds: 2);
      await connectDevice(transport, 'ble-awaited');
      fakePlatform.writtenPackets.clear();

      final delivered = transport.sendDataAwaitingDelivery(
        firmwareSysEx(0x01),
        deviceId: 'ble-awaited',
      );
      expect(
        fakePlatform.writtenPackets.length,
        lessThan(8),
        reason: 'writes should still be in flight immediately after the call',
      );

      await delivered;
      expect(fakePlatform.writtenPackets, hasLength(8));
    },
  );

  test('a failed write is reported and the SysEx still completes', () async {
    fakePlatform.negotiatedMtu = 23;
    await connectDevice(transport, 'ble-write-fail');
    fakePlatform.failingWriteIds.add('ble-write-fail');
    fakePlatform.writtenPackets.clear();

    final failures = <MidiWriteFailure>[];
    final sub = transport.onWriteFailure.listen(failures.add);

    transport.sendData(firmwareSysEx(), deviceId: 'ble-write-fail');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await sub.cancel();

    // Every packet is still attempted: abandoning the rest of a SysEx would
    // leave the peripheral parsing a truncated message.
    expect(fakePlatform.writtenPackets, hasLength(8));
    expect(failures, hasLength(8));
    expect(failures.first.deviceId, 'ble-write-fail');
    expect(failures.first.error, isA<StateError>());
  });
}
