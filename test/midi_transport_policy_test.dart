import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MidiTransportPolicy', () {
    test('defaults to all supported transports', () {
      const policy = MidiTransportPolicy();
      final result = policy.resolveEnabledTransports({
        MidiTransport.native,
        MidiTransport.ble,
      });

      expect(result, {MidiTransport.native, MidiTransport.ble});
    });

    test('can include only selected transports', () {
      const policy = MidiTransportPolicy(
        includedTransports: {MidiTransport.native},
      );

      final result = policy.resolveEnabledTransports({
        MidiTransport.native,
        MidiTransport.ble,
      });

      expect(result, {MidiTransport.native});
    });

    test('excluded transports are always removed', () {
      const policy = MidiTransportPolicy(
        excludedTransports: {MidiTransport.ble},
      );

      final result = policy.resolveEnabledTransports({
        MidiTransport.native,
        MidiTransport.ble,
      });

      expect(result, {MidiTransport.native});
    });

    test('unknown transports are ignored', () {
      const policy = MidiTransportPolicy(
        includedTransports: {MidiTransport.native, MidiTransport.network},
      );

      final result = policy.resolveEnabledTransports({MidiTransport.native});

      expect(result, {MidiTransport.native});
    });
  });

  group('MidiCapabilities', () {
    test('tracks supported and enabled transports', () {
      const capabilities = MidiCapabilities(
        supportedTransports: {MidiTransport.native, MidiTransport.ble},
        enabledTransports: {MidiTransport.native},
      );

      expect(capabilities.supports(MidiTransport.native), isTrue);
      expect(capabilities.supports(MidiTransport.virtual), isFalse);
      expect(capabilities.isEnabled(MidiTransport.native), isTrue);
      expect(capabilities.isEnabled(MidiTransport.ble), isFalse);
    });
  });

  group('MidiDeviceType', () {
    test('maps to and from wire values', () {
      expect(MidiDeviceType.serial.wireValue, 'native');
      expect(MidiDeviceType.ble.wireValue, 'BLE');

      expect(MidiDeviceTypeWire.fromWireValue('native'), MidiDeviceType.serial);
      expect(MidiDeviceTypeWire.fromWireValue('BLE'), MidiDeviceType.ble);
      expect(
        MidiDeviceTypeWire.fromWireValue('own-virtual'),
        MidiDeviceType.ownVirtual,
      );
    });
  });

  group('MidiConnectionState', () {
    test('updates per-device state stream', () async {
      final device = MidiDevice(
        'serial-1',
        'Serial',
        MidiDeviceType.serial,
        false,
      );
      final states = <MidiConnectionState>[];
      final sub = device.onConnectionStateChanged.listen(states.add);

      device.connected = true;
      device.setConnectionState(MidiConnectionState.disconnecting);
      device.connected = false;

      await Future<void>.delayed(const Duration(milliseconds: 10));
      await sub.cancel();
      device.dispose();

      expect(states, <MidiConnectionState>[
        MidiConnectionState.connected,
        MidiConnectionState.disconnecting,
        MidiConnectionState.disconnected,
      ]);
    });
  });
}
