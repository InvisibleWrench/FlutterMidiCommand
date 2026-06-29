import 'dart:typed_data';

import 'flutter_midi_command.dart';
part 'src/midi_message_parser.dart';

enum MessageType {
  CC,
  PC,
  NoteOn,
  NoteOff,
  NRPN,
  RPN,
  SYSEX,
  Beat,
  PolyAT,
  AT,
  PitchBend,
}

class MidiMessage {
  /// Byte data of the message
  Uint8List data = Uint8List(0);

  /// Base class for MIDI message types
  MidiMessage();

  /// Generates MIDI bytes for this message without sending.
  ///
  /// Subclasses override this to provide typed message encoding.
  Uint8List generateData() => data;

  /// Parses one or more raw MIDI messages into typed [MidiMessage] objects.
  static List<MidiMessage> parse(
    Uint8List bytes, {
    MidiMessageParser? parser,
    bool flushPendingNrpn = true,
  }) {
    final activeParser = parser ?? MidiMessageParser();
    return activeParser.parse(bytes, flushPendingNrpn: flushPendingNrpn);
  }

  /// Send the message bytes to all connected devices
  void send({String? deviceId, int? timestamp}) {
    data = generateData();
    MidiCommand().sendData(data, deviceId: deviceId, timestamp: timestamp);
  }
}

class CCMessage extends MidiMessage {
  int channel;
  int controller;
  int value;

  /// Continuous Control Message
  CCMessage({this.channel = 0, this.controller = 0, this.value = 0});

  @override
  Uint8List generateData() {
    final generated = Uint8List(3);
    generated[0] = 0xB0 + channel;
    generated[1] = controller;
    generated[2] = value;
    return generated;
  }
}

class PCMessage extends MidiMessage {
  int channel;
  int program;

  /// Program Change Message
  PCMessage({this.channel = 0, this.program = 0});

  @override
  Uint8List generateData() {
    final generated = Uint8List(2);
    generated[0] = 0xC0 + channel;
    generated[1] = program;
    return generated;
  }
}

class NoteOnMessage extends MidiMessage {
  int channel;
  int note;
  int velocity;

  /// Note On Message
  NoteOnMessage({this.channel = 0, this.note = 0, this.velocity = 0});

  @override
  Uint8List generateData() {
    final generated = Uint8List(3);
    generated[0] = 0x90 + channel;
    generated[1] = note;
    generated[2] = velocity;
    return generated;
  }
}

class NoteOffMessage extends MidiMessage {
  int channel;
  int note;
  int velocity;

  /// Note Off Message
  NoteOffMessage({this.channel = 0, this.note = 0, this.velocity = 0});

  @override
  Uint8List generateData() {
    final generated = Uint8List(3);
    generated[0] = 0x80 + channel;
    generated[1] = note;
    generated[2] = velocity;
    return generated;
  }
}

class SysExMessage extends MidiMessage {
  List<int> headerData;
  int value;
  List<int>? rawData;

  /// System Exclusive Message
  SysExMessage({this.headerData = const [], this.value = 0, this.rawData});

  @override
  Uint8List generateData() {
    if (rawData != null) {
      return Uint8List.fromList(rawData!);
    }
    final generated = Uint8List.fromList(headerData);
    generated.insert(0, 0xF0); // Start byte
    generated.addAll(_bytesForValue(value));
    generated.add(0xF7); // End byte
    return generated;
  }

  Int8List _bytesForValue(int value) {
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

class NRPN4Message extends MidiMessage {
  int channel;
  int parameter;
  int value;

  /// NRPN Message with Value MSB and LSB bytes
  NRPN4Message({this.channel = 0, this.parameter = 0, this.value = 0});

  @override
  Uint8List generateData() {
    final clampedParameter = parameter.clamp(0, 16383);
    final parameterMSB = clampedParameter ~/ 128;
    final parameterLSB = clampedParameter & 0x7F;

    final clampedValue = value.clamp(0, 16383);
    final valueMSB = clampedValue ~/ 128;
    final valueLSB = clampedValue & 0x7F;

    final generated = Uint8List(9);
    // Data Entry MSB
    generated[0] = 0xB0 + channel;
    generated[1] = 0x63;
    generated[2] = parameterMSB;

    // Data Entry LSB
    generated[3] = 0x62;
    generated[4] = parameterLSB;

    // Data Value MSB
    generated[5] = 0x06;
    generated[6] = valueMSB;

    // Data Value LSB
    generated[7] = 0x26;
    generated[8] = valueLSB;

    return generated;
  }
}

class NRPN3Message extends MidiMessage {
  int channel;
  int parameter;
  int value;

  /// NRPN Message with single value byte
  NRPN3Message({this.channel = 0, this.parameter = 0, this.value = 0});

  @override
  Uint8List generateData() {
    final clampedParameter = parameter.clamp(0, 16383);
    final parameterMSB = clampedParameter ~/ 128;
    final parameterLSB = clampedParameter & 0x7F;
    final clampedValue = value & 0x7F;

    final generated = Uint8List(7);
    // Data Entry MSB
    generated[0] = 0xB0 + channel;
    generated[1] = 0x63;
    generated[2] = parameterMSB;

    // Data Entry LSB
    generated[3] = 0x62;
    generated[4] = parameterLSB;

    // Data Value
    generated[5] = 0x06;
    generated[6] = clampedValue;

    return generated;
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
  Uint8List generateData() {
    final hasValueLsb = valueLSB >= 0;
    final generated = Uint8List(hasValueLsb ? 9 : 7);
    // Data Entry MSB
    generated[0] = 0xB0 + channel;
    generated[1] = 0x63;
    generated[2] = parameterMSB;

    // Data Entry LSB
    generated[3] = 0x62;
    generated[4] = parameterLSB;

    // Data Value MSB
    generated[5] = 0x06;
    generated[6] = valueMSB;

    // Data Value LSB
    if (hasValueLsb) {
      generated[7] = 0x26;
      generated[8] = valueLSB;
    }

    return generated;
  }
}

class NRPNNullMessage extends MidiMessage {
  int channel;

  /// It is best practice, but not mandatory, to send a Null Message at the end of a NRPN
  /// Stream to prevent accidental value changes on CC6 after a message has concluded.
  NRPNNullMessage({this.channel = 0});

  @override
  Uint8List generateData() {
    final generated = Uint8List(6);
    // Data Entry MSB
    generated[0] = 0xB0 + channel;
    generated[1] = 0x63;
    generated[2] = 0x7F;

    // Data Entry LSB
    generated[3] = 0xB0 + channel;
    generated[4] = 0x62;
    generated[5] = 0x7F;

    return generated;
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
  Uint8List generateData() {
    final generated = Uint8List(12);
    // Data Entry MSB
    generated[0] = 0xB0 + channel;
    generated[1] = 0x65;
    generated[2] = parameter >> 7;

    // Data Entry LSB
    generated[3] = 0xB0 + channel;
    generated[4] = 0x64;
    generated[5] = parameter & 0x7F;

    // Data Value MSB
    generated[6] = 0xB0 + channel;
    generated[7] = 0x06;
    generated[8] = value >> 7;

    // Data Value LSB
    generated[9] = 0xB0 + channel;
    generated[10] = 0x26;
    generated[11] = value & 0x7F;

    return generated;
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
  Uint8List generateData() {
    final length = valueLSB > -1 ? 12 : 9;
    final generated = Uint8List(length);
    // Data Entry MSB
    generated[0] = 0xB0 + channel;
    generated[1] = 0x65;
    generated[2] = parameterMSB;

    // Data Entry LSB
    generated[3] = 0xB0 + channel;
    generated[4] = 0x64;
    generated[5] = parameterLSB;

    // Data Value MSB
    generated[6] = 0xB0 + channel;
    generated[7] = 0x06;
    generated[8] = valueMSB;

    // Data Value LSB
    if (valueLSB > -1) {
      generated[9] = 0xB0 + channel;
      generated[10] = 0x26;
      generated[11] = valueLSB;
    }

    return generated;
  }
}

class RPNNullMessage extends MidiMessage {
  int channel;

  /// It is best practice, but not mandatory, to send a Null Message at the end of a RPN
  /// Stream to prevent accidental value changes on CC6 after a message has concluded.
  RPNNullMessage({this.channel = 0});

  @override
  Uint8List generateData() {
    final generated = Uint8List(6);
    // Data Entry MSB
    generated[0] = 0xB0 + channel;
    generated[1] = 0x65;
    generated[2] = 0x7F;

    // Data Entry LSB
    generated[3] = 0xB0 + channel;
    generated[4] = 0x64;
    generated[5] = 0x7F;

    return generated;
  }
}

class PitchBendMessage extends MidiMessage {
  int channel;
  double bend;

  /// Create Pitch Bend Message with a bend value range of -1.0 to 1.0 (default: 0.0).
  PitchBendMessage({this.channel = 0, this.bend = 0});

  @override
  Uint8List generateData() {
    final clampedBend = (bend.clamp(-1.0, 1.0) + 1) / 2.0;
    final targetValue = (clampedBend * 0x3FFF).round();
    final bendMSB = targetValue >> 7;
    final bendLSB = targetValue & 0x7F;

    final generated = Uint8List(3);
    generated[0] = 0xE0 + channel;
    generated[1] = bendLSB;
    generated[2] = bendMSB;
    return generated;
  }
}

class PolyATMessage extends MidiMessage {
  int channel;
  int note;
  int pressure;

  /// Create a Polyphonic Aftertouch Message for a single note
  PolyATMessage({this.channel = 0, this.note = 0, this.pressure = 0});

  @override
  Uint8List generateData() {
    final generated = Uint8List(3);
    generated[0] = 0xA0 + channel;
    generated[1] = note;
    generated[2] = pressure;
    return generated;
  }
}

class ATMessage extends MidiMessage {
  int channel;
  int pressure;

  /// Create an Aftertouch Message for a single channel
  ATMessage({this.channel = 0, this.pressure = 0});

  @override
  Uint8List generateData() {
    final generated = Uint8List(2);
    generated[0] = 0xD0 + channel;
    generated[1] = pressure;
    return generated;
  }
}

class SenseMessage extends MidiMessage {
  /// Sense Message

  @override
  Uint8List generateData() {
    final generated = Uint8List(1);
    generated[0] = 0xFE;
    return generated;
  }
}

enum ClockType { beat, start, cont, stop }

class ClockMessage extends MidiMessage {
  ClockType type;

  /// Clock Message
  ClockMessage({this.type = ClockType.beat});

  @override
  Uint8List generateData() {
    final generated = Uint8List(1);
    switch (type) {
      case ClockType.beat:
        generated[0] = 0xF8;
        break;
      case ClockType.start:
        generated[0] = 0xFA;
        break;
      case ClockType.cont:
        generated[0] = 0xFB;
        break;
      case ClockType.stop:
        generated[0] = 0xFC;
        break;
    }
    return generated;
  }
}
