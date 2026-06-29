import 'dart:typed_data';

import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';
import 'package:flutter_midi_command_platform_interface/method_channel_midi_command.dart';
import 'package:flutter_midi_command_platform_interface/src/pigeon/midi_api.g.dart'
    as pigeon;
import 'package:flutter_test/flutter_test.dart';

class _FakeHostApi extends pigeon.MidiHostApi {
  List<pigeon.MidiHostDevice> listedDevices = <pigeon.MidiHostDevice>[];
  pigeon.MidiHostDevice? lastConnectDevice;
  List<pigeon.MidiPort>? lastConnectPorts;
  final List<String> disconnectCalls = <String>[];
  final List<pigeon.MidiPacket> sentPackets = <pigeon.MidiPacket>[];
  int teardownCalls = 0;
  int addVirtualCalls = 0;
  int removeVirtualCalls = 0;
  String? lastVirtualName;
  bool? networkEnabled = false;
  bool? setNetworkEnabledArg;

  @override
  Future<List<pigeon.MidiHostDevice>> listDevices() async => listedDevices;

  @override
  Future<void> connect(
    pigeon.MidiHostDevice device,
    List<pigeon.MidiPort>? ports,
  ) async {
    lastConnectDevice = device;
    lastConnectPorts = ports;
  }

  @override
  Future<void> disconnect(String deviceId) async {
    disconnectCalls.add(deviceId);
  }

  @override
  Future<void> teardown() async {
    teardownCalls += 1;
  }

  @override
  Future<void> sendData(pigeon.MidiPacket packet) async {
    sentPackets.add(packet);
  }

  @override
  Future<void> addVirtualDevice(String? name) async {
    addVirtualCalls += 1;
    lastVirtualName = name;
  }

  @override
  Future<void> removeVirtualDevice(String? name) async {
    removeVirtualCalls += 1;
    lastVirtualName = name;
  }

  @override
  Future<bool?> isNetworkSessionEnabled() async => networkEnabled;

  @override
  Future<void> setNetworkSessionEnabled(bool enabled) async {
    setNetworkEnabledArg = enabled;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    pigeon.MidiFlutterApi.setUp(null);
  });

  test('devices maps typed host devices and ports', () async {
    final host =
        _FakeHostApi()
          ..listedDevices = <pigeon.MidiHostDevice>[
            pigeon.MidiHostDevice(
              id: 'serial-1',
              name: 'Serial',
              type: pigeon.MidiDeviceType.serial,
              connected: true,
              inputs: <pigeon.MidiPort?>[
                pigeon.MidiPort(id: 0, connected: true, isInput: true),
              ],
              outputs: <pigeon.MidiPort?>[
                pigeon.MidiPort(id: 1, connected: false, isInput: false),
              ],
            ),
          ];
    final platform = MethodChannelMidiCommand(hostApi: host);

    final devices = await platform.devices;

    expect(devices, isNotNull);
    expect(devices!.length, 1);
    expect(devices.first.id, 'serial-1');
    expect(devices.first.name, 'Serial');
    expect(devices.first.type, MidiDeviceType.serial);
    expect(devices.first.connected, isTrue);
    expect(devices.first.inputPorts.first.id, 0);
    expect(devices.first.inputPorts.first.type, MidiPortType.IN);
    expect(devices.first.inputPorts.first.connected, isTrue);
    expect(devices.first.outputPorts.first.id, 1);
    expect(devices.first.outputPorts.first.type, MidiPortType.OUT);
    expect(devices.first.outputPorts.first.connected, isFalse);
  });

  test('devices prunes stale cached devices when host list changes', () async {
    final host =
        _FakeHostApi()
          ..listedDevices = <pigeon.MidiHostDevice>[
            pigeon.MidiHostDevice(
              id: 'serial-1',
              name: 'Serial',
              type: pigeon.MidiDeviceType.serial,
              connected: true,
            ),
          ];
    final platform = MethodChannelMidiCommand(hostApi: host);

    final firstList = await platform.devices;
    final device = firstList!.first;
    final states = <MidiConnectionState>[];
    final sub = device.onConnectionStateChanged.listen(states.add);
    expect(device.connected, isTrue);

    host.listedDevices = <pigeon.MidiHostDevice>[];
    final secondList = await platform.devices;

    await Future<void>.delayed(const Duration(milliseconds: 10));
    await sub.cancel();

    expect(secondList, isEmpty);
    expect(device.connected, isFalse);
    expect(states, contains(MidiConnectionState.disconnected));
  });

  test('pruning stale cache entries closes device state streams', () async {
    final host =
        _FakeHostApi()
          ..listedDevices = <pigeon.MidiHostDevice>[
            pigeon.MidiHostDevice(
              id: 'serial-1',
              name: 'Serial',
              type: pigeon.MidiDeviceType.serial,
              connected: true,
            ),
          ];
    final platform = MethodChannelMidiCommand(hostApi: host);

    final device = (await platform.devices)!.single;
    final done = expectLater(
      device.onConnectionStateChanged,
      emitsInOrder(<Object>[MidiConnectionState.disconnected, emitsDone]),
    );

    host.listedDevices = <pigeon.MidiHostDevice>[];
    await platform.devices;
    await done;
  });

  test(
    'connect forwards typed payload and connection callback updates same instance',
    () async {
      final host = _FakeHostApi();
      final platform = MethodChannelMidiCommand(hostApi: host);
      final device = MidiDevice(
        'serial-1',
        'Serial',
        MidiDeviceType.serial,
        false,
      );
      final port = MidiPort(3, MidiPortType.OUT)..connected = true;

      await platform.connectToDevice(device, ports: <MidiPort>[port]);

      expect(device.connectionState, MidiConnectionState.connecting);
      expect(host.lastConnectDevice, isNotNull);
      expect(host.lastConnectDevice!.id, 'serial-1');
      expect(host.lastConnectDevice!.type, pigeon.MidiDeviceType.serial);
      expect(host.lastConnectPorts, isNotNull);
      expect(host.lastConnectPorts!.length, 1);
      expect(host.lastConnectPorts!.first.id, 3);
      expect(host.lastConnectPorts!.first.connected, isTrue);
      expect(host.lastConnectPorts!.first.isInput, isFalse);

      platform.onDeviceConnectionStateChanged('serial-1', true);
      expect(device.connected, isTrue);
      expect(device.connectionState, MidiConnectionState.connected);
    },
  );

  test(
    'disconnect triggers host disconnect and transitions to disconnected',
    () async {
      final host = _FakeHostApi();
      final platform = MethodChannelMidiCommand(hostApi: host);
      final device = MidiDevice(
        'serial-1',
        'Serial',
        MidiDeviceType.serial,
        true,
      );

      platform.disconnectDevice(device);

      expect(device.connectionState, MidiConnectionState.disconnecting);
      await Future<void>.delayed(Duration.zero);

      expect(host.disconnectCalls, <String>['serial-1']);
      expect(device.connectionState, MidiConnectionState.disconnected);
    },
  );

  test('disconnect callback removes cached entry for that device', () async {
    final host =
        _FakeHostApi()
          ..listedDevices = <pigeon.MidiHostDevice>[
            pigeon.MidiHostDevice(
              id: 'serial-1',
              name: 'Serial',
              type: pigeon.MidiDeviceType.serial,
              connected: true,
            ),
          ];
    final platform = MethodChannelMidiCommand(hostApi: host);
    final device = (await platform.devices)!.first;
    expect(device.connected, isTrue);

    platform.onDeviceConnectionStateChanged('serial-1', false);
    expect(device.connected, isFalse);

    // If cache entry was removed, reconnect callback creates a new instance and
    // does not mutate the old stale one.
    platform.onDeviceConnectionStateChanged('serial-1', true);
    expect(device.connected, isFalse);
  });

  test('sendData serializes into typed packet payload', () async {
    final host = _FakeHostApi();
    final platform = MethodChannelMidiCommand(hostApi: host);
    final bytes = Uint8List.fromList(<int>[0x90, 0x3C, 0x64]);

    platform.sendData(bytes, deviceId: 'serial-1', timestamp: 42);
    platform.sendData(bytes);
    await Future<void>.delayed(Duration.zero);

    expect(host.sentPackets.length, 2);
    expect(host.sentPackets.first.data, bytes);
    expect(host.sentPackets.first.timestamp, 42);
    expect(host.sentPackets.first.device?.id, 'serial-1');
    expect(host.sentPackets.last.device, isNull);
  });

  test('Flutter callbacks forward setup and midi streams', () async {
    final host = _FakeHostApi();
    final platform = MethodChannelMidiCommand(hostApi: host);
    final setupEvents = <MidiSetupChange>[];
    final packets = <MidiPacket>[];

    final setupSub = platform.onMidiSetupChanged!.listen(setupEvents.add);
    final packetSub = platform.onMidiDataReceived!.listen(packets.add);

    platform.onSetupChanged(pigeon.MidiSetupChange.deviceAppeared);
    platform.onDataReceived(
      pigeon.MidiPacket(
        device: pigeon.MidiHostDevice(
          id: 'serial-1',
          name: 'Serial',
          type: pigeon.MidiDeviceType.serial,
          connected: true,
        ),
        data: Uint8List.fromList(<int>[0xF8]),
        timestamp: 7,
      ),
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));
    await setupSub.cancel();
    await packetSub.cancel();

    expect(setupEvents, <MidiSetupChange>[MidiSetupChange.deviceAppeared]);
    expect(packets.length, 1);
    expect(packets.first.data, Uint8List.fromList(<int>[0xF8]));
    expect(packets.first.timestamp, 7);
    expect(packets.first.device.id, 'serial-1');
    expect(packets.first.device.type, MidiDeviceType.serial);
  });

  test('virtual/network/teardown methods delegate to host api', () async {
    final host = _FakeHostApi()..networkEnabled = true;
    final platform = MethodChannelMidiCommand(hostApi: host);
    final connected = MidiDevice(
      'serial-1',
      'Serial',
      MidiDeviceType.serial,
      true,
    );

    await platform.connectToDevice(connected);
    platform.addVirtualDevice(name: 'Virtual');
    platform.removeVirtualDevice(name: 'Virtual');
    final networkEnabled = await platform.isNetworkSessionEnabled;
    platform.setNetworkSessionEnabled(false);
    platform.teardown();
    await Future<void>.delayed(Duration.zero);

    expect(host.addVirtualCalls, 1);
    expect(host.removeVirtualCalls, 1);
    expect(networkEnabled, isTrue);
    expect(host.setNetworkEnabledArg, isFalse);
    expect(host.teardownCalls, 1);
    expect(connected.connectionState, MidiConnectionState.disconnected);
  });

  test(
    'constructor throws root-isolate error for background message handler setup failures',
    () {
      expect(
        () => MethodChannelMidiCommand(
          hostApi: _FakeHostApi(),
          flutterApiSetUp: (_) {
            throw UnsupportedError(
              'Background isolates do not support setMessageHandler().',
            );
          },
        ),
        throwsA(isA<MidiCommandRootIsolateRequiredError>()),
      );
    },
  );
}
