import 'dart:typed_data';

import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';

class MidiPacket {
  int timestamp;
  Uint8List data;
  MidiDevice device;

  MidiPacket(this.data, this.timestamp, this.device);
}
