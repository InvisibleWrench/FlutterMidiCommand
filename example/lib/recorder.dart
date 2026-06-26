
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:csv/csv.dart';
import 'package:file_picker/file_picker.dart';

class MidiRecorder {

  factory MidiRecorder() {
    _instance ??= MidiRecorder._();
    return _instance!;
  }

  static MidiRecorder? _instance;

  MidiRecorder._();

  bool _recording = false;

  bool get recording => _recording;

  final List<MidiPacket> _messages = [];

  StreamSubscription<MidiPacket>? _midiSub;

  void startRecording() {
    print("Starting recording");
    _recording = true;
    _midiSub = MidiCommand().onMidiDataReceived?.listen((packet) {
      print("Recording packet: ${packet.data.length} bytes");
      _messages.add(packet);
    });
  }

  void stopRecording() {
    print("Stopping recording");
    _recording = false;
    _midiSub?.cancel();
  }


  void exportRecording() async {
    print("Writing ${_messages.length} messages to CSV file");
    List<List<String>> rows = _messages.map<List<String>>((e) => [e.timestamp.toString(), ...e.data.map<String>((e) => e.toString())]).toList();

    var data = csv.encode(rows);
    Uint8List bytes = Uint8List.fromList(data.codeUnits);

    String? outputFile = await FilePicker.saveFile(
      dialogTitle: 'Please select an output file:',
      fileName: 'midi_recording.csv',
      type: FileType.custom,
      allowedExtensions: ['csv'],
      bytes: bytes,
    );

    if (outputFile == null) {
      print("The user canceled the picker");
    } else {
      print("Recorded ${bytes.length} bytes exported to $outputFile");
    }
  }

  void clearRecording() {
    _messages.clear();
  }
}

