part of '../flutter_midi_command_messages.dart';

/// Stateful parser that converts raw MIDI bytes into typed [MidiMessage]s.
///
/// Supports all currently defined typed messages in `flutter_midi_command`:
/// CC, PC, Note On/Off, NRPN, RPN, SysEx, Clock, PolyAT, AT, and Pitch Bend.
class MidiMessageParser {
  final List<_ParameterState> _channelStates = List<_ParameterState>.generate(
    16,
    (_) => _ParameterState(),
  );

  int? _runningStatus;
  int? _currentStatus;
  int _expectedDataLength = 0;
  final List<int> _currentData = <int>[];

  bool _insideSysEx = false;
  final List<int> _sysexBuffer = <int>[];

  /// Parse [bytes] into typed messages.
  ///
  /// Set [flushPendingNrpn] to `false` to preserve partial NRPN/RPN state
  /// across parse calls when packets are split across chunks.
  List<MidiMessage> parse(Uint8List bytes, {bool flushPendingNrpn = true}) {
    final messages = <MidiMessage>[];

    for (final byte in bytes) {
      _consumeByte(byte & 0xFF, messages);
    }

    if (flushPendingNrpn) {
      _flushAllPending(messages);
    }

    return messages;
  }

  /// Clears parser state (running status, SysEx buffer, NRPN/RPN context).
  void reset() {
    _runningStatus = null;
    _currentStatus = null;
    _expectedDataLength = 0;
    _currentData.clear();
    _insideSysEx = false;
    _sysexBuffer.clear();
    for (final state in _channelStates) {
      state.clear();
    }
  }

  void _consumeByte(int byte, List<MidiMessage> messages) {
    // Real-time single-byte messages are valid even while inside SysEx.
    if (byte >= 0xF8) {
      final realtime = _parseRealtimeByte(byte);
      if (realtime != null) {
        messages.add(realtime);
      }
      return;
    }

    if (_insideSysEx) {
      _sysexBuffer.add(byte);
      if (byte == 0xF7) {
        final message = SysExMessage(rawData: List<int>.from(_sysexBuffer));
        message.data = Uint8List.fromList(_sysexBuffer);
        messages.add(message);
        _sysexBuffer.clear();
        _insideSysEx = false;
      }
      return;
    }

    if (byte == 0xF0) {
      _insideSysEx = true;
      _sysexBuffer
        ..clear()
        ..add(byte);
      _currentStatus = null;
      _currentData.clear();
      _expectedDataLength = 0;
      _runningStatus = null;
      return;
    }

    if ((byte & 0x80) != 0) {
      _currentStatus = byte;
      _currentData.clear();
      _expectedDataLength = _dataLengthForStatus(byte);

      if (byte < 0xF0) {
        _runningStatus = byte;
      } else {
        _runningStatus = null;
      }

      if (_expectedDataLength == 0) {
        _currentStatus = null;
      }
      return;
    }

    if (_currentStatus == null) {
      if (_runningStatus == null) {
        return;
      }
      _currentStatus = _runningStatus;
      _expectedDataLength = _dataLengthForStatus(_currentStatus!);
      _currentData.clear();
    }

    _currentData.add(byte & 0x7F);
    if (_currentData.length < _expectedDataLength) {
      return;
    }

    final status = _currentStatus!;
    _emitMessage(status, _currentData, messages);
    _currentData.clear();
    _currentStatus = status < 0xF0 ? _runningStatus : null;
  }

  MidiMessage? _parseRealtimeByte(int byte) {
    switch (byte) {
      case 0xF8:
        final message = ClockMessage(type: ClockType.beat);
        message.data = Uint8List.fromList([byte]);
        return message;
      case 0xFA:
        final message = ClockMessage(type: ClockType.start);
        message.data = Uint8List.fromList([byte]);
        return message;
      case 0xFB:
        final message = ClockMessage(type: ClockType.cont);
        message.data = Uint8List.fromList([byte]);
        return message;
      case 0xFC:
        final message = ClockMessage(type: ClockType.stop);
        message.data = Uint8List.fromList([byte]);
        return message;
      case 0xFE:
        final message = SenseMessage();
        message.data = Uint8List.fromList([byte]);
        return message;
      default:
        return null;
    }
  }

  int _dataLengthForStatus(int status) {
    final statusClass = status & 0xF0;
    switch (statusClass) {
      case 0x80:
      case 0x90:
      case 0xA0:
      case 0xB0:
      case 0xE0:
        return 2;
      case 0xC0:
      case 0xD0:
        return 1;
    }

    switch (status) {
      case 0xF1:
      case 0xF3:
        return 1;
      case 0xF2:
        return 2;
      default:
        return 0;
    }
  }

  void _emitMessage(int status, List<int> payload, List<MidiMessage> messages) {
    final statusClass = status & 0xF0;
    final channel = status & 0x0F;

    if (statusClass != 0xB0 && statusClass >= 0x80 && statusClass <= 0xE0) {
      _flushPendingForChannel(channel, messages);
    }

    switch (statusClass) {
      case 0x80:
        final message = NoteOffMessage(
          channel: channel,
          note: payload[0],
          velocity: payload[1],
        );
        message.data = Uint8List.fromList([status, ...payload]);
        messages.add(message);
        return;

      case 0x90:
        final note = payload[0];
        final velocity = payload[1];
        if (velocity == 0) {
          final message = NoteOffMessage(
            channel: channel,
            note: note,
            velocity: velocity,
          );
          message.data = Uint8List.fromList([status, ...payload]);
          messages.add(message);
        } else {
          final message = NoteOnMessage(
            channel: channel,
            note: note,
            velocity: velocity,
          );
          message.data = Uint8List.fromList([status, ...payload]);
          messages.add(message);
        }
        return;

      case 0xA0:
        final message = PolyATMessage(
          channel: channel,
          note: payload[0],
          pressure: payload[1],
        );
        message.data = Uint8List.fromList([status, ...payload]);
        messages.add(message);
        return;

      case 0xB0:
        messages.addAll(_handleControlChange(channel, payload[0], payload[1]));
        return;

      case 0xC0:
        final message = PCMessage(channel: channel, program: payload[0]);
        message.data = Uint8List.fromList([status, ...payload]);
        messages.add(message);
        return;

      case 0xD0:
        final message = ATMessage(channel: channel, pressure: payload[0]);
        message.data = Uint8List.fromList([status, ...payload]);
        messages.add(message);
        return;

      case 0xE0:
        final rawValue = ((payload[1] & 0x7F) << 7) | (payload[0] & 0x7F);
        final bend = (rawValue / 0x3FFF) * 2.0 - 1.0;
        final message = PitchBendMessage(channel: channel, bend: bend);
        message.data = Uint8List.fromList([status, ...payload]);
        messages.add(message);
        return;
    }
  }

  List<MidiMessage> _handleControlChange(
    int channel,
    int controller,
    int value,
  ) {
    final out = <MidiMessage>[];
    final state = _channelStates[channel];
    final c = controller & 0x7F;
    final v = value & 0x7F;

    switch (c) {
      case 0x63: // NRPN parameter MSB
        _flushPendingForChannel(channel, out);
        state.nrpnParameterMsb = v;
        state.nrpnParameterLsb = null;
        return out;
      case 0x62: // NRPN parameter LSB
        _flushPendingForChannel(channel, out);
        state.nrpnParameterLsb = v;
        if (state.nrpnParameterMsb == 0x7F && state.nrpnParameterLsb == 0x7F) {
          final message = NRPNNullMessage(channel: channel);
          message.data = message.generateData();
          out.add(message);
          state.clearNrpn();
        }
        return out;
      case 0x65: // RPN parameter MSB
        _flushPendingForChannel(channel, out);
        state.rpnParameterMsb = v;
        state.rpnParameterLsb = null;
        return out;
      case 0x64: // RPN parameter LSB
        _flushPendingForChannel(channel, out);
        state.rpnParameterLsb = v;
        if (state.rpnParameterMsb == 0x7F && state.rpnParameterLsb == 0x7F) {
          final message = RPNNullMessage(channel: channel);
          message.data = message.generateData();
          out.add(message);
          state.clearRpn();
        }
        return out;
      case 0x06: // Data Entry MSB
        if (state.hasNrpnParameter) {
          _flushPendingForChannel(channel, out);
          state.pendingNrpnValueMsb = v;
          return out;
        }
        if (state.hasRpnParameter) {
          _flushPendingForChannel(channel, out);
          state.pendingRpnValueMsb = v;
          return out;
        }
        out.add(_ccMessage(channel, c, v));
        return out;
      case 0x26: // Data Entry LSB
        if (state.hasNrpnParameter && state.pendingNrpnValueMsb != null) {
          final message = NRPN4Message(
            channel: channel,
            parameter: state.nrpnParameterValue!,
            value: ((state.pendingNrpnValueMsb! & 0x7F) << 7) | v,
          );
          message.data = message.generateData();
          out.add(message);
          state.pendingNrpnValueMsb = null;
          return out;
        }
        if (state.hasRpnParameter && state.pendingRpnValueMsb != null) {
          final message = RPNMessage(
            channel: channel,
            parameter: state.rpnParameterValue!,
            value: ((state.pendingRpnValueMsb! & 0x7F) << 7) | v,
          );
          message.data = message.generateData();
          out.add(message);
          state.pendingRpnValueMsb = null;
          return out;
        }
        out.add(_ccMessage(channel, c, v));
        return out;
      default:
        _flushPendingForChannel(channel, out);
        out.add(_ccMessage(channel, c, v));
        return out;
    }
  }

  CCMessage _ccMessage(int channel, int controller, int value) {
    final message = CCMessage(
      channel: channel,
      controller: controller,
      value: value,
    );
    message.data = message.generateData();
    return message;
  }

  void _flushPendingForChannel(int channel, List<MidiMessage> out) {
    final pending = _channelStates[channel].buildPendingMessage(channel);
    if (pending != null) {
      out.add(pending);
    }
  }

  void _flushAllPending(List<MidiMessage> out) {
    for (var channel = 0; channel < _channelStates.length; channel += 1) {
      _flushPendingForChannel(channel, out);
    }
  }
}

class _ParameterState {
  int? nrpnParameterMsb;
  int? nrpnParameterLsb;
  int? pendingNrpnValueMsb;

  int? rpnParameterMsb;
  int? rpnParameterLsb;
  int? pendingRpnValueMsb;

  bool get hasNrpnParameter =>
      nrpnParameterMsb != null &&
      nrpnParameterLsb != null &&
      !(nrpnParameterMsb == 0x7F && nrpnParameterLsb == 0x7F);

  int? get nrpnParameterValue =>
      hasNrpnParameter
          ? ((nrpnParameterMsb! & 0x7F) << 7) | (nrpnParameterLsb! & 0x7F)
          : null;

  bool get hasRpnParameter =>
      rpnParameterMsb != null &&
      rpnParameterLsb != null &&
      !(rpnParameterMsb == 0x7F && rpnParameterLsb == 0x7F);

  int? get rpnParameterValue =>
      hasRpnParameter
          ? ((rpnParameterMsb! & 0x7F) << 7) | (rpnParameterLsb! & 0x7F)
          : null;

  MidiMessage? buildPendingMessage(int channel) {
    if (hasNrpnParameter && pendingNrpnValueMsb != null) {
      final message = NRPN3Message(
        channel: channel,
        parameter: nrpnParameterValue!,
        value: pendingNrpnValueMsb!,
      );
      message.data = message.generateData();
      pendingNrpnValueMsb = null;
      return message;
    }

    if (hasRpnParameter && pendingRpnValueMsb != null) {
      final message = RPNHexMessage(
        channel: channel,
        parameterMSB: rpnParameterMsb!,
        parameterLSB: rpnParameterLsb!,
        valueMSB: pendingRpnValueMsb!,
        valueLSB: -1,
      );
      message.data = message.generateData();
      pendingRpnValueMsb = null;
      return message;
    }

    return null;
  }

  void clearNrpn() {
    nrpnParameterMsb = null;
    nrpnParameterLsb = null;
    pendingNrpnValueMsb = null;
  }

  void clearRpn() {
    rpnParameterMsb = null;
    rpnParameterLsb = null;
    pendingRpnValueMsb = null;
  }

  void clear() {
    clearNrpn();
    clearRpn();
  }
}
