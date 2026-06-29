import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_midi_command_ble/flutter_midi_command_ble.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';

import 'controller.dart';

void main() => runExampleApp(enableBle: !kIsWeb);

void runExampleApp({
  bool enableBle = true,
  MidiCommand? midiCommand,
  MidiBleTransport? bleTransport,
}) {
  runApp(
    MyApp(
      enableBle: enableBle,
      midiCommand: midiCommand,
      bleTransport: bleTransport,
    ),
  );
}

class MyApp extends StatefulWidget {
  const MyApp({
    super.key,
    this.enableBle = true,
    this.midiCommand,
    this.bleTransport,
  });

  final bool enableBle;
  final MidiCommand? midiCommand;
  final MidiBleTransport? bleTransport;

  @override
  MyAppState createState() => MyAppState();
}

class MyAppState extends State<MyApp> {
  StreamSubscription<MidiSetupChange>? _setupSubscription;
  StreamSubscription<BluetoothState>? _bluetoothStateSubscription;
  late final MidiCommand _midiCommand;

  bool _bleTransportEnabled = false;
  bool _virtualDeviceActivated = false;
  bool _networkTransportSupported = true;
  bool _networkTransportEnabled = false;
  bool _loadingDevices = true;
  bool _scanningBleDevices = false;
  int _deviceRefreshGeneration = 0;
  List<MidiDevice> _devices = <MidiDevice>[];

  bool _didAskForBluetoothPermissions = false;

  @override
  void initState() {
    super.initState();
    _midiCommand = widget.midiCommand ?? MidiCommand();
    _bleTransportEnabled = widget.enableBle;

    if (widget.enableBle) {
      _midiCommand.configureBleTransport(
        widget.bleTransport ?? UniversalBleMidiTransport(),
      );
    } else {
      _midiCommand.configureBleTransport(null);
    }

    _setupSubscription = _midiCommand.onMidiSetupChanged?.listen((data) async {
      if (kDebugMode) {
        print("setup changed $data");
      }
      await _refreshDevices(showLoading: false);
    });

    _bluetoothStateSubscription =
        _midiCommand.onBluetoothStateChanged.listen((data) {
      if (kDebugMode) {
        print("bluetooth state change $data");
      }
      if (_scanningBleDevices && data != BluetoothState.poweredOn) {
        _scanningBleDevices = false;
      }
      setState(() {});
    });

    unawaited(_initializeExampleState());
  }

  @override
  void dispose() {
    _setupSubscription?.cancel();
    _bluetoothStateSubscription?.cancel();
    _midiCommand.configureBleTransport(null);
    super.dispose();
  }

  Future<void> _initializeExampleState() async {
    await _updateNetworkSessionState();
    _applyTransportPolicy();
    await _refreshDevices();
  }

  Future<void> _updateNetworkSessionState() async {
    try {
      var nse = await _midiCommand.isNetworkSessionEnabled;
      if (!mounted) {
        return;
      }
      setState(() {
        _networkTransportSupported = true;
        _networkTransportEnabled = nse ?? false;
      });
    } on StateError {
      if (!mounted) {
        return;
      }
      setState(() {
        _networkTransportSupported = false;
        _networkTransportEnabled = false;
      });
    }
  }

  void _applyTransportPolicy() {
    final excludedTransports = <MidiTransport>{};
    if (!_bleTransportEnabled) {
      excludedTransports.add(MidiTransport.ble);
    }
    if (!_networkTransportEnabled) {
      excludedTransports.add(MidiTransport.network);
    }
    if (!_virtualDeviceActivated) {
      excludedTransports.add(MidiTransport.virtual);
    }
    _midiCommand.configureTransportPolicy(
      MidiTransportPolicy(
        excludedTransports: excludedTransports,
      ),
    );
  }

  Future<void> _refreshDevices({bool showLoading = true}) async {
    final generation = ++_deviceRefreshGeneration;
    if (showLoading && mounted) {
      setState(() {
        _loadingDevices = true;
      });
    }

    final devices = await _midiCommand.devices ?? <MidiDevice>[];
    if (!mounted || generation != _deviceRefreshGeneration) {
      return;
    }

    setState(() {
      _devices = devices;
      _loadingDevices = false;
    });
  }

  Future<void> _setBleTransportEnabled(bool enabled) async {
    if (_bleTransportEnabled == enabled) {
      return;
    }

    if (!enabled && _midiCommand.bluetoothState == BluetoothState.poweredOn) {
      try {
        _midiCommand.stopScanningForBluetoothDevices();
      } catch (_) {}
    }

    setState(() {
      _bleTransportEnabled = enabled;
      _scanningBleDevices = false;
    });
    _applyTransportPolicy();
    await _refreshDevices(showLoading: false);
  }

  Future<void> _setNetworkTransportEnabled(bool enabled) async {
    if (_networkTransportEnabled == enabled) {
      return;
    }

    if (!enabled) {
      try {
        _midiCommand.setNetworkSessionEnabled(false);
      } catch (_) {}
    }

    setState(() {
      _networkTransportEnabled = enabled;
    });
    _applyTransportPolicy();

    if (enabled) {
      try {
        _midiCommand.setNetworkSessionEnabled(true);
      } catch (_) {}
    }

    await _refreshDevices(showLoading: false);
  }

  Future<void> _setVirtualTransportEnabled(bool enabled) async {
    if (_virtualDeviceActivated == enabled) {
      return;
    }

    if (!enabled) {
      try {
        _midiCommand.removeVirtualDevice(name: "Flutter MIDI Command");
      } catch (_) {}
    }

    setState(() {
      _virtualDeviceActivated = enabled;
    });
    _applyTransportPolicy();

    if (enabled) {
      try {
        _midiCommand.addVirtualDevice(name: "Flutter MIDI Command");
      } catch (_) {}
    }

    await _refreshDevices(showLoading: false);
  }

  Future<void> _startBleScan(BuildContext context) async {
    if (!_bleTransportEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Enable BLE transport first.'),
      ));
      return;
    }

    await _informUserAboutBluetoothPermissions(context);

    if (kDebugMode) {
      print("start bluetooth");
    }
    await _midiCommand.startBluetooth().catchError((err) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(err.toString()),
      ));
    });

    if (kDebugMode) {
      print("wait for init");
    }
    await _midiCommand
        .waitUntilBluetoothIsInitialized()
        .timeout(const Duration(seconds: 5), onTimeout: () {
      if (kDebugMode) {
        print("Failed to initialize Bluetooth");
      }
    });

    if (!mounted) {
      return;
    }

    if (_midiCommand.bluetoothState == BluetoothState.poweredOn) {
      await _midiCommand.startScanningForBluetoothDevices().catchError((err) {
        if (kDebugMode) {
          print("Error $err");
        }
      });
      if (!mounted) {
        return;
      }
      setState(() {
        _scanningBleDevices = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Scanning for bluetooth devices ...'),
      ));
    } else {
      final messages = {
        BluetoothState.unsupported:
            'Bluetooth is not supported on this device.',
        BluetoothState.poweredOff: 'Please switch on bluetooth and try again.',
        BluetoothState.poweredOn: 'Everything is fine.',
        BluetoothState.resetting: 'Currently resetting. Try again later.',
        BluetoothState.unauthorized:
            'This app needs bluetooth permissions. Please open settings, find your app and assign bluetooth access rights and start your app again.',
        BluetoothState.unknown: 'Bluetooth is not ready yet. Try again later.',
        BluetoothState.other:
            'This should never happen. Please inform the developer of your app.',
      };
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: Colors.red,
        content: Text(messages[_midiCommand.bluetoothState] ??
            'Unknown bluetooth state: ${_midiCommand.bluetoothState}'),
      ));
    }

    if (kDebugMode) {
      print("done");
    }
  }

  IconData _deviceIconForType(MidiDeviceType type) {
    switch (type) {
      case MidiDeviceType.serial:
        return Icons.devices;
      case MidiDeviceType.network:
        return Icons.language;
      case MidiDeviceType.ble:
        return Icons.bluetooth;
      default:
        return Icons.device_unknown;
    }
  }

  String _transportLabelForType(MidiDeviceType type) {
    switch (type) {
      case MidiDeviceType.serial:
        return 'Native';
      case MidiDeviceType.network:
        return 'Network';
      case MidiDeviceType.ble:
        return 'BLE';
      case MidiDeviceType.virtual:
        return 'Virtual';
      case MidiDeviceType.ownVirtual:
        return 'Own Virtual';
      case MidiDeviceType.unknown:
        return 'Unknown';
    }
  }

  Future<void> _sendTestNote(
    BuildContext context,
    MidiDevice device,
  ) async {
    final noteOn = Uint8List.fromList(<int>[0x90, 60, 100]);
    final noteOff = Uint8List.fromList(<int>[0x80, 60, 0]);

    try {
      _midiCommand.sendData(noteOn, deviceId: device.id);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      _midiCommand.sendData(noteOff, deviceId: device.id);
    } catch (err) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to send test note: $err')),
      );
    }
  }

  IconData _connectionIconForState(MidiConnectionState state) {
    switch (state) {
      case MidiConnectionState.connected:
        return Icons.radio_button_on;
      case MidiConnectionState.connecting:
      case MidiConnectionState.disconnecting:
        return Icons.sync;
      case MidiConnectionState.disconnected:
        return Icons.radio_button_off;
    }
  }

  Future<void> _informUserAboutBluetoothPermissions(
      BuildContext context) async {
    if (_didAskForBluetoothPermissions) {
      return;
    }

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text(
              'Please Grant Bluetooth Permissions to discover BLE MIDI Devices.'),
          content: const Text(
              'In the next dialog we might ask you for bluetooth permissions.\n'
              'Please grant permissions to make bluetooth MIDI possible.'),
          actions: <Widget>[
            TextButton(
              child: const Text('Ok. I got it!'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );

    _didAskForBluetoothPermissions = true;

    return;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Builder(
        builder: (appContext) => Scaffold(
          appBar: AppBar(
            title: const Text('FlutterMidiCommand Example'),
          ),
          bottomNavigationBar: Container(
            padding: const EdgeInsets.all(24.0),
            child: const Text(
              "Tap to connect/disconnect, long press to control.",
              textAlign: TextAlign.center,
            ),
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final horizontalLayout = constraints.maxWidth >= 760;
                    final transportCard = _ControlCard(
                      title: 'Transports',
                      child: Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          _LabeledAppBarSwitch(
                            label: 'RTP',
                            tooltip: _networkTransportSupported
                                ? 'Enable network MIDI session (RTP-MIDI) when available.'
                                : 'RTP-MIDI is not supported on this platform.',
                            value: _networkTransportEnabled,
                            enabled: _networkTransportSupported,
                            onChanged: (newValue) {
                              unawaited(
                                _setNetworkTransportEnabled(newValue),
                              );
                            },
                          ),
                          _LabeledAppBarSwitch(
                            label: 'Virtual',
                            tooltip:
                                'Expose this app as a virtual MIDI device.',
                            value: _virtualDeviceActivated,
                            onChanged: (newValue) {
                              unawaited(
                                _setVirtualTransportEnabled(newValue),
                              );
                            },
                          ),
                          if (widget.enableBle)
                            _LabeledAppBarSwitch(
                              label: 'BLE',
                              tooltip: 'Enable BLE MIDI transport.',
                              value: _bleTransportEnabled,
                              onChanged: (newValue) {
                                unawaited(_setBleTransportEnabled(newValue));
                              },
                            ),
                        ],
                      ),
                    );

                    final actions = <Widget>[
                      FilledButton.icon(
                        onPressed: () {
                          unawaited(_refreshDevices());
                        },
                        icon: const Icon(Icons.refresh),
                        label: const Text('Refresh Devices'),
                      ),
                    ];

                    if (widget.enableBle) {
                      actions.add(
                        FilledButton.tonalIcon(
                          onPressed: _bleTransportEnabled
                              ? () {
                                  unawaited(_startBleScan(appContext));
                                }
                              : null,
                          icon: const Icon(Icons.bluetooth_searching),
                          label: Text(
                            _scanningBleDevices
                                ? 'Scanning BLE...'
                                : 'Scan BLE',
                          ),
                        ),
                      );
                    }

                    final bleCard = _ControlCard(
                      title: 'Discovery',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 12,
                            runSpacing: 8,
                            children: actions,
                          ),
                          if (widget.enableBle) ...[
                            const SizedBox(height: 8),
                            Text(
                              'Bluetooth: ${_midiCommand.bluetoothState.name}',
                              style: Theme.of(appContext).textTheme.bodyMedium,
                            ),
                          ],
                        ],
                      ),
                    );

                    if (horizontalLayout) {
                      return IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(child: transportCard),
                            const SizedBox(width: 12),
                            Expanded(child: bleCard),
                          ],
                        ),
                      );
                    }

                    return Column(
                      children: [
                        transportCard,
                        const SizedBox(height: 12),
                        bleCard,
                      ],
                    );
                  },
                ),
              ),
              Expanded(
                child: Center(
                  child: _buildDeviceList(appContext),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDeviceList(BuildContext context) {
    if (_loadingDevices) {
      return const CircularProgressIndicator();
    }

    if (_devices.isEmpty) {
      return const Text('No MIDI devices found.');
    }

    return ListView.builder(
      itemCount: _devices.length,
      itemBuilder: (context, index) {
        MidiDevice device = _devices[index];

        return ListTile(
          title: Text(
            device.name,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  Chip(
                    avatar: Icon(
                      _deviceIconForType(device.type),
                      size: 16,
                    ),
                    label: Text(_transportLabelForType(device.type)),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                "ins:${device.inputPorts.length} outs:${device.outputPorts.length}, ${device.id}, ${device.connectionState.name}",
              ),
            ],
          ),
          leading: Icon(
            _connectionIconForState(device.connectionState),
          ),
          trailing: device.connected
              ? IconButton(
                  icon: const Icon(Icons.music_note),
                  tooltip: 'Send test note',
                  onPressed: () {
                    unawaited(_sendTestNote(context, device));
                  },
                )
              : null,
          onLongPress: () {
            if (_midiCommand.isTransportEnabled(
                  MidiTransport.ble,
                ) &&
                _midiCommand.bluetoothState == BluetoothState.poweredOn) {
              try {
                _midiCommand.stopScanningForBluetoothDevices();
              } catch (_) {
                // Ignore BLE shutdown issues when opening the
                // controller page for non-BLE workflows.
              }
            }
            Navigator.of(context)
                .push(MaterialPageRoute<void>(
              builder: (_) => ControllerPage(device),
            ))
                .then((value) {
              setState(() {});
            });
          },
          onTap: () {
            if (device.connectionState == MidiConnectionState.connecting ||
                device.connectionState == MidiConnectionState.disconnecting) {
              return;
            }

            if (device.connected) {
              if (kDebugMode) {
                print("disconnect");
              }
              _midiCommand.disconnectDevice(device);
              setState(() {});
            } else {
              if (kDebugMode) {
                print("connect");
              }
              _midiCommand.connectToDevice(device).then((_) {
                if (kDebugMode) {
                  print("device connected async");
                }
              }).catchError((err) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(
                        "Error: ${(err as PlatformException?)?.message}")));
              });
              setState(() {});
            }
          },
        );
      },
    );
  }
}

class _ControlCard extends StatelessWidget {
  const _ControlCard({
    required this.title,
    required this.child,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}

class _LabeledAppBarSwitch extends StatelessWidget {
  const _LabeledAppBarSwitch({
    required this.label,
    required this.tooltip,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final String label;
  final String tooltip;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final labelStyle = Theme.of(context).textTheme.labelSmall;

    return Tooltip(
      message: tooltip,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4.0),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: labelStyle),
            Switch(
              value: value,
              onChanged: enabled ? onChanged : null,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ],
        ),
      ),
    );
  }
}
