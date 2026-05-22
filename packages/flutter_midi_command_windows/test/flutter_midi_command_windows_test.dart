import 'dart:async';

import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';
import 'package:flutter_midi_command_windows/flutter_midi_command_windows.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win32/win32.dart';

void main() {
  test('midiErrorMessage maps known WinMM status codes', () {
    expect(midiErrorMessage(MMSYSERR_ALLOCATED), 'Resource already allocated');
    expect(midiErrorMessage(MMSYSERR_BADDEVICEID), 'Device ID out of range');
    expect(midiErrorMessage(MMSYSERR_INVALFLAG), 'Invalid dwFlags');
    expect(
      midiErrorMessage(MMSYSERR_INVALPARAM),
      'Invalid pointer or structure',
    );
    expect(midiErrorMessage(MMSYSERR_NOMEM), 'Unable to allocate memory');
    expect(midiErrorMessage(MMSYSERR_INVALHANDLE), 'Invalid handle');
  });

  test('midiErrorMessage falls back for unknown status', () {
    expect(midiErrorMessage(-12345), 'Status -12345');
  });

  test('device monitor emits semantic events from snapshot changes', () async {
    final monitor = StreamController<void>.broadcast();
    var discovered = <MidiDevice>[];
    final plugin = FlutterMidiCommandWindows(
      deviceDiscovery: () => discovered,
      deviceMonitor: () => monitor.stream,
      deviceMonitorDebounce: Duration.zero,
    );
    final events = <MidiSetupChange>[];
    final subscription = plugin.onMidiSetupChanged!.listen(events.add);

    monitor.add(null);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty);

    discovered = <MidiDevice>[_device('keys')];
    monitor.add(null);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(events, <MidiSetupChange>[MidiSetupChange.deviceAppeared]);

    discovered = <MidiDevice>[_device('keys', name: 'Keys MkII')];
    monitor.add(null);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(events, <MidiSetupChange>[
      MidiSetupChange.deviceAppeared,
      MidiSetupChange.deviceStateChanged,
    ]);

    discovered = <MidiDevice>[];
    monitor.add(null);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(events, <MidiSetupChange>[
      MidiSetupChange.deviceAppeared,
      MidiSetupChange.deviceStateChanged,
      MidiSetupChange.deviceDisappeared,
    ]);

    await subscription.cancel();
    await monitor.close();
  });
}

MidiDevice _device(String id, {String name = 'Keys'}) {
  return MidiDevice(id, name, MidiDeviceType.serial, false)
    ..inputPorts = <MidiPort>[MidiPort(0, MidiPortType.IN)]
    ..outputPorts = <MidiPort>[MidiPort(0, MidiPortType.OUT)];
}
