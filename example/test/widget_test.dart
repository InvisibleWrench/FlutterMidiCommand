import 'package:flutter/material.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_midi_command_example/main.dart' as app;
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_ble_transport.dart';
import 'support/fake_midi_platform.dart';

void main() {
  setUp(() {
    MidiCommand.resetForTest();
  });

  testWidgets(
    'example separates device refresh from BLE scanning and exposes transport toggles',
    (tester) async {
      final fakePlatform = FakeMidiPlatform(networkEnabled: false);
      final fakeBleTransport = FakeBleTransport();
      MidiCommand.setPlatformOverride(fakePlatform);

      app.runExampleApp(
        enableBle: true,
        bleTransport: fakeBleTransport,
      );
      await tester.pumpAndSettle();

      expect(find.text('Transports'), findsOneWidget);
      expect(find.text('Discovery'), findsOneWidget);
      expect(find.text('Test Serial Device'), findsOneWidget);
      expect(find.text('Test BLE Device'), findsNothing);

      final initialDeviceCalls = fakePlatform.devicesCallCount;
      await tester.tap(find.text('Refresh Devices'));
      await tester.pumpAndSettle();
      expect(fakePlatform.devicesCallCount, greaterThan(initialDeviceCalls));
      expect(fakeBleTransport.startScanCallCount, 0);

      await tester.tap(find.text('Scan BLE'));
      await tester.pumpAndSettle();
      expect(find.text('Ok. I got it!'), findsOneWidget);

      await tester.tap(find.text('Ok. I got it!'));
      await tester.pumpAndSettle();
      expect(fakeBleTransport.startBluetoothCallCount, 1);
      expect(fakeBleTransport.startScanCallCount, 1);
      expect(find.text('Test BLE Device'), findsOneWidget);

      await tester.tap(find.byType(Switch).at(0));
      await tester.pumpAndSettle();
      expect(fakePlatform.networkEnabledChanges, contains(true));

      await tester.tap(find.byType(Switch).at(1));
      await tester.pumpAndSettle();
      expect(
        fakePlatform.addedVirtualDeviceNames,
        contains('Flutter MIDI Command'),
      );
    },
  );
}
