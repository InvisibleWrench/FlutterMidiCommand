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
    final firstDevice = _FakeAlsaMidiDevice(id: 'hw:1,0', name: 'First');
    final secondDevice = _FakeAlsaMidiDevice(id: 'hw:2,0', name: 'Second');
    final plugin = FlutterMidiCommandLinux(
      deviceDiscovery: () {
        discoveryCount += 1;
        return discoveryCount == 1 ? [firstDevice] : [secondDevice];
      },
    );

    final first = await plugin.devices;
    final second = await plugin.devices;

    expect(first.single.id, 'hw:1,0');
    expect(second.single.id, 'hw:2,0');
    expect(discoveryCount, 2);
  });

  test(
    'sendData targets deviceId when supplied and broadcasts otherwise',
    () async {
      final first = _FakeAlsaMidiDevice(id: 'hw:1,0');
      final second = _FakeAlsaMidiDevice(id: 'hw:2,0');
      final plugin = FlutterMidiCommandLinux(
        deviceDiscovery: () => [first, second],
      );
      final devices = await plugin.devices;

      await plugin.connectToDevice(devices[0]);
      await plugin.connectToDevice(devices[1]);

      plugin.sendData(
        Uint8List.fromList([0x90, 0x40, 0x7f]),
        deviceId: 'hw:2,0',
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
      final connectedAlsa = _FakeAlsaMidiDevice(id: 'hw:1,0');
      final refreshedAlsa = _FakeAlsaMidiDevice(id: 'hw:1,0');
      final plugin = FlutterMidiCommandLinux(
        deviceDiscovery: () => [connectedAlsa],
      );
      final device = (await plugin.devices).single;

      await plugin.connectToDevice(device);

      final refreshedDevice = LinuxMidiDevice.fromAlsaDevice(
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

  test('received data is emitted once and stops after disconnect', () async {
    final alsa = _FakeAlsaMidiDevice(id: 'hw:1,0');
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
    expect(packets.single.device.id, 'hw:1,0');

    plugin.disconnectDevice(device);
    await Future<void>.delayed(Duration.zero);
    alsa.emit([0x90, 0x41, 0x7f]);
    await Future<void>.delayed(Duration.zero);

    expect(packets, hasLength(1));
    await subscription.cancel();
  });

  test('reconnect does not duplicate received data subscriptions', () async {
    final alsa = _FakeAlsaMidiDevice(id: 'hw:1,0');
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
      final alsa = _FakeAlsaMidiDevice(id: 'hw:1,0');
      final plugin = FlutterMidiCommandLinux(deviceDiscovery: () => [alsa]);
      await plugin.connectToDevice((await plugin.devices).single);
      final setupDone = expectLater(
        plugin.onMidiSetupChanged!,
        emitsInOrder(<Object>['deviceDisconnected', emitsDone]),
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

class _FakeAlsaMidiDevice implements LinuxAlsaMidiDevice {
  _FakeAlsaMidiDevice({
    required this.id,
    this.name = 'Fake MIDI',
    List<String>? inputPorts,
    List<String>? outputPorts,
  }) : inputPorts = inputPorts ?? ['0'],
       outputPorts = outputPorts ?? ['0'];

  @override
  final String id;

  @override
  final int cardId = 1;

  @override
  final int deviceId = 0;

  @override
  final String name;

  @override
  final List<String> inputPorts;

  @override
  final List<String> outputPorts;

  final StreamController<LinuxAlsaMidiPacket> _receivedMessages =
      StreamController<LinuxAlsaMidiPacket>.broadcast();
  final List<List<int>> sentMessages = <List<int>>[];
  int connectCount = 0;
  int disconnectCount = 0;

  @override
  Stream<LinuxAlsaMidiPacket> get receivedMessages => _receivedMessages.stream;

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
    _receivedMessages.add(
      LinuxAlsaMidiPacket(Uint8List.fromList(data), timestamp),
    );
  }
}
