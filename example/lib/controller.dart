import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_midi_command/flutter_midi_command_messages.dart';
import 'package:flutter_midi_command_example/recorder.dart';
import 'package:flutter_virtual_piano/flutter_virtual_piano.dart';

class ControllerPage extends StatelessWidget {
  final MidiDevice device;

  const ControllerPage(this.device, {super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(device.name),
      ),
      body: MidiControls(device),
    );
  }
}

class MidiControls extends StatefulWidget {
  final MidiDevice device;

  const MidiControls(this.device, {super.key});

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
  StreamSubscription<MidiDataReceivedEvent>? _rxSubscription;
  final MidiCommand _midiCommand = MidiCommand();

  @override
  void initState() {
    if (kDebugMode) {
      print('init controller');
    }
    _rxSubscription = _midiCommand.onMidiDataReceived?.listen(
      _handleMessageEvent,
    );

    super.initState();
  }

  @override
  void dispose() {
    // _setupSubscription?.cancel();
    _rxSubscription?.cancel();
    super.dispose();
  }

  void _handleMessageEvent(MidiDataReceivedEvent event) {
    if (event.device.id != widget.device.id) {
      return;
    }

    final message = event.message;
    if (message is ClockMessage || message is SenseMessage) {
      return;
    }

    var nextCcValue = _ccValue;
    var nextPcValue = _pcValue;
    var nextPitchValue = _pitchValue;
    var nextNrpnValue = _nrpnValue;
    var nextNrpnCtrl = _nrpnCtrl;
    var hasChanges = false;

    if (message is CCMessage) {
      if (message.channel == _channel && message.controller == _controller) {
        if (nextCcValue != message.value) {
          nextCcValue = message.value;
          hasChanges = true;
        }
      }
    } else if (message is PCMessage) {
      if (message.channel == _channel && nextPcValue != message.program) {
        nextPcValue = message.program;
        hasChanges = true;
      }
    } else if (message is PitchBendMessage) {
      if (message.channel == _channel && nextPitchValue != message.bend) {
        nextPitchValue = message.bend;
        hasChanges = true;
      }
    } else if (message is NRPN4Message) {
      if (message.channel == _channel &&
          (nextNrpnCtrl != message.parameter ||
              nextNrpnValue != message.value)) {
        nextNrpnCtrl = message.parameter;
        nextNrpnValue = message.value;
        hasChanges = true;
      }
    } else if (message is NRPN3Message) {
      if (message.channel == _channel &&
          (nextNrpnCtrl != message.parameter ||
              nextNrpnValue != message.value)) {
        nextNrpnCtrl = message.parameter;
        nextNrpnValue = message.value;
        hasChanges = true;
      }
    } else if (message is NRPNHexMessage) {
      if (message.channel != _channel) {
        return;
      }

      final parameter =
          ((message.parameterMSB & 0x7F) << 7) | (message.parameterLSB & 0x7F);
      final value = message.valueLSB >= 0
          ? ((message.valueMSB & 0x7F) << 7) | (message.valueLSB & 0x7F)
          : (message.valueMSB & 0x7F);
      if (nextNrpnCtrl != parameter || nextNrpnValue != value) {
        nextNrpnCtrl = parameter;
        nextNrpnValue = value;
        hasChanges = true;
      }
    }

    if (!hasChanges || !mounted) {
      return;
    }

    setState(() {
      _ccValue = nextCcValue;
      _pcValue = nextPcValue;
      _pitchValue = nextPitchValue;
      _nrpnCtrl = nextNrpnCtrl;
      _nrpnValue = nextNrpnValue;
    });
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
        SteppedSelector(
            'Controller', _controller, 0, 127, _onControllerChanged),
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
              NoteOnMessage(
                channel: _channel,
                note: note,
                velocity: 100,
              ).send(deviceId: widget.device.id);
            },
            onNoteReleased: (note) {
              NoteOffMessage(
                channel: _channel,
                note: note,
              ).send(deviceId: widget.device.id);
            },
          ),
        ),
        const Divider(),
        Text("SysEx", style: Theme.of(context).textTheme.titleLarge),
        ...[64, 128, 256, 512, 768, 1024].map(
          (e) => Padding(
            padding: const EdgeInsets.all(8.0),
            child: ElevatedButton(
              onPressed: () => _sendSysex(e),
              child: Text('Send $e bytes'),
            ),
          ),
        ),
        const Divider(),
        const MidiRecorderPanel(),
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
    PCMessage(channel: _channel, program: _pcValue).send(
      deviceId: widget.device.id,
    );
  }

  _onValueChanged(int newValue) {
    setState(() {
      _ccValue = newValue;
    });
    CCMessage(
      channel: _channel,
      controller: _controller,
      value: _ccValue,
    ).send(deviceId: widget.device.id);
  }

  _onNRPNValueChanged(int newValue) {
    setState(() {
      _nrpnValue = newValue;
    });
    NRPN4Message(
      channel: _channel,
      parameter: _nrpnCtrl,
      value: _nrpnValue,
    ).send(deviceId: widget.device.id);
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
    PitchBendMessage(channel: _channel, bend: _pitchValue).send(
      deviceId: widget.device.id,
    );
  }

  void _sendSysex(int length) {
    if (kDebugMode) {
      print("Send $length SysEx bytes");
    }
    final data = Uint8List(length);
    data[0] = 0xF0;
    for (int i = 0; i < length - 1; i++) {
      data[i + 1] = i % 0x80;
    }
    data[length - 1] = 0xF7;
    SysExMessage(rawData: data).send(deviceId: widget.device.id);
  }
}

class SteppedSelector extends StatelessWidget {
  final String label;
  final int minValue;
  final int maxValue;
  final int value;
  final Function(int) callback;

  const SteppedSelector(
    this.label,
    this.value,
    this.minValue,
    this.maxValue,
    this.callback, {
    super.key,
  });

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

  const SlidingSelector(
    this.label,
    this.value,
    this.minValue,
    this.maxValue,
    this.callback, {
    super.key,
  });

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
