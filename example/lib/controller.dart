import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_midi_command/flutter_midi_command_messages.dart';
import 'package:flutter_virtual_piano/flutter_virtual_piano.dart';

class ControllerPage extends StatelessWidget {
  final MidiDevice device;

  const ControllerPage(this.device, {Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Controls'),
      ),
      body: MidiControls(device),
    );
  }
}

class MidiControls extends StatefulWidget {
  final MidiDevice device;

  const MidiControls(this.device, {Key? key}) : super(key: key);

  @override
  MidiControlsState createState() {
    return MidiControlsState();
  }
}

class MidiControlsState extends State<MidiControls> {
  var _channel = 0;
  var _controller = 0;
  var _ccValue = 0;
  var _pcValue = 0;
  var _pitchValue = 0.0;
  var _nrpnValue = 0;
  var _nrpnCtrl = 0;

  // StreamSubscription<String> _setupSubscription;
  StreamSubscription<MidiPacket>? _rxSubscription;
  final MidiCommand _midiCommand = MidiCommand();

  @override
  void initState() {
    if (kDebugMode) {
      print('init controller');
    }
    _rxSubscription = _midiCommand.onMidiDataReceived?.listen((packet) {
      if (kDebugMode) {
        print('received packet $packet');
      }
      var data = packet.data;
      var timestamp = packet.timestamp;
      var device = packet.device;
      if (kDebugMode) {
        print("data $data @ time $timestamp from device ${device.name}:${device.id}");
      }

      var status = data[0];

      if (status == 0xF8) {
        // Beat
        return;
      }

      if (status == 0xFE) {
        // Active sense;
        return;
      }

      if (data.length >= 2) {
        var rawStatus = status & 0xF0; // without channel
        var channel = (status & 0x0F);
        if (channel == _channel) {
          var d1 = data[1];
          switch (rawStatus) {
            case 0xB0: // CC
              if (d1 == _controller) {
                // CC
                var d2 = data[2];
                setState(() {
                  _ccValue = d2;
                });
              }
              break;
            case 0xC0: // PC
              setState(() {
                _pcValue = d1;
              });
              break;
            case 0xE0: // Pitch Bend
              setState(() {
                var rawPitch = d1 + (data[2] << 7);
                _pitchValue = (((rawPitch) / 0x3FFF) * 2.0) - 1;
              });
              break;
          }
        }
      }
    });

    super.initState();
  }

  @override
  void dispose() {
    // _setupSubscription?.cancel();
    _rxSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: <Widget>[
        Text("Channel", style: Theme.of(context).textTheme.titleLarge),
        SteppedSelector('Channel', _channel + 1, 1, 16, _onChannelChanged),
        const Divider(),
        Text("CC", style: Theme.of(context).textTheme.titleLarge),
        SteppedSelector('Controller', _controller, 0, 127, _onControllerChanged),
        SlidingSelector('Value', _ccValue, 0, 127, _onValueChanged),
        const Divider(),
        Text("NRPN", style: Theme.of(context).textTheme.titleLarge),
        SteppedSelector('Parameter', _nrpnCtrl, 0, 16383, _onNRPNCtrlChanged),
        SlidingSelector('Parameter', _nrpnCtrl, 0, 16383, _onNRPNCtrlChanged),
        SlidingSelector('Value', _nrpnValue, 0, 16383, _onNRPNValueChanged),
        const Divider(),
        Text("PC", style: Theme.of(context).textTheme.titleLarge),
        SteppedSelector('Program', _pcValue, 0, 127, _onProgramChanged),
        const Divider(),
        Text("Pitch Bend", style: Theme.of(context).textTheme.titleLarge),
        Slider(
            value: _pitchValue,
            max: 1,
            min: -1,
            onChanged: _onPitchChanged,
            onChangeEnd: (_) {
              _onPitchChanged(0);
            }),
        const Divider(),
        SizedBox(
          height: 80,
          child: VirtualPiano(
            noteRange: const RangeValues(48, 76),
            onNotePressed: (note, vel) {
              NoteOnMessage(channel: _channel, note: note, velocity: 100).send();
            },
            onNoteReleased: (note) {
              NoteOffMessage(channel: _channel, note: note).send();
            },
          ),
        ),
        const Divider(),
        Text("SysEx", style: Theme.of(context).textTheme.titleLarge),
        ...[64, 128, 256, 512, 768, 1024]
            .map(
              (e) => Padding(
                padding: const EdgeInsets.all(8.0),
                child: ElevatedButton(
                  onPressed: () => _sendSysex(e),
                  child: Text('Send $e bytes'),
                ),
              ),
            )
            .toList(),
      ],
    );
  }

  _onChannelChanged(int newValue) {
    setState(() {
      _channel = newValue - 1;
    });
  }

  _onControllerChanged(int newValue) {
    setState(() {
      _controller = newValue;
    });
  }

  _onProgramChanged(int newValue) {
    setState(() {
      _pcValue = newValue;
    });
    PCMessage(channel: _channel, program: _pcValue).send();
  }

  _onValueChanged(int newValue) {
    setState(() {
      _ccValue = newValue;
    });
    CCMessage(channel: _channel, controller: _controller, value: _ccValue).send();
  }

  _onNRPNValueChanged(int newValue) {
    setState(() {
      _nrpnValue = newValue;
    });
    NRPN4Message(channel: _channel, parameter: _nrpnCtrl, value: _nrpnValue).send();
  }

  _onNRPNCtrlChanged(int newValue) {
    setState(() {
      _nrpnCtrl = newValue;
    });
  }

  _onPitchChanged(double newValue) {
    setState(() {
      _pitchValue = newValue;
    });
    PitchBendMessage(channel: _channel, bend: _pitchValue).send();
  }

  void _sendSysex(int length) {
    print("Send $length SysEx bytes");
    final data = Uint8List(length);
    data[0] = 0xF0;
    for (int i = 0; i < length -1; i++) {
      data[i+1] = i % 0x80;
    }
    data[length - 1] = 0xF7;
    _midiCommand.sendData(data);
  }
}

class SteppedSelector extends StatelessWidget {
  final String label;
  final int minValue;
  final int maxValue;
  final int value;
  final Function(int) callback;

  const SteppedSelector(this.label, this.value, this.minValue, this.maxValue, this.callback, {Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Text(label),
        IconButton(
            icon: const Icon(Icons.remove_circle),
            onPressed: (value > minValue)
                ? () {
                    callback(value - 1);
                  }
                : null),
        Text(value.toString()),
        IconButton(
            icon: const Icon(Icons.add_circle),
            onPressed: (value < maxValue)
                ? () {
                    callback(value + 1);
                  }
                : null)
      ],
    );
  }
}

class SlidingSelector extends StatelessWidget {
  final String label;
  final int minValue;
  final int maxValue;
  final int value;
  final Function(int) callback;

  const SlidingSelector(this.label, this.value, this.minValue, this.maxValue, this.callback, {Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Text(label),
        Slider(
          value: value.toDouble(),
          divisions: maxValue,
          min: minValue.toDouble(),
          max: maxValue.toDouble(),
          onChanged: (v) {
            callback(v.toInt());
          },
        ),
        Text(value.toString()),
      ],
    );
  }
}
