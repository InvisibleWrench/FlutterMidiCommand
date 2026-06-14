import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';
import 'package:flutter_midi_command_windows/src/windows_device_discovery.dart';
import 'package:flutter_midi_command_windows/flutter_midi_command_windows.dart';
import 'package:flutter_midi_command_windows/windows_midi_device.dart';
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

  test('buildWindowsMidiDevices pairs balanced multi-port endpoints', () {
    final rxStreamController = StreamController<MidiPacket>.broadcast();
    final setupStreamController = StreamController<MidiSetupChange>.broadcast();

    final devices = buildWindowsMidiDevices(
      inputs: const <WindowsMidiEndpointDescriptor>[
        WindowsMidiEndpointDescriptor(id: 0, name: 'Controller'),
        WindowsMidiEndpointDescriptor(id: 1, name: 'MIDIIN2 (Controller)'),
        WindowsMidiEndpointDescriptor(id: 2, name: 'MIDIIN3 (Controller)'),
      ],
      outputs: const <WindowsMidiEndpointDescriptor>[
        WindowsMidiEndpointDescriptor(id: 10, name: 'Controller'),
        WindowsMidiEndpointDescriptor(id: 11, name: 'MIDIOUT2 (Controller)'),
        WindowsMidiEndpointDescriptor(id: 12, name: 'MIDIOUT3 (Controller)'),
      ],
      rxStreamController: rxStreamController,
      setupStreamController: setupStreamController,
      callbackAddress: 0,
    );

    expect(devices, hasLength(3));
    expect(devices.map((device) => device.name), <String>[
      'Controller',
      'Controller (1)',
      'Controller (2)',
    ]);
    expect(
      devices.every(
        (device) =>
            device.inputPorts.length == 1 && device.outputPorts.length == 1,
      ),
      isTrue,
    );

    rxStreamController.close();
    setupStreamController.close();
  });

  test('buildWindowsMidiDevices keeps unmatched extra endpoints unpaired', () {
    final rxStreamController = StreamController<MidiPacket>.broadcast();
    final setupStreamController = StreamController<MidiSetupChange>.broadcast();

    final devices = buildWindowsMidiDevices(
      inputs: const <WindowsMidiEndpointDescriptor>[
        WindowsMidiEndpointDescriptor(id: 0, name: 'Controller'),
        WindowsMidiEndpointDescriptor(id: 1, name: 'MIDIIN2 (Controller)'),
      ],
      outputs: const <WindowsMidiEndpointDescriptor>[
        WindowsMidiEndpointDescriptor(id: 10, name: 'Controller'),
      ],
      rxStreamController: rxStreamController,
      setupStreamController: setupStreamController,
      callbackAddress: 0,
    );

    expect(devices, hasLength(2));
    expect(devices[0].inputPorts, hasLength(1));
    expect(devices[0].outputPorts, hasLength(1));
    expect(devices[1].inputPorts, hasLength(1));
    expect(devices[1].outputPorts, isEmpty);

    rxStreamController.close();
    setupStreamController.close();
  });

  test('normalizeWindowsMidiEndpointName strips WinMM direction prefixes', () {
    expect(
      normalizeWindowsMidiEndpointName('MIDIIN2 (Controller)'),
      'Controller',
    );
    expect(
      normalizeWindowsMidiEndpointName('MIDIOUT3 (Controller)'),
      'Controller',
    );
    expect(
      normalizeWindowsMidiEndpointName('Output: Controller'),
      'Controller',
    );
  });

  test('buildWindowsMidiDevices preserves connected state by generated id', () {
    final rxStreamController = StreamController<MidiPacket>.broadcast();
    final setupStreamController = StreamController<MidiSetupChange>.broadcast();

    final devices = buildWindowsMidiDevices(
      inputs: const <WindowsMidiEndpointDescriptor>[
        WindowsMidiEndpointDescriptor(id: 0, name: 'Controller'),
        WindowsMidiEndpointDescriptor(id: 1, name: 'MIDIIN2 (Controller)'),
      ],
      outputs: const <WindowsMidiEndpointDescriptor>[
        WindowsMidiEndpointDescriptor(id: 10, name: 'Controller'),
        WindowsMidiEndpointDescriptor(id: 11, name: 'MIDIOUT2 (Controller)'),
      ],
      rxStreamController: rxStreamController,
      setupStreamController: setupStreamController,
      callbackAddress: 0,
      connectedDeviceIds: const <String>{'Controller (1)'},
    );

    expect(devices[0].connected, isFalse);
    expect(devices[1].connected, isTrue);

    rxStreamController.close();
    setupStreamController.close();
  });

  test(
    'disconnectDevice emits deviceDisconnected after successful teardown',
    () async {
      final monitor = StreamController<void>.broadcast();
      final plugin = FlutterMidiCommandWindows(
        deviceDiscovery: () => <MidiDevice>[],
        deviceMonitor: () => monitor.stream,
        deviceMonitorDebounce: Duration.zero,
      );
      final events = <MidiSetupChange>[];
      final subscription = plugin.onMidiSetupChanged!.listen(events.add);
      final device = _FakeWindowsMidiDevice('keys');

    await plugin.connectToDevice(device);
    plugin.disconnectDevice(device);
    await Future<void>.delayed(Duration.zero);

    expect(device.connectCalls, 1);
    expect(device.disconnectCalls, 1);
      expect(events, <MidiSetupChange>[MidiSetupChange.deviceDisconnected]);

      await subscription.cancel();
      await monitor.close();
    },
  );

  test(
    'disconnectDevice restores device registration when teardown fails',
    () async {
      final monitor = StreamController<void>.broadcast();
      final plugin = FlutterMidiCommandWindows(
        deviceDiscovery: () => <MidiDevice>[],
        deviceMonitor: () => monitor.stream,
        deviceMonitorDebounce: Duration.zero,
      );
      final subscription = plugin.onMidiSetupChanged!.listen((_) {});
      final device = _FakeWindowsMidiDevice('keys', disconnectResult: false);

      await plugin.connectToDevice(device);
      plugin.disconnectDevice(device);
      plugin.sendData(
        Uint8List.fromList(<int>[0x90, 60, 100]),
        deviceId: 'keys',
      );

      expect(device.disconnectCalls, 1);
      expect(device.sendCalls, 1);

      await subscription.cancel();
      await monitor.close();
    },
  );
}

MidiDevice _device(String id, {String name = 'Keys'}) {
  return MidiDevice(id, name, MidiDeviceType.serial, false)
    ..inputPorts = <MidiPort>[MidiPort(0, MidiPortType.IN)]
    ..outputPorts = <MidiPort>[MidiPort(0, MidiPortType.OUT)];
}

class _FakeWindowsMidiDevice extends WindowsMidiDevice {
  _FakeWindowsMidiDevice(String id, {this.disconnectResult = true})
    : super(
        id,
        'Keys',
        StreamController<MidiPacket>.broadcast(),
        StreamController<MidiSetupChange>.broadcast(),
        0,
      );

  final bool disconnectResult;
  int connectCalls = 0;
  int disconnectCalls = 0;
  int sendCalls = 0;

  @override
  bool connect() {
    connectCalls += 1;
    connected = true;
    return true;
  }

  @override
  bool disconnect() {
    disconnectCalls += 1;
    connected = false;
    return disconnectResult;
  }

  @override
  void send(Uint8List data) {
    sendCalls += 1;
  }
}
