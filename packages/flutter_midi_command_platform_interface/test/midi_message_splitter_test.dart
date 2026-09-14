import 'dart:typed_data';

import 'package:flutter_midi_command_platform_interface/midi_message_splitter.dart';
import 'package:flutter_test/flutter_test.dart';

/// The shared conformance table. The same cases exist in `MidiPacketParserTest.kt`
/// and `MidiPacketParserTests.swift`, so the three implementations answer to one
/// spec.
void main() {
  late List<List<int>> received;
  late List<int> timestamps;
  late MidiMessageSplitter splitter;

  setUp(() {
    received = [];
    timestamps = [];
    splitter = MidiMessageSplitter(
      onMessage: (message, timestamp) {
        received.add(message.toList());
        timestamps.add(timestamp);
      },
    );
  });

  void feed(List<int> bytes, {int timestamp = 0}) =>
      splitter.parse(bytes, timestamp);

  group('running status', () {
    test('splits a running-status Note On run into separate messages', () {
      // The core of issue #179: an M-VAVE SMK-25 sends the status byte once.
      feed([0x90, 0x3C, 0x64, 0x40, 0x7F, 0x42, 0x50]);

      expect(received, [
        [0x90, 0x3C, 0x64],
        [0x90, 0x40, 0x7F],
        [0x90, 0x42, 0x50],
      ]);
    });

    test('resolves running status for two-byte messages', () {
      feed([0xC0, 0x01, 0x02, 0x03]);

      expect(received, [
        [0xC0, 0x01],
        [0xC0, 0x02],
        [0xC0, 0x03],
      ]);
    });

    test('survives a clock between two messages', () {
      feed([0x90, 0x3C, 0x64, 0xF8, 0x40, 0x7F]);

      expect(received, [
        [0x90, 0x3C, 0x64],
        [0xF8],
        [0x90, 0x40, 0x7F],
      ]);
    });

    test('is cleared by System Common', () {
      feed([0x90, 0x3C, 0x64, 0xF1, 0x25, 0x40, 0x7F]);

      expect(received, [
        [0x90, 0x3C, 0x64],
        [0xF1, 0x25],
      ], reason: 'the trailing 40 7F has no status to revive');
    });

    test('drops leading orphan data bytes', () {
      feed([0x40, 0x7F, 0x90, 0x3C, 0x64]);

      expect(received, [
        [0x90, 0x3C, 0x64],
      ]);
    });
  });

  group('system real-time', () {
    test('is emitted between a status byte and its data', () {
      feed([0x90, 0xF8, 0x3C, 0x64]);

      expect(received, [
        [0xF8],
        [0x90, 0x3C, 0x64],
      ]);
    });

    test('is emitted between two data bytes', () {
      feed([0x90, 0x3C, 0xFE, 0x64]);

      expect(received, [
        [0xFE],
        [0x90, 0x3C, 0x64],
      ], reason: 'the clock must not become the velocity');
    });

    test('undefined F9/FD are swallowed but disturb nothing', () {
      feed([0x90, 0x3C, 0xF9, 0x64, 0xFD, 0x40, 0x7F]);

      expect(received, [
        [0x90, 0x3C, 0x64],
        [0x90, 0x40, 0x7F],
      ]);
    });
  });

  group('system common', () {
    test('F2 carries two data bytes', () {
      feed([0xF2, 0x01, 0x02]);

      expect(received, [
        [0xF2, 0x01, 0x02],
      ]);
    });

    test('F3 carries one data byte', () {
      feed([0xF3, 0x05]);

      expect(received, [
        [0xF3, 0x05],
      ]);
    });

    test('F6 is a single byte', () {
      feed([0xF6]);

      expect(received, [
        [0xF6],
      ]);
    });

    test('F4/F5 emit nothing and clear the running status', () {
      feed([0x90, 0x3C, 0x64, 0xF4, 0x40, 0x7F]);

      expect(received, [
        [0x90, 0x3C, 0x64],
      ], reason: 'no [00 ..] message may be synthesised');
    });

    test('a stray F7 emits nothing and clears the running status', () {
      feed([0x90, 0x3C, 0x64, 0xF7, 0x40, 0x7F]);

      expect(received, [
        [0x90, 0x3C, 0x64],
      ]);
    });
  });

  group('sysex', () {
    test('passes a real-time byte through without disturbing the message', () {
      feed([0xF0, 0x01, 0xF8, 0x02, 0xF7]);

      expect(received, [
        [0xF8],
        [0xF0, 0x01, 0x02, 0xF7],
      ]);
    });

    test(
      'is aborted by a channel status byte, which is then re-dispatched',
      () {
        feed([0xF0, 0x01, 0x02, 0x90, 0x3C, 0x64]);

        expect(received, [
          [0xF0, 0x01, 0x02, 0xF7],
          [0x90, 0x3C, 0x64],
        ]);
      },
    );

    test('repairs back-to-back F0', () {
      feed([0xF0, 0x01, 0x02, 0xF0, 0x03, 0xF7]);

      expect(received, [
        [0xF0, 0x01, 0x02, 0xF7],
        [0xF0, 0x03, 0xF7],
      ]);
    });

    test('clears the running status', () {
      feed([0x90, 0x3C, 0x64, 0xF0, 0x01, 0xF7, 0x40, 0x7F]);

      expect(received, [
        [0x90, 0x3C, 0x64],
        [0xF0, 0x01, 0xF7],
      ]);
    });

    test('is capped, and the stream recovers afterwards', () {
      final capped = MidiMessageSplitter(
        onMessage: (m, _) => received.add(m.toList()),
        maxSysExLength: 64,
      );

      capped.parse([0xF0, ...List<int>.filled(70000, 0x01)], 0);
      capped.parse([0x90, 0x3C, 0x64], 0);

      expect(received.first, hasLength(64));
      expect(received.first.first, 0xF0);
      expect(received.first.last, 0xF7);
      expect(received.last, [0x90, 0x3C, 0x64]);
    });

    test('the default cap bounds an unterminated SysEx', () {
      feed([0xF0, ...List<int>.filled(70000, 0x01)]);
      feed([0x90, 0x3C, 0x64]);

      expect(received.first, hasLength(65536));
      expect(received.last, [0x90, 0x3C, 0x64]);
    });
  });

  group('state across calls', () {
    test('a message split across two parse calls emits once', () {
      feed([0x90, 0x3C]);
      expect(received, isEmpty);

      feed([0x64]);
      expect(received, [
        [0x90, 0x3C, 0x64],
      ]);
    });

    test('reset mid-message emits nothing', () {
      feed([0x90, 0x3C]);
      splitter.reset();
      feed([0x64]);

      expect(received, isEmpty, reason: 'reset drops the partial message');
    });

    test('reset clears the running status', () {
      feed([0x90, 0x3C, 0x64]);
      splitter.reset();
      feed([0x40, 0x7F]);

      expect(received, [
        [0x90, 0x3C, 0x64],
      ]);
    });

    test('reset clears a SysEx in progress', () {
      feed([0xF0, 0x01, 0x02]);
      splitter.reset();
      feed([0x03, 0xF7]);

      expect(received, isEmpty);
    });

    test('stamps each message with the timestamp of the completing call', () {
      feed([0x90, 0x3C], timestamp: 10);
      feed([0x64, 0x40, 0x7F], timestamp: 20);

      expect(timestamps, [20, 20]);
    });
  });

  test('emitted messages are independent copies', () {
    feed([0x90, 0x3C, 0x64, 0x40, 0x7F]);

    expect(received, hasLength(2));
    received[0][1] = 0x00;

    expect(received[1], [0x90, 0x40, 0x7F]);
  });

  test('delivers a Uint8List', () {
    late Uint8List first;
    MidiMessageSplitter(
      onMessage: (m, _) => first = m,
    ).parse([0x90, 0x3C, 0x64], 0);

    expect(first, isA<Uint8List>());
  });
}
