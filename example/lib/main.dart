import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'controller.dart';
import 'dart:io' show Platform;

void main() => runApp(new MyApp());

class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => new _MyAppState();
}

class _MyAppState extends State<MyApp> {
  StreamSubscription<String>? _setupSubscription;
  StreamSubscription<BluetoothState>? _bluetoothStateSubscription;
  MidiCommand _midiCommand = MidiCommand();

  @override
  void initState() {
    super.initState();

    _setupSubscription = _midiCommand.onMidiSetupChanged?.listen((data) async {
      print("setup changed $data");
      setState(() {});
    });

    _midiCommand.startBluetoothCentral();

    /* _bluetoothStateSubscription =
        _midiCommand.onBluetoothStateChanged.listen((data) {
      print("bluetooth state change $data");
      setState(() {});
    });*/

    if (Platform.isIOS) {
      _midiCommand.addVirtualDevice(name: "Flutter MIDI Command");
    }
  }

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

  @override
  Widget build(BuildContext context) {
    return new MaterialApp(
      home: new Scaffold(
        appBar: new AppBar(
          title: const Text('FlutterMidiCommand Example'),
          actions: <Widget>[
            Builder(builder: (context) {
              return IconButton(
                  onPressed: () {
                    // If bluetooth is powered on, start scanning
                    if (_midiCommand.bluetoothState ==
                        BluetoothState.poweredOn) {
                      _midiCommand
                          .startScanningForBluetoothDevices()
                          .catchError((err) {
                        print("Error $err");
                      });

                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text('Scanning for bluetooth devices ...'),
                      ));
                    } else {
                      final messages = {
                        BluetoothState.unsupported:
                            'Bluetooth is not supported on this device.',
                        BluetoothState.poweredOff:
                            'Please switch on bluetooth and try again.',
                        BluetoothState.poweredOn: 'Everything is fine.',
                        BluetoothState.resetting:
                            'Currently resetting. Try again later.',
                        BluetoothState.unauthorized:
                            'This app has needs bluetooth permissions. Please open settings, find your app and assign bluetooth access rights and start your app again.',
                        BluetoothState.unknown:
                            'Bluetooth is not ready yet. Try again later.',
                        BluetoothState.other:
                            'This should never happen. Please inform the developer of your app.',
                      };

                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        backgroundColor: Colors.red,
                        content: Text(messages[_midiCommand.bluetoothState] ??
                            'Unknown bluetooth state: ${_midiCommand.bluetoothState}'),
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
                      subtitle: Text(
                          "ins:${device.inputPorts.length} outs:${device.outputPorts.length}"),
                      leading: Icon(device.connected
                          ? Icons.radio_button_on
                          : Icons.radio_button_off),
                      trailing: Icon(_deviceIconForType(device.type)),
                      onLongPress: () {
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
                          _midiCommand
                              .connectToDevice(device)
                              .then((_) => print("device connected async"));
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
