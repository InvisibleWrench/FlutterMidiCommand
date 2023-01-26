import 'dart:typed_data';

import 'flutter_midi_command.dart';

enum MessageType { CC, PC, NoteOn, NoteOff, NRPN, RPN, SYSEX, Beat, PolyAT, AT, PitchBend }

class MidiMessage {
  /// Byte data of the message
  Uint8List data = Uint8List(0);

  /// Base class for MIDI message types
  MidiMessage();

  /// Send the message bytes to all connected devices
  void send() {
    print("send $data");
    MidiCommand().sendData(data);
  }
}

class CCMessage extends MidiMessage {
  int channel;
  int controller;
  int value;

  /// Continuous Control Message
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

class PCMessage extends MidiMessage {
  int channel;
  int program;

  /// Program Change Message
  PCMessage({this.channel = 0, this.program = 0});

  @override
  void send() {
    data = Uint8List(2);
    data[0] = 0xC0 + channel;
    data[1] = program;
    super.send();
  }
}

class NoteOnMessage extends MidiMessage {
  int channel;
  int note;
  int velocity;

  /// Note On Message
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

class NoteOffMessage extends MidiMessage {
  int channel;
  int note;
  int velocity;

  /// Note Off Message
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

class SysExMessage extends MidiMessage {
  List<int> headerData;
  int value;

  /// System Exclusive Message
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

class NRPNMessage extends MidiMessage {
  int channel;
  int parameter;
  int value;

  /// NRPN Message
  NRPNMessage({this.channel = 0, this.parameter = 0, this.value = 0});

  @override
  void send() {
    parameter = parameter.clamp(0, 16383);
    int parameterMSB = parameter ~/ 128;
    int parameterLSB = parameter & 0x7F;

    value = value.clamp(0, 16383);
    int valueMSB = value ~/ 128;
    int valueLSB = value & 0x7F;

    var length = value > 127 ? 9 : 7;

    data = Uint8List(length);
    // Data Entry MSB
    data[0] = 0xB0 + channel;
    data[1] = 0x63;
    data[2] = parameterMSB;

    // Data Entry LSB
    data[3] = 0x62;
    data[4] = parameterLSB;

    // Data Value MSB
    data[5] = 0x06;
    data[6] = value > 127 ? valueMSB : value;

    // Data Value MSB
    if (value > 127) {
      data[7] = 0x38;
      data[8] = valueLSB;
    }

    super.send();
  }
}

class NRPNHexMessage extends MidiMessage {
  int channel;
  int parameterMSB;
  int parameterLSB;
  int valueMSB;
  int valueLSB;

  /// NRPN Message with data separated in MSB, LSB
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

class NRPNNullMessage extends MidiMessage {
  int channel;

  /// It is best practice, but not mandatory, to send a Null Message at the end of a NRPN
  /// Stream to prevent accidental value changes on CC6 after a message has concluded.
  NRPNNullMessage({this.channel = 0});

  void send() {
    data = Uint8List(6);
    // Data Entry MSB
    data[0] = 0xB0 + channel;
    data[1] = 0x63;
    data[2] = 0x7F;

    // Data Entry LSB
    data[3] = 0xB0 + channel;
    data[4] = 0x62;
    data[5] = 0x7F;

    super.send();
  }
}

class RPNMessage extends MidiMessage {
  int channel;
  int parameter;
  int value;

  /// ## RPN Message
  /// All defined RPN Parameters as per Midi Spec:
  /// - 0x0000 – Pitch bend range
  /// - 0x0001 – Fine tuning
  /// - 0x0002 – Coarse tuning
  /// - 0x0003 – Tuning program change
  /// - 0x0004 – Tuning bank select
  /// - 0x0005 – Modulation depth range
  /// - 0x0006 – MPE Configuration Message (MCM)
  ///
  /// Value Range is Hex: 0x0000 - 0x3FFFF or Decimal: 0-16383
  RPNMessage({this.channel = 0, this.parameter = 0, this.value = 0});

  @override
  void send() {
    data = Uint8List(12);
    // Data Entry MSB
    data[0] = 0xB0 + channel;
    data[1] = 0x65;
    data[2] = parameter >> 7;

    // Data Entry LSB
    data[3] = 0xB0 + channel;
    data[4] = 0x64;
    data[5] = parameter & 0x7F;

    // Data Value MSB
    data[6] = 0xB0 + channel;
    data[7] = 0x06;
    data[8] = value >> 7;

    // Data Value LSB
    data[9] = 0xB0 + channel;
    data[10] = 0x26;
    data[11] = value & 0x7F;

    super.send();
  }
}

class RPNHexMessage extends MidiMessage {
  int channel;
  int parameterMSB;
  int parameterLSB;
  int valueMSB;
  int valueLSB;

  /// RPN Message with data separated in MSB, LSB
  RPNHexMessage({
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
    data[1] = 0x65;
    data[2] = parameterMSB;

    // Data Entry LSB
    data[3] = 0xB0 + channel;
    data[4] = 0x64;
    data[5] = parameterLSB;

    // Data Value MSB
    data[6] = 0xB0 + channel;
    data[7] = 0x06;
    data[8] = valueMSB;

    // Data Value LSB
    if (valueLSB > -1) {
      data[9] = 0xB0 + channel;
      data[10] = 0x26;
      data[11] = valueLSB;
    }

    super.send();
  }
}

class RPNNullMessage extends MidiMessage {
  int channel;

  /// It is best practice, but not mandatory, to send a Null Message at the end of a RPN
  /// Stream to prevent accidental value changes on CC6 after a message has concluded.
  RPNNullMessage({this.channel = 0});

  void send() {
    data = Uint8List(6);
    // Data Entry MSB
    data[0] = 0xB0 + channel;
    data[1] = 0x65;
    data[2] = 0x7F;

    // Data Entry LSB
    data[3] = 0xB0 + channel;
    data[4] = 0x64;
    data[5] = 0x7F;

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
