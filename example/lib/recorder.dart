import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:csv/csv.dart';
import 'package:file_picker/file_picker.dart';

class MidiRecorder extends ChangeNotifier {
  factory MidiRecorder() {
    _instance ??= MidiRecorder._();
    return _instance!;
  }

  static MidiRecorder? _instance;

  MidiRecorder._();

  bool _recording = false;

  bool get recording => _recording;

  final List<MidiDataReceivedEvent> _messages = [];
  static const int latestMessageLimit = 20;

  List<MidiDataReceivedEvent> get latestMessages {
    final start = _messages.length > latestMessageLimit
        ? _messages.length - latestMessageLimit
        : 0;
    return List<MidiDataReceivedEvent>.unmodifiable(_messages.skip(start));
  }

  StreamSubscription<MidiDataReceivedEvent>? _midiSub;

  startRecording() {
    _recording = true;
    _midiSub?.cancel();
    _midiSub = MidiCommand().onMidiDataReceived?.listen((event) {
      _messages.add(event);
      notifyListeners();
    });
    notifyListeners();
  }

  stopRecording() {
    _recording = false;
    _midiSub?.cancel();
    _midiSub = null;
    notifyListeners();
  }

  exportRecording() async {
    var rows = _messages
        .map(
          (event) => [
            event.timestamp,
            ...event.message.data.map((byte) => byte.toString()),
          ],
        )
        .toList();

    var csv = const ListToCsvConverter().convert(rows);

    String? outputFile = await FilePicker.platform.saveFile(
      dialogTitle: 'Please select an output file:',
      fileName: 'midi_recording.csv',
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );

    if (outputFile == null) {
      // User canceled the picker
    } else {
      await File(outputFile).writeAsString(csv);
    }

    print("recording exported");
  }

  clearRecording() {
    _messages.clear();
    notifyListeners();
  }
}

class MidiRecorderPanel extends StatelessWidget {
  const MidiRecorderPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final recorder = MidiRecorder();

    return AnimatedBuilder(
      animation: recorder,
      builder: (context, _) {
        final latestMessages = recorder.latestMessages.reversed.toList();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                children: [
                  Text(
                    "Recorder",
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const Spacer(),
                  Switch(
                    value: recorder.recording,
                    onChanged: (newValue) {
                      if (newValue) {
                        recorder.startRecording();
                      } else {
                        recorder.stopRecording();
                      }
                    },
                  ),
                  TextButton(
                    onPressed: recorder.exportRecording,
                    child: const Text("Export CSV"),
                  ),
                  TextButton(
                    onPressed: recorder.clearRecording,
                    child: const Text("Clear"),
                  ),
                ],
              ),
            ),
            Container(
              constraints: const BoxConstraints(maxHeight: 280),
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(8),
              ),
              child: latestMessages.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text("No MIDI messages recorded yet."),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: latestMessages.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final event = latestMessages[index];
                        final bytes = event.message.data
                            .map((byte) =>
                                byte.toRadixString(16).padLeft(2, '0'))
                            .join(' ');
                        return ListTile(
                          dense: true,
                          title: Text(event.message.runtimeType.toString()),
                          subtitle: Text(
                            't=${event.timestamp}  ${event.device.name}\n$bytes',
                          ),
                          isThreeLine: true,
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}
