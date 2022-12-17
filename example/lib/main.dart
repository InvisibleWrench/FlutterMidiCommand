import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';

import 'controller.dart';

void main() => runApp(new MyApp());

class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => new _MyAppState();
}

class _MyAppState extends State<MyApp> {
  StreamSubscription<String>? _setupSubscription;
  StreamSubscription<BluetoothState>? _bluetoothStateSubscription;
  MidiCommand _midiCommand = MidiCommand();

  bool _virtualDeviceActivated = false;

  @override
  void initState() {
    super.initState();

    _setupSubscription = _midiCommand.onMidiSetupChanged?.listen((data) async {
      print("setup changed $data");
      setState(() {});
    });

    _bluetoothStateSubscription = _midiCommand.onBluetoothStateChanged.listen((data) {
      print("bluetooth state change $data");
      setState(() {});
    });
  }

  bool _didAskForBluetoothPermissions = false;

  @override
  void dispose() {
    _setupSubscription?.cancel();
    _bluetoothStateSubscription?.cancel();
    super.dispose();
  }

  IconData _deviceIconForType(String type) {
    switch (type) {
      case "native":
        return Icons.devices;
      case "network":
        return Icons.language;
      case "BLE":
        return Icons.bluetooth;
      default:
        return Icons.device_unknown;
    }
  }

  Future<void> _informUserAboutBluetoothPermissions(BuildContext context) async {
    if (_didAskForBluetoothPermissions) {
      return;
    }

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Please Grant Bluetooth Permissions to discover BLE MIDI Devices.'),
          content: const Text('In the next dialog we might ask you for bluetooth permissions.\n'
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
    return new MaterialApp(
      home: new Scaffold(
        appBar: new AppBar(
          title: const Text('FlutterMidiCommand Example'),
          actions: <Widget>[
            Switch(
                value: _virtualDeviceActivated,
                onChanged: (newValue) {
                  setState(() {
                    _virtualDeviceActivated = newValue;
                  });
                  if (newValue) {
                    _midiCommand.addVirtualDevice(name: "Flutter MIDI Command");
                  } else {
                    _midiCommand.removeVirtualDevice(name: "Flutter MIDI Command");
                  }
                }),
            Builder(builder: (context) {
              return IconButton(
                  onPressed: () async {
                    // Ask for bluetooth permissions
                    await _informUserAboutBluetoothPermissions(context);

                    // Start bluetooth
                    await _midiCommand.startBluetoothCentral();

                    await _midiCommand.waitUntilBluetoothIsInitialized();

                    // If bluetooth is powered on, start scanning
                    if (_midiCommand.bluetoothState == BluetoothState.poweredOn) {
                      _midiCommand.startScanningForBluetoothDevices().catchError((err) {
                        print("Error $err");
                      });

                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text('Scanning for bluetooth devices ...'),
                      ));
                    } else {
                      final messages = {
                        BluetoothState.unsupported: 'Bluetooth is not supported on this device.',
                        BluetoothState.poweredOff: 'Please switch on bluetooth and try again.',
                        BluetoothState.poweredOn: 'Everything is fine.',
                        BluetoothState.resetting: 'Currently resetting. Try again later.',
                        BluetoothState.unauthorized:
                            'This app needs bluetooth permissions. Please open settings, find your app and assign bluetooth access rights and start your app again.',
                        BluetoothState.unknown: 'Bluetooth is not ready yet. Try again later.',
                        BluetoothState.other: 'This should never happen. Please inform the developer of your app.',
                      };

                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        backgroundColor: Colors.red,
                        content: Text(messages[_midiCommand.bluetoothState] ?? 'Unknown bluetooth state: ${_midiCommand.bluetoothState}'),
                      ));
                    }

                    // If not show a message telling users what to do
                    setState(() {});
                  },
                  icon: Icon(Icons.refresh));
            }),
          ],
        ),
        bottomNavigationBar: Container(
          padding: EdgeInsets.all(24.0),
          child: Text(
            "Tap to connnect/disconnect, long press to control.",
            textAlign: TextAlign.center,
          ),
        ),
        body: Center(
          child: FutureBuilder(
            future: _midiCommand.devices,
            builder: (BuildContext context, AsyncSnapshot snapshot) {
              if (snapshot.hasData && snapshot.data != null) {
                var devices = snapshot.data as List<MidiDevice>;
                return ListView.builder(
                  itemCount: devices.length,
                  itemBuilder: (context, index) {
                    MidiDevice device = devices[index];

                    return ListTile(
                      title: Text(
                        device.name,
                        style: Theme.of(context).textTheme.headline5,
                      ),
                      subtitle: Text("ins:${device.inputPorts.length} outs:${device.outputPorts.length}, ${device.id}, ${device.type}"),
                      leading: Icon(device.connected ? Icons.radio_button_on : Icons.radio_button_off),
                      trailing: Icon(_deviceIconForType(device.type)),
                      onLongPress: () {
                        _midiCommand.stopScanningForBluetoothDevices();
                        Navigator.of(context).push(MaterialPageRoute<Null>(
                          builder: (_) => ControllerPage(device),
                        ));
                      },
                      onTap: () {
                        if (device.connected) {
                          print("disconnect");
                          _midiCommand.disconnectDevice(device);
                        } else {
                          print("connect");
                          _midiCommand.connectToDevice(device).then((_) => print("device connected async")).catchError((err) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: ${(err as PlatformException?)?.message}")));
                          });
                        }
                      },
                    );
                  },
                );
              } else {
                return new CircularProgressIndicator();
              }
            },
          ),
        ),
      ),
    );
  }
}
