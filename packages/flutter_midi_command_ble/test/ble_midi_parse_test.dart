import 'dart:typed_data';

import 'package:flutter_midi_command_ble/flutter_midi_command_ble.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

class _FakePlatform extends UniversalBlePlatform {
  final Map<String, List<BleService>> servicesByDevice = {};

  @override
  Future<AvailabilityState> getBluetoothAvailabilityState() async =>
      AvailabilityState.poweredOn;
  @override
  Future<bool> enableBluetooth() async => true;
  @override
  Future<bool> disableBluetooth() async => true;
  @override
  Future<void> startScan({
    ScanFilter? scanFilter,
    PlatformConfig? platformConfig,
  }) async {}
  @override
  Future<void> stopScan() async {}
  @override
  Future<bool> isScanning() async => false;
  @override
  Future<void> connect(
    String deviceId, {
    Duration? connectionTimeout,
    bool autoConnect = false,
    ConnectionPlatformConfig? platformConfig,
  }) async {
    updateConnection(deviceId, true);
  }

  @override
  Future<void> disconnect(String deviceId) async =>
      updateConnection(deviceId, false);
  @override
  Future<List<BleService>> discoverServices(
    String deviceId,
    bool withDescriptors,
  ) async => servicesByDevice[deviceId] ?? [];
  @override
  Future<void> setNotifiable(
    String d,
    String s,
    String c,
    BleInputProperty p,
  ) async {}
  @override
  Future<Uint8List> readValue(
    String d,
    String s,
    String c, {
    Duration? timeout,
  }) async => Uint8List(0);
  @override
  Future<void> writeValue(
    String d,
    String s,
    String c,
    Uint8List v,
    BleOutputProperty p,
  ) async {}
  @override
  Future<int> requestMtu(String d, int m) async => m;
  @override
  Future<int> readRssi(String d) async => 0;
  @override
  Future<void> requestConnectionPriority(
    String d,
    BleConnectionPriority p,
  ) async {}
  @override
  Future<bool> isPaired(String d) async => true;
  @override
  Future<bool> pair(String d) async => true;
  @override
  Future<void> unpair(String d) async {}
  @override
  Future<BleConnectionState> getConnectionState(String d) async =>
      BleConnectionState.connected;
  @override
  Future<List<BleDevice>> getSystemDevices(List<String>? withServices) async =>
      [];

  void emitValue(String deviceId, List<int> bytes) {
    updateCharacteristicValue(
      deviceId,
      midiCharacteristicId,
      Uint8List.fromList(bytes),
      null,
    );
  }

  void emitScan(String id, String name) =>
      updateScanResult(BleDevice(deviceId: id, name: name, services: const []));
}

List<BleService> midiServices() => [
  BleService(midiServiceId, [
    BleCharacteristic(midiCharacteristicId, const [
      CharacteristicProperty.read,
      CharacteristicProperty.notify,
    ], const []),
  ]),
];

void main() {
  test('BLE MIDI parse: channel message and short SysEx round-trip', () async {
    BleCapabilities.hasSystemPairingApi = true;
    final fake = _FakePlatform();
    UniversalBle.setInstance(fake);
    final transport = UniversalBleMidiTransport();

    fake.servicesByDevice['dev'] = midiServices();
    fake.emitScan('dev', 'GEWA');
    final device = (await transport.devices).single;
    await transport.connectToDevice(device);
    await Future<void>.delayed(const Duration(milliseconds: 5));

    final received = <List<int>>[];
    final sub = transport.onMidiDataReceived.listen(
      (p) => received.add(p.data.toList()),
    );

    // 1) Note On, ts=0: header=0x80, tsLow=0x80, 0x90 0x3C 0x64
    fake.emitValue('dev', [0x80, 0x80, 0x90, 0x3C, 0x64]);

    // 2) Short SysEx: header, ts, F0, 7E 7F 06 01, ts(0x80), F7
    fake.emitValue('dev', [
      0x80,
      0x80,
      0xF0,
      0x7E,
      0x7F,
      0x06,
      0x01,
      0x80,
      0xF7,
    ]);

    // 3) SysEx split across two BLE packets, with an interrupting active-sensing
    //    (0xFE) system-real-time byte in the middle.
    //    packet A: header, ts, F0, 01 02, ts(0x80), FE  (0xFE interrupts sysex)
    fake.emitValue('dev', [0x80, 0x80, 0xF0, 0x01, 0x02, 0x80, 0xFE]);
    //    packet B: header, 03 04, ts(0x80), F7
    fake.emitValue('dev', [0x80, 0x03, 0x04, 0x80, 0xF7]);

    await Future<void>.delayed(const Duration(milliseconds: 10));
    await sub.cancel();

    expect(received[0], [0x90, 0x3C, 0x64], reason: 'Note On');
    expect(
      received[1],
      [0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7],
      reason: 'SysEx must NOT contain the BLE timestamp byte 0x80 before F7',
    );
    expect(
      received[2],
      [0xF0, 0x01, 0x02, 0x03, 0x04, 0xF7],
      reason: 'Multi-packet SysEx must reassemble without framing/RT bytes',
    );
  });

  test('buildBleMidiSysExPackets respects the write size and framing', () {
    for (final writeSize in <int>[20, 23, 100, 244]) {
      for (var bodyLength = 0; bodyLength <= 300; bodyLength++) {
        final sysEx = <int>[
          0xF0,
          ...List<int>.generate(bodyLength, (i) => i % 0x80),
          0xF7,
        ];
        final packets = buildBleMidiSysExPackets(sysEx, writeSize);

        expect(packets, isNotEmpty, reason: 'w=$writeSize b=$bodyLength');
        for (final packet in packets) {
          expect(
            packet.length,
            lessThanOrEqualTo(writeSize),
            reason: 'packet exceeds the MTU: w=$writeSize b=$bodyLength',
          );
          expect(
            packet.first,
            0x80,
            reason: 'every packet opens with a header byte',
          );
        }
        // The closing 0xF7 must always be preceded by a timestamp byte. The
        // previous chunker dropped it whenever the remainder was exactly
        // writeSize - 1 bytes.
        final last = packets.last;
        expect(last.last, 0xF7, reason: 'w=$writeSize b=$bodyLength');
        expect(
          last[last.length - 2],
          0x80,
          reason: 'missing timestamp before F7: w=$writeSize b=$bodyLength',
        );
      }
    }
  });

  test(
    'BLE MIDI SysEx survives a chunk/parse round-trip at any size',
    () async {
      BleCapabilities.hasSystemPairingApi = true;
      final fake = _FakePlatform();
      UniversalBle.setInstance(fake);
      final transport = UniversalBleMidiTransport();

      fake.servicesByDevice['dev'] = midiServices();
      fake.emitScan('dev', 'GEWA');
      final device = (await transport.devices).single;
      await transport.connectToDevice(device);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      final received = <List<int>>[];
      final sub = transport.onMidiDataReceived.listen(
        (p) => received.add(p.data.toList()),
      );

      // Sweep every body length across the packet boundaries of several write
      // sizes, feeding the chunker's own output back through the parser.
      final expected = <List<int>>[];
      for (final writeSize in <int>[20, 23, 100, 244]) {
        for (var bodyLength = 0; bodyLength <= 200; bodyLength++) {
          final sysEx = <int>[
            0xF0,
            ...List<int>.generate(bodyLength, (i) => i % 0x80),
            0xF7,
          ];
          expected.add(sysEx);
          for (final packet in buildBleMidiSysExPackets(sysEx, writeSize)) {
            fake.emitValue('dev', packet);
          }
        }
      }

      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();

      expect(received, hasLength(expected.length));
      for (var i = 0; i < expected.length; i++) {
        expect(received[i], expected[i], reason: 'round-trip mismatch at $i');
      }
    },
  );
}
