import 'dart:typed_data';

import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';

/// One MIDI message received from a device.
class MidiPacket {
  /// When the message arrived, in whatever clock the originating transport
  /// reports. BLE MIDI carries the 13-bit millisecond timestamp of the MMA
  /// specification; other transports may report 0.
  int timestamp;

  /// Exactly one complete MIDI message, with all transport framing removed.
  ///
  /// Every transport guarantees this shape, so a listener never has to
  /// reassemble or re-split what it receives:
  ///
  /// - a channel voice or System Common message is its status byte followed by
  ///   its data bytes, and running status has already been resolved — a device
  ///   that sends `90 3C 64 40 7F` produces two packets, the second one
  ///   `90 40 7F`;
  /// - a SysEx is the whole message from `0xF0` to `0xF7`, reassembled across
  ///   however many transport packets carried it. A device that never sends the
  ///   terminator gets one synthesised once the message exceeds the transport's
  ///   size cap, so the stream always recovers;
  /// - a System Real-Time message is a single byte, delivered on its own even
  ///   when the device interleaved it into another message or into a SysEx.
  ///
  /// The buffer belongs to the listener: transports never hand out a view of an
  /// internal buffer, so it is safe to keep or mutate.
  Uint8List data;

  /// The device the message came from.
  MidiDevice device;

  MidiPacket(this.data, this.timestamp, this.device);
}
