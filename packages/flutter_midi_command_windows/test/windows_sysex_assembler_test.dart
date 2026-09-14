import 'dart:typed_data';

import 'package:flutter_midi_command_windows/src/windows_sysex_assembler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Uint8List chunk(List<int> bytes) => Uint8List.fromList(bytes);

  List<List<int>> add(WindowsSysExAssembler assembler, List<int> bytes) =>
      assembler.add(chunk(bytes)).map((m) => m.toList()).toList();

  test('assembles a SysEx spanning several chunks', () {
    final assembler = WindowsSysExAssembler();

    expect(add(assembler, [0xF0, 0x01, 0x02]), isEmpty);
    expect(add(assembler, [0x03, 0x04]), isEmpty);
    expect(add(assembler, [0x05, 0xF7]), [
      [0xF0, 0x01, 0x02, 0x03, 0x04, 0x05, 0xF7],
    ], reason: 'only the last chunk used to be delivered');
  });

  test('delivers a SysEx contained in one chunk', () {
    expect(add(WindowsSysExAssembler(), [0xF0, 0x01, 0xF7]), [
      [0xF0, 0x01, 0xF7],
    ]);
  });

  test('delivers two SysEx messages arriving in one chunk', () {
    expect(add(WindowsSysExAssembler(), [0xF0, 0x01, 0xF7, 0xF0, 0x02, 0xF7]), [
      [0xF0, 0x01, 0xF7],
      [0xF0, 0x02, 0xF7],
    ]);
  });

  test('terminates an abandoned message when a new one starts', () {
    final assembler = WindowsSysExAssembler();

    expect(add(assembler, [0xF0, 0x01, 0x02]), isEmpty);
    expect(add(assembler, [0xF0, 0x03, 0xF7]), [
      [0xF0, 0x01, 0x02, 0xF7],
      [0xF0, 0x03, 0xF7],
    ]);
  });

  test('caps a message the device never terminates, then recovers', () {
    final assembler = WindowsSysExAssembler(maxLength: 64);

    final messages = add(assembler, [0xF0, ...List<int>.filled(70000, 0x01)]);

    expect(messages, hasLength(1), reason: 'one capped frame, not a torrent');
    expect(messages.single, hasLength(64));
    expect(messages.single.first, 0xF0);
    expect(messages.single.last, 0xF7);
    expect(
      add(assembler, [0xF0, 0x02, 0xF7]),
      [
        [0xF0, 0x02, 0xF7],
      ],
      reason: 'the assembler keeps working after the cap',
    );
  });

  test('reset drops a message in progress', () {
    final assembler = WindowsSysExAssembler();

    add(assembler, [0xF0, 0x01]);
    assembler.reset();

    expect(
      add(assembler, [0x02, 0xF7]),
      isEmpty,
      reason: 'the abandoned 0xF0 0x01 is gone, and a headless tail is dropped',
    );
  });

  test('an empty chunk yields nothing', () {
    expect(add(WindowsSysExAssembler(), []), isEmpty);
  });

  test('two assemblers do not share state', () {
    // The buffer used to be a file-global, so two devices receiving SysEx at
    // the same time interleaved into each other's message.
    final a = WindowsSysExAssembler();
    final b = WindowsSysExAssembler();

    add(a, [0xF0, 0x01]);
    add(b, [0xF0, 0x0A]);

    expect(add(a, [0x02, 0xF7]), [
      [0xF0, 0x01, 0x02, 0xF7],
    ]);
    expect(add(b, [0x0B, 0xF7]), [
      [0xF0, 0x0A, 0x0B, 0xF7],
    ]);
  });

  test('each delivered message is an independent copy', () {
    final assembler = WindowsSysExAssembler();
    final first = assembler.add(chunk([0xF0, 0x01, 0xF7])).single;
    first[1] = 0x7F;

    expect(assembler.add(chunk([0xF0, 0x02, 0xF7])).single, [0xF0, 0x02, 0xF7]);
  });
}
