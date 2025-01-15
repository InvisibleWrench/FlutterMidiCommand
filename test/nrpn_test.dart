import 'package:flutter/widgets.dart';
import 'package:flutter_midi_command/flutter_midi_command_messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  test("sends an NRPN message with correct data buffer", () {
    final m = NRPNMessage(parameter: 4107, value: 0);

    m.send();

    expect(m.data, hasLength(12));

    expect(m.data[0], equals(0xb0));
    expect(m.data[1], equals(0x63));
    expect(m.data[2], equals(0x20));

    expect(m.data[3], equals(0xb0));
    expect(m.data[4], equals(0x62));
    expect(m.data[5], equals(0x0b));

    expect(m.data[6], equals(0xb0));
    expect(m.data[7], equals(0x06));
    expect(m.data[8], equals(0x00));

    expect(m.data[9], equals(0xb0));
    expect(m.data[10], equals(0x26));
    expect(m.data[11], equals(0x00));
  });
}