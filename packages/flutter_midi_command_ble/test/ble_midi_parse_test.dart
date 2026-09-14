import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_midi_command_ble/flutter_midi_command_ble.dart';
import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';
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

/// A connected transport with its RX stream captured, in the same fake-platform
/// style as the tests above.
class _Rig {
  _Rig(this.fake, this.transport, this.device, this.received, this._sub);

  final _FakePlatform fake;
  final UniversalBleMidiTransport transport;
  final MidiDevice device;
  final List<List<int>> received;
  final StreamSubscription<MidiPacket> _sub;

  void emit(List<int> packet) => fake.emitValue('dev', packet);

  /// Lets the RX stream deliver, then stops listening.
  Future<List<List<int>>> settle() async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await _sub.cancel();
    return received;
  }
}

// ignore: library_private_types_in_public_api
Future<_Rig> connectRig() async {
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
  return _Rig(fake, transport, device, received, sub);
}

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
      [0xFE],
      reason:
          'a System Real-Time byte inside a SysEx is delivered on its own, '
          'rather than being dropped as it was before the two-stage rewrite',
    );
    expect(
      received[3],
      [0xF0, 0x01, 0x02, 0x03, 0x04, 0xF7],
      reason: 'Multi-packet SysEx must reassemble without framing/RT bytes',
    );
    expect(received, hasLength(4));
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

  group('BleMidiFramer', () {
    test('decodes a timestamp, including the header high bits', () {
      // header 0xBF -> high 0x3F, timestamp byte 0xFF -> low 0x7F.
      final runs = BleMidiFramer().parse([0xBF, 0xFF, 0x90, 0x3C, 0x64]);

      expect(runs, hasLength(1));
      expect(runs.single.timestamp, 0x3F << 7 | 0x7F);
      expect(runs.single.bytes, [0x90, 0x3C, 0x64]);
    });

    test('splits two timestamped runs in one packet', () {
      final runs = BleMidiFramer().parse([
        0x80, 0x80, 0x90, 0x3C, 0x64, //
        0x81, 0x90, 0x40, 0x7F,
      ]);

      expect(runs.map((r) => r.timestamp), [0, 1]);
      expect(runs.map((r) => r.bytes), [
        [0x90, 0x3C, 0x64],
        [0x90, 0x40, 0x7F],
      ]);
    });

    test('keeps a running-status run, which carries no timestamp, whole', () {
      final runs = BleMidiFramer().parse([
        0x80, 0x80, 0x90, 0x3C, 0x64, 0x40, 0x7F, //
      ]);

      expect(runs, hasLength(1));
      expect(runs.single.bytes, [0x90, 0x3C, 0x64, 0x40, 0x7F]);
    });

    test(
      'does not mistake a status byte after a timestamp for a timestamp',
      () {
        // 0xF0 and 0xF7 are both valid timestamp-byte values numerically.
        final runs = BleMidiFramer().parse([
          0x80,
          0x80,
          0xF0,
          0x01,
          0x80,
          0xF7,
        ]);

        expect(
          runs.map((r) => r.bytes),
          [
            [0xF0, 0x01],
            [0xF7],
          ],
          reason: 'the in-SysEx timestamp byte is framing, not payload',
        );
      },
    );

    test('carries a SysEx across a continuation packet with no timestamp', () {
      final framer = BleMidiFramer();

      expect(framer.parse([0x80, 0x80, 0xF0, 0x01, 0x02]).single.bytes, [
        0xF0,
        0x01,
        0x02,
      ]);
      expect(framer.parse([0x80, 0x03, 0x04]).single.bytes, [0x03, 0x04]);
      expect(framer.parse([0x80, 0x80, 0xF7]).single.bytes, [0xF7]);
    });

    test('passes a real-time byte inside a SysEx through', () {
      final framer = BleMidiFramer();
      framer.parse([0x80, 0x80, 0xF0, 0x01]);

      final runs = framer.parse([0x80, 0x02, 0x81, 0xFE, 0x03]);

      expect(runs.map((r) => r.bytes), [
        [0x02],
        [0xFE, 0x03],
      ]);
    });

    test('drops leading data bytes when no SysEx is open', () {
      expect(BleMidiFramer().parse([0x80, 0x40, 0x7F]), isEmpty);
    });

    test('ignores a packet too short to carry anything', () {
      expect(BleMidiFramer().parse([]), isEmpty);
      expect(BleMidiFramer().parse([0x80]), isEmpty);
    });

    test('reset clears the SysEx latch', () {
      final framer = BleMidiFramer();
      framer.parse([0x80, 0x80, 0xF0, 0x01]);
      framer.reset();

      expect(
        framer.parse([0x80, 0x02, 0x03]),
        isEmpty,
        reason: 'with no SysEx open these are stray data bytes',
      );
    });
  });

  group('BLE end-to-end', () {
    test('splits a running-status run into one message per note', () async {
      final rig = await connectRig();

      // Issue #179: an M-VAVE SMK-25 Mini sends two simultaneous notes as one
      // run under a single 0x90. Before the two-stage rewrite this produced
      // messages of 3, 4 and 5 bytes, each re-emitting the first note.
      rig.emit([0x80, 0x80, 0x90, 0x3C, 0x64, 0x40, 0x7F, 0x42, 0x50]);

      expect(
        await rig.settle(),
        [
          [0x90, 0x3C, 0x64],
          [0x90, 0x40, 0x7F],
          [0x90, 0x42, 0x50],
        ],
        reason:
            'https://github.com/InvisibleWrench/FlutterMidiCommand/issues/179',
      );
    });

    test('carries running status across two notifications', () async {
      final rig = await connectRig();

      rig.emit([0x80, 0x80, 0x90, 0x3C, 0x64]);
      rig.emit([0x80, 0x80, 0x40, 0x7F]);

      expect(
        await rig.settle(),
        [
          [0x90, 0x3C, 0x64],
          [0x90, 0x40, 0x7F],
        ],
        reason: 'the second notification used to arrive as [0x00, 0x40]',
      );
    });

    test('a real-time byte mid-message leaves the note intact', () async {
      final rig = await connectRig();

      // header, ts, 90 3C, ts, FE, 64 — the velocity arrives after the
      // interruption. The pending note used to be discarded by the 0xFE.
      rig.emit([0x80, 0x80, 0x90, 0x3C, 0x81, 0xFE, 0x64]);

      expect(await rig.settle(), [
        [0xFE],
        [0x90, 0x3C, 0x64],
      ]);
    });

    test('System Common clears running status', () async {
      final rig = await connectRig();

      rig.emit([
        0x80, 0x80, 0x90, 0x3C, 0x64, //
        0x81, 0xF1, 0x25, 0x40, 0x7F,
      ]);

      expect(await rig.settle(), [
        [0x90, 0x3C, 0x64],
        [0xF1, 0x25],
      ], reason: 'the trailing 40 7F has no status to revive');
    });

    test('an unterminated SysEx does not swallow later traffic', () async {
      final rig = await connectRig();

      rig.emit([0x80, 0x80, 0xF0, 0x01, 0x02]);
      rig.emit([0x80, 0x80, 0x90, 0x3C, 0x64]);

      expect(
        await rig.settle(),
        [
          [0xF0, 0x01, 0x02, 0xF7],
          [0x90, 0x3C, 0x64],
        ],
        reason: 'everything after an unterminated SysEx used to be lost',
      );
    });

    test('a partial message does not survive a disconnect', () async {
      final rig = await connectRig();

      rig.emit([0x80, 0x80, 0x90, 0x3C]);
      rig.transport.disconnectDevice(rig.device);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      rig.fake.emitScan('dev', 'GEWA');
      final device = (await rig.transport.devices).single;
      await rig.transport.connectToDevice(device);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      rig.emit([0x80, 0x80, 0x64, 0x7F]);

      expect(await rig.settle(), isEmpty);
    });
  });
}
