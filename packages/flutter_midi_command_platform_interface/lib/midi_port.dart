// IN/OUT are part of the public API; renaming would be a breaking change.
// ignore_for_file: constant_identifier_names
enum MidiPortType { IN, OUT }

class MidiPort {
  MidiPortType type;
  int id;
  bool connected = false;

  MidiPort(this.id, this.type);
}
