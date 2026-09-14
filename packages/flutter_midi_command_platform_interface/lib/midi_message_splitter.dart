import 'dart:typed_data';

/// Splits a stream of MIDI bytes into complete messages.
///
/// This is the shared MIDI-assembly stage every transport in this plugin feeds,
/// once it has stripped its own framing. It resolves running status, keeps
/// partial messages across calls, and reassembles SysEx, so that each message
/// handed to [onMessage] satisfies the `MidiPacket.data` contract: exactly one
/// complete MIDI message, `0xF0 ... 0xF7` for SysEx and a single byte for
/// System Real-Time.
///
/// The rules below are numbered, and the same numbers appear in the Kotlin and
/// Swift ports (`MidiPacketParser.kt` / `.swift`) so the three implementations
/// can be reviewed against one spec.
///
/// 1. System Real-Time (`0xF8`-`0xFF`) is handled first, in every state, and
///    mutates nothing else — not the running status, not a partial message, not
///    a SysEx in progress. It is emitted immediately, including between the
///    data bytes of another message and from inside a SysEx. `0xF9` and `0xFD`
///    are undefined and are swallowed, but they disturb no state either.
/// 2. A channel voice status byte (`0x80`-`0xEF`) latches the running status,
///    discards any incomplete message and starts a new one.
/// 3. System Common `0xF1`/`0xF2`/`0xF3` *clears* the running status and starts
///    a new message; `0xF6` clears it and is emitted immediately.
/// 4. `0xF0` clears the running status and opens a SysEx. Inside a SysEx any
///    non-real-time status byte aborts it: a `0xF7` is synthesised, the message
///    is emitted, and the offending byte is then re-dispatched. [maxSysExLength]
///    does the same, so a device that never sends `0xF7` cannot wedge the
///    stream.
/// 5. `0xF7` outside a SysEx, and `0xF4`/`0xF5`, clear the running status and
///    emit nothing. A status byte is never latched before it has been
///    classified.
/// 6. A data byte extends the message in flight, or revives the running status
///    when there is none. A message is emitted when it reaches its expected
///    length exactly. Data with neither is dropped.
/// 7. After an emission the partial message is cleared but the running status
///    survives. Emitted messages are always copies; the internal buffers are
///    never handed out.
/// 8. [reset] clears all state, and transports call it on disconnect.
class MidiMessageSplitter {
  /// Creates a splitter delivering complete messages to [onMessage].
  ///
  /// [onMessage] receives the message bytes and the timestamp that was passed
  /// to the [parse] call carrying the byte which completed it.
  ///
  /// [maxSysExLength] bounds an unterminated SysEx, counting the opening
  /// `0xF0` and the synthesised `0xF7`. Values below 2 are treated as 2.
  MidiMessageSplitter({required this.onMessage, this.maxSysExLength = 65536});

  /// Called once per complete MIDI message.
  final void Function(Uint8List message, int timestamp) onMessage;

  /// Largest SysEx this splitter will assemble before force-terminating it.
  final int maxSysExLength;

  /// The last channel voice status byte, or `null` when running status has been
  /// cleared. Only ever holds `0x80`-`0xEF` (rule 2, rule 3).
  int? _runningStatus;

  /// The message being assembled, including its status byte. Non-empty exactly
  /// when [_expectedLength] is non-zero.
  final List<int> _pending = [];

  /// Total length [_pending] must reach, or 0 when no message is in flight.
  int _expectedLength = 0;

  bool _inSysEx = false;
  final List<int> _sysExBuffer = [];

  int get _sysExCap => maxSysExLength < 2 ? 2 : maxSysExLength;

  /// Feeds [bytes] to the splitter, stamping any message they complete with
  /// [timestamp].
  void parse(List<int> bytes, int timestamp) {
    for (final byte in bytes) {
      final b = byte & 0xFF;

      // Rule 1: System Real-Time, before anything else can touch state.
      if (b >= 0xF8) {
        if (b != 0xF9 && b != 0xFD) {
          onMessage(Uint8List.fromList(<int>[b]), timestamp);
        }
        continue;
      }

      if (b >= 0x80) {
        _handleStatus(b, timestamp);
      } else {
        _handleData(b, timestamp);
      }
    }
  }

  /// Drops every partial message, the running status and any SysEx in progress.
  void reset() {
    _runningStatus = null;
    _pending.clear();
    _expectedLength = 0;
    _inSysEx = false;
    _sysExBuffer.clear();
  }

  /// Handles a status byte in `0x80`-`0xF7`. Real-time bytes never reach here.
  void _handleStatus(int b, int timestamp) {
    if (_inSysEx) {
      // Rule 4: 0xF7 terminates normally, any other status byte aborts — both
      // close the message with a 0xF7. The aborting byte is re-dispatched
      // below.
      _closeSysEx(timestamp);
      if (b == 0xF7) {
        return;
      }
    }

    if (b < 0xF0) {
      // Rule 2: channel voice.
      _runningStatus = b;
      _startMessage(b, _lengthOfChannelMessage(b), timestamp);
      return;
    }

    // Rules 3-5: everything from 0xF0 clears the running status.
    _runningStatus = null;
    switch (b) {
      case 0xF0:
        _pending.clear();
        _expectedLength = 0;
        _inSysEx = true;
        _sysExBuffer
          ..clear()
          ..add(0xF0);
        _capSysEx(timestamp);
      case 0xF1: // MIDI Time Code quarter frame
      case 0xF3: // Song Select
        _startMessage(b, 2, timestamp);
      case 0xF2: // Song Position Pointer
        _startMessage(b, 3, timestamp);
      case 0xF6: // Tune Request
        _pending.clear();
        _expectedLength = 0;
        onMessage(Uint8List.fromList(<int>[b]), timestamp);
      default: // 0xF4, 0xF5 (undefined) and a stray 0xF7.
        _pending.clear();
        _expectedLength = 0;
    }
  }

  /// Handles a data byte, `0x00`-`0x7F`.
  void _handleData(int b, int timestamp) {
    if (_inSysEx) {
      _sysExBuffer.add(b);
      _capSysEx(timestamp);
      return;
    }

    // Rule 6: extend the message in flight, else revive the running status.
    if (_expectedLength == 0) {
      final status = _runningStatus;
      if (status == null) {
        return;
      }
      _pending
        ..clear()
        ..add(status);
      _expectedLength = _lengthOfChannelMessage(status);
    }

    _pending.add(b);
    if (_pending.length == _expectedLength) {
      _emitPending(timestamp);
    }
  }

  void _startMessage(int status, int length, int timestamp) {
    _pending
      ..clear()
      ..add(status);
    _expectedLength = length;
    if (_pending.length == _expectedLength) {
      _emitPending(timestamp);
    }
  }

  // Rule 7: emit a copy, clear the partial message, keep the running status.
  void _emitPending(int timestamp) {
    onMessage(Uint8List.fromList(_pending), timestamp);
    _pending.clear();
    _expectedLength = 0;
  }

  /// Terminates the SysEx in progress with a `0xF7` and emits it.
  void _closeSysEx(int timestamp) {
    _sysExBuffer.add(0xF7);
    onMessage(Uint8List.fromList(_sysExBuffer), timestamp);
    _sysExBuffer.clear();
    _inSysEx = false;
  }

  void _capSysEx(int timestamp) {
    if (_sysExBuffer.length >= _sysExCap - 1) {
      _closeSysEx(timestamp);
    }
  }

  static int _lengthOfChannelMessage(int status) {
    final high = status & 0xF0;
    // Program Change and Channel Pressure carry one data byte; everything else
    // in 0x80-0xEF carries two.
    return (high == 0xC0 || high == 0xD0) ? 2 : 3;
  }
}
