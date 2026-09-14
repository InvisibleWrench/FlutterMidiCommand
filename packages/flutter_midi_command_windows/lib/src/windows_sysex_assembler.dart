import 'dart:typed_data';

/// Reassembles a SysEx message from the chunks WinMM delivers.
///
/// A SysEx larger than one input buffer arrives as several `MM_MIM_LONGDATA`
/// callbacks, and only the last of them ends with `0xF7`. One assembler belongs
/// to one device: the buffer used to be a file-global shared by every open
/// device, so two devices receiving SysEx at the same time interleaved into each
/// other's message.
class WindowsSysExAssembler {
  WindowsSysExAssembler({this.maxLength = 65536});

  /// Largest message this assembler will build before force-terminating it, so
  /// a device that never sends `0xF7` cannot make the buffer grow without
  /// bound. Counts the opening `0xF0` and the synthesised `0xF7`.
  final int maxLength;

  final List<int> _buffer = [];

  /// Whether a message is open. Bytes arriving outside one are dropped, so a
  /// stream that has already been force-terminated cannot keep producing
  /// headless fragments.
  bool _inMessage = false;

  int get _cap => maxLength < 2 ? 2 : maxLength;

  /// Adds one WinMM chunk, returning every message it completes.
  ///
  /// Usually empty (the message is still being assembled) or a single message.
  /// It holds two only when a chunk opens a new SysEx while a previous one is
  /// still pending *and* closes the new one as well: the abandoned message is
  /// terminated with a synthesised `0xF7` and returned first, which is the same
  /// repair the other transports' parsers make.
  List<Uint8List> add(Uint8List chunk) {
    final messages = <Uint8List>[];
    if (chunk.isEmpty) {
      return messages;
    }

    for (final byte in chunk) {
      if (byte == 0xF0) {
        // A new message while one is still open means the device never
        // terminated the previous one.
        if (_buffer.isNotEmpty) {
          messages.add(_close());
        }
        _inMessage = true;
      }
      if (!_inMessage) {
        continue;
      }
      _buffer.add(byte);
      if (byte == 0xF7) {
        messages.add(_take());
      } else if (_buffer.length >= _cap - 1) {
        messages.add(_close());
      }
    }

    return messages;
  }

  /// Drops any message in progress.
  void reset() {
    _buffer.clear();
    _inMessage = false;
  }

  /// Takes the assembled message, which already ends with `0xF7`.
  Uint8List _take() {
    final message = Uint8List.fromList(_buffer);
    _buffer.clear();
    _inMessage = false;
    return message;
  }

  /// Terminates an unfinished message with a synthesised `0xF7` and takes it.
  Uint8List _close() {
    _buffer.add(0xF7);
    return _take();
  }
}
