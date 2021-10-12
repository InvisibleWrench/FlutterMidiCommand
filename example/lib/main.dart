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
  MidiCommand _midiCommand = MidiCommand();

  @override
  void initState() {
    super.initState();

    _midiCommand.startScanningForBluetoothDevices().catchError((err) {
      print("Error $err");
    });
    _setupSubscription = _midiCommand.onMidiSetupChanged?.listen((data) {
      print("setup changed $data");
      setState(() {});
    });

    if (Platform.isIOS) {
      _midiCommand.addVirtualDevice(name: "Flutter MIDI Command");
    }
  }

  @override
  void dispose() {
    _setupSubscription?.cancel();
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
            IconButton(
                onPressed: () {
                  _midiCommand.startScanningForBluetoothDevices().catchError((err) {
                    print("Error $err");
                  });
                  setState(() {});
                },
                icon: Icon(Icons.refresh))
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
                      subtitle: Text("ins:${device.inputPorts.length} outs:${device.outputPorts.length}"),
                      leading: Icon(device.connected ? Icons.radio_button_on : Icons.radio_button_off),
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
                          _midiCommand.connectToDevice(device).then((_) => print("device connected async"));
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
