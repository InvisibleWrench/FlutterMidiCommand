import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';

void main() {
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(body: HomeView()),
    );
  }
}

class HomeView extends StatefulWidget {
  const HomeView({super.key});

  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> {
  final midi = MidiCommand();

  @override
  void initState() {
    super.initState();
    midi.onMidiSetupChanged?.listen((_) => _updateSetup());
    _updateSetup();
  }

  void _updateSetup() async {
    final devices = await midi.devices ?? [];
    for (final device in devices) {
      if (!device.connected) {
        try {
          await midi.connectToDevice(device);
        } catch (_) {
          debugPrint('Could not connect to device: $device');
        }
      }
    }
  }

  void _sendEmptySysex(int length) {
    final data = Uint8List(length);
    data[0] = 0xF0;
    data[length - 1] = 0xF7;
    midi.sendData(data);
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [256, 512, 768, 1024]
            .map(
              (e) => Padding(
            padding: const EdgeInsets.all(8.0),
            child: ElevatedButton(
              onPressed: () => _sendEmptySysex(e),
              child: Text('Send $e bytes'),
            ),
          ),
        )
            .toList(),
      ),
    );
  }
}
