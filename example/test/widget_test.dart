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
    'example separates discovery, shows transport badges, quick send, and raw monitor',
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
      expect(find.text('Native'), findsOneWidget);
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
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
      expect(fakeBleTransport.startBluetoothCallCount, 1);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Switch).at(0));
      await tester.pumpAndSettle();
      expect(fakePlatform.networkEnabledChanges, contains(true));

      await tester.tap(find.byType(Switch).at(1));
      await tester.pumpAndSettle();
      expect(
        fakePlatform.addedVirtualDeviceNames,
        contains('Flutter MIDI Command'),
      );

      await tester.tap(find.text('Test Serial Device'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Send test note'), findsOneWidget);

      await tester.tap(find.byTooltip('Send test note'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(fakePlatform.sentMessages.length, 2);
      expect(fakePlatform.sentDeviceIds, <String?>['serial-1', 'serial-1']);

      await tester.longPress(find.text('Test Serial Device'));
      await tester.pumpAndSettle();
      expect(find.text('Test Serial Device'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Raw MIDI Monitor'),
        300,
      );
      expect(find.text('Raw MIDI Monitor'), findsOneWidget);

      fakePlatform.emitPacket(
        'serial-1',
        <int>[0x90, 0x3C, 0x64],
        timestamp: 42,
      );
      await tester.pump();

      await tester.tap(find.text('Raw MIDI Monitor'));
      await tester.pumpAndSettle();
      expect(find.textContaining('90 3C 64'), findsOneWidget);
    },
  );

  test('connectionErrorMessage handles typed MIDI connection errors', () {
    expect(
      app.connectionErrorMessage(
        MidiConnectionTimeoutException(
          deviceId: 'serial-1',
          stage: MidiConnectionStage.connectionState,
          timeout: const Duration(milliseconds: 25),
        ),
      ),
      contains('Timed out after 25 ms'),
    );
  });
}
