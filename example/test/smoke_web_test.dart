import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_midi_command_example/main.dart' as app;
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_midi_platform.dart';

void main() {
  setUp(() {
    MidiCommand.resetForTest();
  });

  testWidgets('web smoke: example app renders and connect/disconnect works', (
    tester,
  ) async {
    final fakePlatform = FakeMidiPlatform();
    MidiCommand.setPlatformOverride(fakePlatform);
    final device = fakePlatform.devicesList.first;

    app.runExampleApp(enableBle: false);
    await tester.pumpAndSettle();

    expect(find.text('FlutterMidiCommand Example'), findsOneWidget);
    expect(find.text('Transports'), findsOneWidget);
    expect(find.text('Discovery'), findsOneWidget);
    expect(find.text('Test Serial Device'), findsOneWidget);

    await tester.tap(find.text('Test Serial Device'));
    await tester.pumpAndSettle();
    expect(fakePlatform.connectedDeviceIds, contains('serial-1'));
    expect(device.connectionState, MidiConnectionState.connected);

    await tester.tap(find.text('Test Serial Device'));
    await tester.pumpAndSettle();
    expect(fakePlatform.disconnectedDeviceIds, contains('serial-1'));
    expect(device.connectionState, MidiConnectionState.disconnected);
  });
}
