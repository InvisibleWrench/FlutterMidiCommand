import 'dart:typed_data';

import 'package:flutter_midi_command/flutter_midi_command_messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MidiMessage parser', () {
    test('parses Note On', () {
      final messages = MidiMessage.parse(Uint8List.fromList([0x90, 60, 100]));

      expect(messages, hasLength(1));
      final message = messages.single as NoteOnMessage;
      expect(message.channel, 0);
      expect(message.note, 60);
      expect(message.velocity, 100);
      expect(message.data, Uint8List.fromList([0x90, 60, 100]));
    });

    test('parses Note Off', () {
      final messages = MidiMessage.parse(Uint8List.fromList([0x81, 62, 12]));

      expect(messages, hasLength(1));
      final message = messages.single as NoteOffMessage;
      expect(message.channel, 1);
      expect(message.note, 62);
      expect(message.velocity, 12);
      expect(message.data, Uint8List.fromList([0x81, 62, 12]));
    });

    test('parses CC', () {
      final messages = MidiMessage.parse(Uint8List.fromList([0xB2, 7, 127]));

      expect(messages, hasLength(1));
      final message = messages.single as CCMessage;
      expect(message.channel, 2);
      expect(message.controller, 7);
      expect(message.value, 127);
      expect(message.data, Uint8List.fromList([0xB2, 7, 127]));
    });

    test('parses Program Change', () {
      final messages = MidiMessage.parse(Uint8List.fromList([0xC3, 10]));

      expect(messages, hasLength(1));
      final message = messages.single as PCMessage;
      expect(message.channel, 3);
      expect(message.program, 10);
      expect(message.data, Uint8List.fromList([0xC3, 10]));
    });

    test('parses Polyphonic Aftertouch', () {
      final messages = MidiMessage.parse(Uint8List.fromList([0xA2, 64, 70]));

      expect(messages, hasLength(1));
      final message = messages.single as PolyATMessage;
      expect(message.channel, 2);
      expect(message.note, 64);
      expect(message.pressure, 70);
      expect(message.data, Uint8List.fromList([0xA2, 64, 70]));
    });

    test('parses Channel Aftertouch', () {
      final messages = MidiMessage.parse(Uint8List.fromList([0xD1, 55]));

      expect(messages, hasLength(1));
      final message = messages.single as ATMessage;
      expect(message.channel, 1);
      expect(message.pressure, 55);
      expect(message.data, Uint8List.fromList([0xD1, 55]));
    });

    test('parses Pitch Bend', () {
      final messages = MidiMessage.parse(
        Uint8List.fromList([0xE0, 0x00, 0x40]),
      );

      expect(messages, hasLength(1));
      final message = messages.single as PitchBendMessage;
      expect(message.channel, 0);
      expect(message.bend, closeTo(0.0, 0.001));
      expect(message.data, Uint8List.fromList([0xE0, 0x00, 0x40]));
    });

    test('parses SysEx', () {
      final bytes = Uint8List.fromList([0xF0, 0x7D, 0x01, 0x02, 0xF7]);
      final messages = MidiMessage.parse(bytes);

      expect(messages, hasLength(1));
      final message = messages.single as SysExMessage;
      expect(message.data, bytes);
      expect(message.rawData, bytes);
    });

    test('parses NRPN with MSB + LSB data entry', () {
      final messages = MidiMessage.parse(
        Uint8List.fromList([
          0xB0, 0x63, 0x01, // NRPN param MSB
          0xB0, 0x62, 0x02, // NRPN param LSB
          0xB0, 0x06, 0x03, // Data Entry MSB
          0xB0, 0x26, 0x04, // Data Entry LSB
        ]),
      );

      expect(messages, hasLength(1));
      final message = messages.single as NRPN4Message;
      expect(message.channel, 0);
      expect(message.parameter, 130);
      expect(message.value, (3 << 7) | 4);
      expect(
        message.data,
        Uint8List.fromList([
          0xB0,
          0x63,
          0x01,
          0x62,
          0x02,
          0x06,
          0x03,
          0x26,
          0x04,
        ]),
      );
    });

    test('parses NRPN with single data byte (MSB only)', () {
      final messages = MidiMessage.parse(
        Uint8List.fromList([
          0xB0, 0x63, 0x05, // NRPN param MSB
          0xB0, 0x62, 0x06, // NRPN param LSB
          0xB0, 0x06, 0x40, // Data Entry MSB only
        ]),
      );

      expect(messages, hasLength(1));
      final message = messages.single as NRPN3Message;
      expect(message.channel, 0);
      expect(message.parameter, (0x05 << 7) | 0x06);
      expect(message.value, 0x40);
      expect(
        message.data,
        Uint8List.fromList([0xB0, 0x63, 0x05, 0x62, 0x06, 0x06, 0x40]),
      );
    });

    test('parses NRPN null message', () {
      final messages = MidiMessage.parse(
        Uint8List.fromList([0xB0, 0x63, 0x7F, 0xB0, 0x62, 0x7F]),
      );

      expect(messages, hasLength(1));
      expect(messages.single, isA<NRPNNullMessage>());
    });

    test('parses RPN with MSB + LSB data entry', () {
      final messages = MidiMessage.parse(
        Uint8List.fromList([
          0xB0, 0x65, 0x00, // RPN param MSB
          0xB0, 0x64, 0x01, // RPN param LSB
          0xB0, 0x06, 0x02, // Data Entry MSB
          0xB0, 0x26, 0x03, // Data Entry LSB
        ]),
      );

      expect(messages, hasLength(1));
      final message = messages.single as RPNMessage;
      expect(message.channel, 0);
      expect(message.parameter, 1);
      expect(message.value, (2 << 7) | 3);
    });

    test('parses RPN with single data byte (MSB only)', () {
      final messages = MidiMessage.parse(
        Uint8List.fromList([
          0xB0,
          0x65,
          0x00,
          0xB0,
          0x64,
          0x02,
          0xB0,
          0x06,
          0x11,
        ]),
      );

      expect(messages, hasLength(1));
      final message = messages.single as RPNHexMessage;
      expect(message.channel, 0);
      expect(message.parameterMSB, 0x00);
      expect(message.parameterLSB, 0x02);
      expect(message.valueMSB, 0x11);
      expect(message.valueLSB, -1);
    });

    test('parses RPN null message', () {
      final messages = MidiMessage.parse(
        Uint8List.fromList([0xB0, 0x65, 0x7F, 0xB0, 0x64, 0x7F]),
      );

      expect(messages, hasLength(1));
      expect(messages.single, isA<RPNNullMessage>());
    });

    test('parses clock realtime messages', () {
      final messages = MidiMessage.parse(
        Uint8List.fromList([0xF8, 0xFA, 0xFB, 0xFC]),
      );

      expect(messages, hasLength(4));
      expect((messages[0] as ClockMessage).type, ClockType.beat);
      expect((messages[1] as ClockMessage).type, ClockType.start);
      expect((messages[2] as ClockMessage).type, ClockType.cont);
      expect((messages[3] as ClockMessage).type, ClockType.stop);
    });

    test('parses active sensing realtime message', () {
      final messages = MidiMessage.parse(Uint8List.fromList([0xFE]));

      expect(messages, hasLength(1));
      expect(messages.single, isA<SenseMessage>());
    });

    test('supports running status for note messages', () {
      final messages = MidiMessage.parse(
        Uint8List.fromList([
          0x90, 60, 100, // Note On status + first message
          61, 110, // running status Note On
          62, 0, // running status Note On w/ velocity 0 -> Note Off
        ]),
      );

      expect(messages, hasLength(3));
      expect(messages[0], isA<NoteOnMessage>());
      expect(messages[1], isA<NoteOnMessage>());
      expect(messages[2], isA<NoteOffMessage>());
    });

    test('supports running status for one-byte messages (Program Change)', () {
      final messages = MidiMessage.parse(
        Uint8List.fromList([
          0xC2, 10, // Program Change status + first message
          11, // running status Program Change
          12, // running status Program Change
        ]),
      );

      expect(messages, hasLength(3));
      expect((messages[0] as PCMessage).program, 10);
      expect((messages[1] as PCMessage).program, 11);
      expect((messages[2] as PCMessage).program, 12);
    });

    test('realtime bytes are emitted and do not break channel messages', () {
      final messages = MidiMessage.parse(
        Uint8List.fromList([
          0x90, 60, // start Note On
          0xF8, // interleaved realtime clock
          100, // complete Note On
        ]),
      );

      expect(messages, hasLength(2));
      expect(messages[0], isA<ClockMessage>());
      expect(messages[1], isA<NoteOnMessage>());
    });

    test('realtime bytes are emitted and do not break SysEx parsing', () {
      final messages = MidiMessage.parse(
        Uint8List.fromList([
          0xF0, 0x7D, // start SysEx
          0xF8, // interleaved realtime clock
          0x01, 0xF7, // continue and finish SysEx
        ]),
      );

      expect(messages, hasLength(2));
      expect(messages[0], isA<ClockMessage>());
      final sysEx = messages[1] as SysExMessage;
      expect(sysEx.data, Uint8List.fromList([0xF0, 0x7D, 0x01, 0xF7]));
    });

    test('ignores malformed trailing bytes for incomplete channel message', () {
      final messages = MidiMessage.parse(Uint8List.fromList([0x90, 60]));
      expect(messages, isEmpty);
    });

    test('can complete split channel messages across parser invocations', () {
      final parser = MidiMessageParser();

      final first = parser.parse(
        Uint8List.fromList([0x90, 60]),
        flushPendingNrpn: false,
      );
      final second = parser.parse(Uint8List.fromList([100]));

      expect(first, isEmpty);
      expect(second, hasLength(1));
      final message = second.single as NoteOnMessage;
      expect(message.note, 60);
      expect(message.velocity, 100);
    });

    test('can complete split SysEx messages across parser invocations', () {
      final parser = MidiMessageParser();

      final first = parser.parse(
        Uint8List.fromList([0xF0, 0x7D, 0x01]),
        flushPendingNrpn: false,
      );
      final second = parser.parse(Uint8List.fromList([0x02, 0xF7]));

      expect(first, isEmpty);
      expect(second, hasLength(1));
      final message = second.single as SysExMessage;
      expect(message.data, Uint8List.fromList([0xF0, 0x7D, 0x01, 0x02, 0xF7]));
    });

    test('ignores stray data bytes when no running status exists', () {
      final messages = MidiMessage.parse(Uint8List.fromList([60, 100, 0xFE]));
      expect(messages, hasLength(1));
      expect(messages.single, isA<SenseMessage>());
    });

    test('ignores stray EOX outside SysEx and recovers', () {
      final messages = MidiMessage.parse(
        Uint8List.fromList([0xF7, 0x90, 60, 100]),
      );
      expect(messages, hasLength(1));
      expect(messages.single, isA<NoteOnMessage>());
    });

    test('ignores unsupported system common events and recovers', () {
      final messages = MidiMessage.parse(
        Uint8List.fromList([
          0xF2, 0x01, 0x02, // Song Position Pointer (unsupported typed mapping)
          0xF6, // Tune Request (unsupported typed mapping)
          0x90, 60, 100, // Valid note event after unsupported events
        ]),
      );

      expect(messages, hasLength(1));
      expect(messages.single, isA<NoteOnMessage>());
    });

    test('system common status clears running status', () {
      final messages = MidiMessage.parse(
        Uint8List.fromList([
          0x90, 60, 100, // valid Note On
          0xF1, 0x7F, // system common event (unsupported typed mapping)
          61, 110, // data bytes should not use old Note On running status
        ]),
      );

      expect(messages, hasLength(1));
      expect(messages.single, isA<NoteOnMessage>());
    });

    test('ignores undefined realtime bytes and continues parsing', () {
      final messages = MidiMessage.parse(
        Uint8List.fromList([
          0xF9, // undefined realtime
          0x90, 60, 100, // valid Note On
          0xFD, // undefined realtime
          0xFF, // system reset (currently not typed)
          0xFE, // active sensing
        ]),
      );

      expect(messages, hasLength(2));
      expect(messages[0], isA<NoteOnMessage>());
      expect(messages[1], isA<SenseMessage>());
    });

    test('new status byte aborts incomplete message and starts fresh', () {
      final messages = MidiMessage.parse(
        Uint8List.fromList([
          0x90, 60, // incomplete Note On
          0x91, 61, 110, // new status + complete Note On on channel 1
        ]),
      );

      expect(messages, hasLength(1));
      final noteOn = messages.single as NoteOnMessage;
      expect(noteOn.channel, 1);
      expect(noteOn.note, 61);
      expect(noteOn.velocity, 110);
    });

    test('system common events consume payload and parser recovers', () {
      final messages = MidiMessage.parse(
        Uint8List.fromList([
          0xF1, 0x7F, // MTC quarter frame
          0xF3, 0x01, // song select
          0xF2, 0x00, 0x20, // song position pointer
          0x90, 60, 100, // valid Note On after system common events
        ]),
      );

      expect(messages, hasLength(1));
      expect(messages.single, isA<NoteOnMessage>());
    });

    test('sysex start clears running status after sysex completion', () {
      final messages = MidiMessage.parse(
        Uint8List.fromList([
          0x90, 60, 100, // first Note On
          61, 110, // running status Note On
          0xF0, 0x7D, 0xF7, // SysEx start/end clears running status
          62, 120, // stray data should not emit a third Note On
        ]),
      );

      expect(messages, hasLength(3));
      expect(messages[0], isA<NoteOnMessage>());
      expect(messages[1], isA<NoteOnMessage>());
      expect(messages[2], isA<SysExMessage>());
    });

    test('reset clears pending parser state', () {
      final parser = MidiMessageParser();

      final first = parser.parse(
        Uint8List.fromList([0x90, 60]),
        flushPendingNrpn: false,
      );
      parser.reset();
      final second = parser.parse(Uint8List.fromList([100]));

      expect(first, isEmpty);
      expect(second, isEmpty);
    });
  });

  group('MidiMessage generateData', () {
    test('generates Note On bytes', () {
      final message = NoteOnMessage(channel: 2, note: 64, velocity: 100);
      expect(message.generateData(), Uint8List.fromList([0x92, 64, 100]));
    });

    test('generates Note Off bytes', () {
      final message = NoteOffMessage(channel: 3, note: 64, velocity: 0);
      expect(message.generateData(), Uint8List.fromList([0x83, 64, 0]));
    });

    test('generates CC bytes', () {
      final message = CCMessage(channel: 1, controller: 74, value: 99);
      expect(message.generateData(), Uint8List.fromList([0xB1, 74, 99]));
    });

    test('generates Program Change bytes', () {
      final message = PCMessage(channel: 5, program: 10);
      expect(message.generateData(), Uint8List.fromList([0xC5, 10]));
    });

    test('generates Pitch Bend bytes', () {
      final message = PitchBendMessage(channel: 0, bend: 0);
      expect(message.generateData(), Uint8List.fromList([0xE0, 0x00, 0x40]));
    });

    test('generates NRPN3 bytes', () {
      final message = NRPN3Message(channel: 0, parameter: 130, value: 5);
      expect(
        message.generateData(),
        Uint8List.fromList([0xB0, 0x63, 0x01, 0x62, 0x02, 0x06, 0x05]),
      );
    });

    test('generates NRPN4 bytes', () {
      final message = NRPN4Message(channel: 0, parameter: 130, value: 0x0344);
      expect(
        message.generateData(),
        Uint8List.fromList([
          0xB0,
          0x63,
          0x01,
          0x62,
          0x02,
          0x06,
          0x06,
          0x26,
          0x44,
        ]),
      );
    });

    test('generates raw SysEx bytes unchanged', () {
      final message = SysExMessage(rawData: [0xF0, 0x7D, 0x10, 0xF7]);
      expect(
        message.generateData(),
        Uint8List.fromList([0xF0, 0x7D, 0x10, 0xF7]),
      );
    });

    test('generates NRPN hex with optional LSB', () {
      final withLsb = NRPNHexMessage(
        channel: 0,
        parameterMSB: 0x01,
        parameterLSB: 0x02,
        valueMSB: 0x03,
        valueLSB: 0x04,
      );
      expect(
        withLsb.generateData(),
        Uint8List.fromList([
          0xB0,
          0x63,
          0x01,
          0x62,
          0x02,
          0x06,
          0x03,
          0x26,
          0x04,
        ]),
      );

      final msbOnly = NRPNHexMessage(
        channel: 0,
        parameterMSB: 0x01,
        parameterLSB: 0x02,
        valueMSB: 0x03,
      );
      expect(
        msbOnly.generateData(),
        Uint8List.fromList([0xB0, 0x63, 0x01, 0x62, 0x02, 0x06, 0x03]),
      );
    });

    test('generates NRPN null bytes', () {
      final message = NRPNNullMessage(channel: 3);
      expect(
        message.generateData(),
        Uint8List.fromList([0xB3, 0x63, 0x7F, 0xB3, 0x62, 0x7F]),
      );
    });

    test('generates RPN bytes', () {
      final message = RPNMessage(channel: 1, parameter: 130, value: 300);
      expect(
        message.generateData(),
        Uint8List.fromList([
          0xB1,
          0x65,
          0x01,
          0xB1,
          0x64,
          0x02,
          0xB1,
          0x06,
          0x02,
          0xB1,
          0x26,
          0x2C,
        ]),
      );
    });

    test('generates RPN hex bytes', () {
      final withLsb = RPNHexMessage(
        channel: 0,
        parameterMSB: 0x00,
        parameterLSB: 0x02,
        valueMSB: 0x11,
        valueLSB: 0x22,
      );
      expect(
        withLsb.generateData(),
        Uint8List.fromList([
          0xB0,
          0x65,
          0x00,
          0xB0,
          0x64,
          0x02,
          0xB0,
          0x06,
          0x11,
          0xB0,
          0x26,
          0x22,
        ]),
      );

      final msbOnly = RPNHexMessage(
        channel: 0,
        parameterMSB: 0x00,
        parameterLSB: 0x02,
        valueMSB: 0x11,
      );
      expect(
        msbOnly.generateData(),
        Uint8List.fromList([
          0xB0,
          0x65,
          0x00,
          0xB0,
          0x64,
          0x02,
          0xB0,
          0x06,
          0x11,
        ]),
      );
    });

    test('generates RPN null bytes', () {
      final message = RPNNullMessage(channel: 2);
      expect(
        message.generateData(),
        Uint8List.fromList([0xB2, 0x65, 0x7F, 0xB2, 0x64, 0x7F]),
      );
    });

    test('generates PolyAT bytes', () {
      final message = PolyATMessage(channel: 4, note: 60, pressure: 99);
      expect(message.generateData(), Uint8List.fromList([0xA4, 60, 99]));
    });

    test('generates AT bytes', () {
      final message = ATMessage(channel: 3, pressure: 88);
      expect(message.generateData(), Uint8List.fromList([0xD3, 88]));
    });

    test('generates Sense bytes', () {
      final message = SenseMessage();
      expect(message.generateData(), Uint8List.fromList([0xFE]));
    });

    test('generates Clock bytes', () {
      expect(
        ClockMessage(type: ClockType.beat).generateData(),
        Uint8List.fromList([0xF8]),
      );
      expect(
        ClockMessage(type: ClockType.start).generateData(),
        Uint8List.fromList([0xFA]),
      );
      expect(
        ClockMessage(type: ClockType.cont).generateData(),
        Uint8List.fromList([0xFB]),
      );
      expect(
        ClockMessage(type: ClockType.stop).generateData(),
        Uint8List.fromList([0xFC]),
      );
    });
  });
}
