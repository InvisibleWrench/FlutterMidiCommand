import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'controller.dart';

void main() => runApp(new MyApp());

class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => new _MyAppState();
}

class _MyAppState extends State<MyApp> {
  StreamSubscription<String> _setupSubscription;
  MidiCommand _midiCommand = MidiCommand();

  @override
  void initState() {
    super.initState();

    _midiCommand.startScanningForBluetoothDevices().catchError((err) {
      print("Error $err");
    });
    _setupSubscription = _midiCommand.onMidiSetupChanged.listen((data) {
      print("setup changed $data");

      switch (data) {
        case "deviceFound":
          break;
      // case "deviceOpened":
      //   break;
        default:
        // print("Unhandled setup change: $data");
          break;
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _setupSubscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return new MaterialApp(
      home: new Scaffold(
        appBar: new AppBar(
          title: const Text('FlutterMidiCommand'),
          actions: <Widget>[
            IconButton(
                onPressed: () {
                  _midiCommand
                      .startScanningForBluetoothDevices()
                      .catchError((err) {
                    print("Error $err");
                  });
                  setState(() {});
                },
                icon: Icon(Icons.refresh))
          ],
        ),
        body: new Center(
            child: FutureBuilder(
                future: _midiCommand.devices,
                builder: (BuildContext context, AsyncSnapshot snapshot) {
                  if (snapshot.hasData && snapshot.data != null) {
                    var devices = snapshot.data as List<MidiDevice>;
                    return ListView.builder(
                      // Let the ListView know how many items it needs to build
                      itemCount: devices.length,
                      // Provide a builder function. This is where the magic happens! We'll
                      // convert each item into a Widget based on the type of item it is.
                      itemBuilder: (context, index) {
                        MidiDevice device = devices[index];

                        return ListTile(
                          title: Text(
                            device.name,
                            style: Theme.of(context).textTheme.headline5,
                          ),
                          subtitle: Text(
                              "ins:${device.inputPorts.length} outs:${device.outputPorts.length}"),
                          trailing:
                                device.type == "BLE"
                                    ? Icon(Icons.bluetooth, color: device.connected ? Colors.green : Colors.black)
                                    : device.connected ? Icon(Icons.check, color: Colors.green) : null,
                          onTap: () {
                            if (!device.connected) {
                              _midiCommand.connectToDevice(device);
                            }
                            Navigator.of(context).push(MaterialPageRoute<Null>(
                              builder: (_) => ControllerPage(device),
                            ));
                          },
                          onLongPress: () {
                            device.connected ? _midiCommand.disconnectDevice(device) : _midiCommand.connectToDevice(device);
                            setState(() {
                            });
                          },
                        );
                      },
                    );
                  } else {
                    return new CircularProgressIndicator();
                  }
                })),
      ),
    );
  }
}
