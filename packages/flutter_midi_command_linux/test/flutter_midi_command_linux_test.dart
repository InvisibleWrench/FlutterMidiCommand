import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_midi_command_linux/flutter_midi_command_linux.dart';
import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('registerWith installs linux platform implementation', () {
    FlutterMidiCommandLinux.registerWith();
    expect(MidiCommandPlatform.instance, isA<FlutterMidiCommandLinux>());
  });

  test('linux plugin exposes streams and no-op optional APIs', () async {
    final plugin = FlutterMidiCommandLinux(deviceDiscovery: () => []);

    expect(plugin.onMidiDataReceived, isNotNull);
    expect(plugin.onMidiSetupChanged, isNotNull);
    expect(
      () => plugin.addVirtualDevice(name: 'Test Virtual'),
      returnsNormally,
    );
    expect(
      () => plugin.removeVirtualDevice(name: 'Test Virtual'),
      returnsNormally,
    );
    expect(await plugin.isNetworkSessionEnabled, isNull);
    expect(() => plugin.setNetworkSessionEnabled(true), returnsNormally);
  });

  test('devices refreshes discovery on each call', () async {
    var discoveryCount = 0;
    final firstDevice = _FakeLinuxMidiPortDevice(id: 'aseq:1:0', name: 'First');
    final secondDevice = _FakeLinuxMidiPortDevice(
      id: 'aseq:2:0',
      name: 'Second',
    );
    final plugin = FlutterMidiCommandLinux(
      deviceDiscovery: () {
        discoveryCount += 1;
        return discoveryCount == 1 ? [firstDevice] : [secondDevice];
      },
    );

    final first = await plugin.devices;
    final second = await plugin.devices;

    expect(first.single.id, 'aseq:1:0');
    expect(second.single.id, 'aseq:2:0');
    expect(discoveryCount, 2);
  });

  test('per-port discovery exposes separate logical devices', () async {
    final plugin = FlutterMidiCommandLinux(
      deviceDiscovery:
          () => [
            _FakeLinuxMidiPortDevice(id: 'aseq:20:0', name: 'Interface [1]'),
            _FakeLinuxMidiPortDevice(id: 'aseq:20:1', name: 'Interface [2]'),
          ],
    );

    final devices = await plugin.devices;

    expect(devices.map((device) => device.id), <String>[
      'aseq:20:0',
      'aseq:20:1',
    ]);
    expect(devices.every((device) => device.inputPorts.length == 1), isTrue);
    expect(devices.every((device) => device.outputPorts.length == 1), isTrue);
  });

  test('input-only and output-only ports keep their direction', () async {
    final plugin = FlutterMidiCommandLinux(
      deviceDiscovery:
          () => [
            _FakeLinuxMidiPortDevice(
              id: 'aseq:20:0',
              hasInput: true,
              hasOutput: false,
            ),
            _FakeLinuxMidiPortDevice(
              id: 'aseq:20:1',
              hasInput: false,
              hasOutput: true,
            ),
          ],
    );

    final devices = await plugin.devices;

    expect(devices[0].inputPorts, hasLength(1));
    expect(devices[0].outputPorts, isEmpty);
    expect(devices[1].inputPorts, isEmpty);
    expect(devices[1].outputPorts, hasLength(1));
  });

  test(
    'sendData targets deviceId when supplied and broadcasts otherwise',
    () async {
      final first = _FakeLinuxMidiPortDevice(id: 'aseq:1:0');
      final second = _FakeLinuxMidiPortDevice(id: 'aseq:2:0');
      final plugin = FlutterMidiCommandLinux(
        deviceDiscovery: () => [first, second],
      );
      final devices = await plugin.devices;

      await plugin.connectToDevice(devices[0]);
      await plugin.connectToDevice(devices[1]);

      plugin.sendData(
        Uint8List.fromList([0x90, 0x40, 0x7f]),
        deviceId: 'aseq:2:0',
      );
      expect(first.sentMessages, isEmpty);
      expect(second.sentMessages, [
        [0x90, 0x40, 0x7f],
      ]);

      plugin.sendData(Uint8List.fromList([0x80, 0x40, 0x00]));
      expect(first.sentMessages, [
        [0x80, 0x40, 0x00],
      ]);
      expect(second.sentMessages, [
        [0x90, 0x40, 0x7f],
        [0x80, 0x40, 0x00],
      ]);
    },
  );

  test(
    'disconnect uses the stored connected wrapper for matching ids',
    () async {
      final connectedAlsa = _FakeLinuxMidiPortDevice(id: 'aseq:1:0');
      final refreshedAlsa = _FakeLinuxMidiPortDevice(id: 'aseq:1:0');
      final plugin = FlutterMidiCommandLinux(
        deviceDiscovery: () => [connectedAlsa],
      );
      final device = (await plugin.devices).single;

      await plugin.connectToDevice(device);

      final refreshedDevice = LinuxMidiDevice.fromPortDevice(
        refreshedAlsa,
        MidiDeviceType.serial,
        StreamController<MidiPacket>.broadcast(),
        true,
      );
      plugin.disconnectDevice(refreshedDevice);
      await Future<void>.delayed(Duration.zero);

      expect(connectedAlsa.disconnectCount, 1);
      expect(refreshedAlsa.disconnectCount, 0);
    },
  );

  test(
    'monitor emits setup events only after device snapshot changes',
    () async {
      final monitor = StreamController<void>.broadcast();
      var discovered = <_FakeLinuxMidiPortDevice>[];
      final plugin = FlutterMidiCommandLinux(
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

      discovered = [_FakeLinuxMidiPortDevice(id: 'aseq:1:0')];
      monitor.add(null);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(events, [MidiSetupChange.deviceAppeared]);

      discovered = [];
      monitor.add(null);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(events, [
        MidiSetupChange.deviceAppeared,
        MidiSetupChange.deviceDisappeared,
      ]);

      await subscription.cancel();
      await monitor.close();
    },
  );

  test('monitor coalesces multiple hotplug signals into one refresh', () async {
    final monitor = StreamController<void>.broadcast();
    var discoveryCount = 0;
    var discovered = <_FakeLinuxMidiPortDevice>[];
    final plugin = FlutterMidiCommandLinux(
      deviceDiscovery: () {
        discoveryCount += 1;
        return discovered;
      },
      deviceMonitor: () => monitor.stream,
      deviceMonitorDebounce: Duration.zero,
    );
    final events = <MidiSetupChange>[];
    final subscription = plugin.onMidiSetupChanged!.listen(events.add);

    discovered = [_FakeLinuxMidiPortDevice(id: 'aseq:1:0')];
    monitor
      ..add(null)
      ..add(null)
      ..add(null);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(events, [MidiSetupChange.deviceAppeared]);
    expect(discoveryCount, 2);

    await subscription.cancel();
    await monitor.close();
  });

  test(
    'monitor removes disconnected hardware from connected devices',
    () async {
      final monitor = StreamController<void>.broadcast();
      final alsa = _FakeLinuxMidiPortDevice(id: 'aseq:1:0');
      var discovered = <_FakeLinuxMidiPortDevice>[alsa];
      final plugin = FlutterMidiCommandLinux(
        deviceDiscovery: () => discovered,
        deviceMonitor: () => monitor.stream,
        deviceMonitorDebounce: Duration.zero,
      );
      final setupEvents = <MidiSetupChange>[];
      final setupSubscription = plugin.onMidiSetupChanged!.listen(
        setupEvents.add,
      );
      final packets = <MidiPacket>[];
      final dataSubscription = plugin.onMidiDataReceived!.listen(packets.add);
      final device = (await plugin.devices).single;

      await plugin.connectToDevice(device);
      discovered = [];
      monitor.add(null);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      alsa.emit([0x90, 0x40, 0x7f]);
      await Future<void>.delayed(Duration.zero);

      expect(setupEvents, [
        MidiSetupChange.deviceConnected,
        MidiSetupChange.deviceDisappeared,
      ]);
      expect(alsa.disconnectCount, 1);
      expect(packets, isEmpty);

      await setupSubscription.cancel();
      await dataSubscription.cancel();
      await monitor.close();
    },
  );

  test('received data is emitted once and stops after disconnect', () async {
    final alsa = _FakeLinuxMidiPortDevice(id: 'aseq:1:0');
    final plugin = FlutterMidiCommandLinux(deviceDiscovery: () => [alsa]);
    final device = (await plugin.devices).single;
    final packets = <MidiPacket>[];
    final subscription = plugin.onMidiDataReceived!.listen(packets.add);

    await plugin.connectToDevice(device);
    alsa.emit([0x90, 0x40, 0x7f], timestamp: 123);
    await Future<void>.delayed(Duration.zero);

    expect(packets, hasLength(1));
    expect(packets.single.data, [0x90, 0x40, 0x7f]);
    expect(packets.single.timestamp, 123);
    expect(packets.single.device.id, 'aseq:1:0');

    plugin.disconnectDevice(device);
    await Future<void>.delayed(Duration.zero);
    alsa.emit([0x90, 0x41, 0x7f]);
    await Future<void>.delayed(Duration.zero);

    expect(packets, hasLength(1));
    await subscription.cancel();
  });

  test('reconnect does not duplicate received data subscriptions', () async {
    final alsa = _FakeLinuxMidiPortDevice(id: 'aseq:1:0');
    final plugin = FlutterMidiCommandLinux(deviceDiscovery: () => [alsa]);
    final device = (await plugin.devices).single;
    final packets = <MidiPacket>[];
    final subscription = plugin.onMidiDataReceived!.listen(packets.add);

    await plugin.connectToDevice(device);
    plugin.disconnectDevice(device);
    await Future<void>.delayed(Duration.zero);
    await plugin.connectToDevice(device);

    alsa.emit([0x90, 0x40, 0x7f]);
    await Future<void>.delayed(Duration.zero);

    expect(alsa.connectCount, 2);
    expect(packets, hasLength(1));
    await subscription.cancel();
  });

  test(
    'teardown disconnects devices and closes setup and data streams',
    () async {
      final alsa = _FakeLinuxMidiPortDevice(id: 'aseq:1:0');
      final plugin = FlutterMidiCommandLinux(
        deviceDiscovery: () => [alsa],
        deviceMonitor: () => const Stream<void>.empty(),
      );
      await plugin.connectToDevice((await plugin.devices).single);
      final setupDone = expectLater(
        plugin.onMidiSetupChanged!,
        emitsInOrder(<Object>[MidiSetupChange.deviceDisconnected, emitsDone]),
      );
      final dataDone = expectLater(plugin.onMidiDataReceived!, emitsDone);

      plugin.teardown();

      await Future<void>.delayed(Duration.zero);
      expect(alsa.disconnectCount, 1);
      await setupDone;
      await dataDone;
    },
  );
}

class _FakeLinuxMidiPortDevice implements LinuxMidiPortDevice {
  _FakeLinuxMidiPortDevice({
    required this.id,
    this.name = 'Fake MIDI',
    this.hasInput = true,
    this.hasOutput = true,
  });

  @override
  final String id;

  @override
  @override
  final String name;

  @override
  final bool hasInput;

  @override
  final bool hasOutput;

  final StreamController<LinuxMidiPacket> _receivedMessages =
      StreamController<LinuxMidiPacket>.broadcast();
  final List<List<int>> sentMessages = <List<int>>[];
  int connectCount = 0;
  int disconnectCount = 0;

  @override
  Stream<LinuxMidiPacket> get receivedMessages => _receivedMessages.stream;

  @override
  Future<bool> connect() async {
    connectCount += 1;
    return true;
  }

  @override
  void send(Uint8List midiMessage) {
    sentMessages.add(midiMessage.toList());
  }

  @override
  Future<void> disconnect() async {
    disconnectCount += 1;
  }

  void emit(List<int> data, {int timestamp = 0}) {
    _receivedMessages.add(LinuxMidiPacket(Uint8List.fromList(data), timestamp));
  }
}
