import 'dart:typed_data';
import 'flutter_midi_command.dart';

enum MessageType {
  CC,
  PC,
  NoteOn,
  NoteOff,
  NRPN,
  SYSEX,
  Beat,
  PolyAT,
  AT,
  PitchBend
}

/// Base class for MIDI message types
class MidiMessage {
  /// Byte data of the message
  Uint8List data = Uint8List(0);

  MidiMessage();

  /// Send the message bytes to all connected devices
  void send() {
    MidiCommand().sendData(data);
  }
}

/// Continuous Control Message
class CCMessage extends MidiMessage {
  int channel;
  int controller;
  int value;

  CCMessage({this.channel = 0, this.controller = 0, this.value = 0});

  @override
  void send() {
    data = Uint8List(3);
    data[0] = 0xB0 + channel;
    data[1] = controller;
    data[2] = value;
    super.send();
  }
}

/// Program Change Message
class PCMessage extends MidiMessage {
  int channel;
  int program;

  PCMessage({this.channel = 0, this.program = 0});

  @override
  void send() {
    data = Uint8List(2);
    data[0] = 0xC0 + channel;
    data[1] = program;
    super.send();
  }
}

/// Note On Message
class NoteOnMessage extends MidiMessage {
  int channel;
  int note;
  int velocity;

  NoteOnMessage({this.channel = 0, this.note = 0, this.velocity = 0});

  @override
  void send() {
    data = Uint8List(3);
    data[0] = 0x90 + channel;
    data[1] = note;
    data[2] = velocity;
    super.send();
  }
}

/// Note Off Message
class NoteOffMessage extends MidiMessage {
  int channel;
  int note;
  int velocity;

  NoteOffMessage({this.channel = 0, this.note = 0, this.velocity = 0});

  @override
  void send() {
    data = Uint8List(3);
    data[0] = 0x80 + channel;
    data[1] = note;
    data[2] = velocity;
    super.send();
  }
}

/// System Exclusive Message
class SysExMessage extends MidiMessage {
  List<int> headerData;
  int value;

  SysExMessage({this.headerData = const [], this.value = 0});

  @override
  void send() {
    data = Uint8List.fromList(headerData);
    data.insert(0, 0xF0); // Start byte
    data.addAll(_bytesForValue(value));
    data.add(0xF7); // End byte
    super.send();
  }

  Int8List _bytesForValue(int value) {
    print("bytes for value $value");
    var bytes = Int8List(5);

    int absValue = value.abs();

    int base256 = (absValue ~/ 256);
    int left = absValue - (base256 * 256);
    int base1 = left % 128;
    left -= base1;
    int base2 = left ~/ 2;

    if (value < 0) {
      bytes[0] = 0x7F;
      bytes[1] = 0x7F;
      bytes[2] = 0x7F - base256;
      bytes[3] = 0x7F - base2;
      bytes[4] = 0x7F - base1;
    } else {
      bytes[2] = base256;
      bytes[3] = base2;
      bytes[4] = base1;
    }
    return bytes;
  }
}

/// NRPN Message
class NRPNMessage extends MidiMessage {
  int channel;
  int parameter;
  int value;

  NRPNMessage({this.channel = 0, this.parameter = 0, this.value = 0});

  @override
  void send() {
    data = Uint8List(12);
    // Data Entry MSB
    data[0] = 0xB0 + channel;
    data[1] = 0x63;
    data[2] = parameter ~/ 128;

    // Data Entry LSB
    data[3] = 0xB0 + channel;
    data[4] = 0x62;
    data[5] = parameter - (data[2] * 128);

    // Data Value MSB
    data[6] = 0xB0 + channel;
    data[7] = 0x06;
    data[8] = value & 0x7F;

    // Data Value LSB
    data[9] = 0xB0 + channel;
    data[10] = 0x38;
    data[11] = value & 0x3F80;

    super.send();
  }
}

/// NRPN Message with data separated in MSB, LSB
class NRPNHexMessage extends MidiMessage {
  int channel;
  int parameterMSB;
  int parameterLSB;
  int valueMSB;
  int valueLSB;

  NRPNHexMessage({
    this.channel = 0,
    this.parameterMSB = 0,
    this.parameterLSB = 0,
    this.valueMSB = 0,
    this.valueLSB = -1,
  });

  @override
  void send() {
    var length = valueLSB > -1 ? 12 : 9;
    data = Uint8List(length);
    // Data Entry MSB
    data[0] = 0xB0 + channel;
    data[1] = 0x63;
    data[2] = parameterMSB;

    // Data Entry LSB
    data[3] = 0xB0 + channel;
    data[4] = 0x62;
    data[5] = parameterLSB;

    // Data Value MSB
    data[6] = 0xB0 + channel;
    data[7] = 0x06;
    data[8] = valueMSB;

    // Data Value LSB
    if (valueLSB > -1) {
      data[9] = 0xB0 + channel;
      data[10] = 0x38;
      data[11] = valueLSB;
    }

    super.send();
  }
}

class PitchBendMessage extends MidiMessage {
  int channel;
  double bend;

  /// Create Pitch Bend Message with a bend value range of -1.0 to 1.0 (default: 0.0).
  PitchBendMessage({this.channel = 0, this.bend = 0});

  @override
  void send() {
    double clampedBend = (bend.clamp(-1, 1) + 1) / 2.0;
    int targetValue = (clampedBend * 0x3FFF).round();

    int bendMSB = targetValue >> 7;
    int bendLSB = targetValue & 0x7F;

    data = Uint8List(3);
    data[0] = 0xE0 + channel;
    data[1] = bendLSB;
    data[2] = bendMSB;
    super.send();
  }
}

class PolyATMessage extends MidiMessage {
  int channel;
  int note;
  int pressure;

  /// Create a Polyphonic Aftertouch Message for a single note
  PolyATMessage({this.channel = 0, this.note = 0, this.pressure = 0});

  @override
  void send() {
    data = Uint8List(3);
    data[0] = 0xA0 + channel;
    data[1] = note;
    data[2] = pressure;
    super.send();
  }
}

class ATMessage extends MidiMessage {
  int channel;
  int pressure;

  /// Create an Aftertouch Message for a single channel
  ATMessage({this.channel = 0, this.pressure = 0});

  @override
  void send() {
    data = Uint8List(2);
    data[0] = 0xD0 + channel;
    data[1] = pressure;
    super.send();
  }
}
