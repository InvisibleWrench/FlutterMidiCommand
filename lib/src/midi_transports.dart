enum MidiTransport {
  /// Host/platform MIDI stack (for example USB, virtual host ports,
  /// and paired devices exposed by the operating system).
  native,
  ble,
  network,
  virtual,
}

class MidiCapabilities {
  const MidiCapabilities({
    required this.supportedTransports,
    required this.enabledTransports,
  });

  final Set<MidiTransport> supportedTransports;
  final Set<MidiTransport> enabledTransports;

  bool supports(MidiTransport transport) =>
      supportedTransports.contains(transport);

  bool isEnabled(MidiTransport transport) =>
      enabledTransports.contains(transport);
}

class MidiTransportPolicy {
  const MidiTransportPolicy({
    this.includedTransports,
    this.excludedTransports = const <MidiTransport>{},
  });

  final Set<MidiTransport>? includedTransports;
  final Set<MidiTransport> excludedTransports;

  Set<MidiTransport> resolveEnabledTransports(Set<MidiTransport> supported) {
    final included = includedTransports ?? supported;
    return included.where((transport) {
      return supported.contains(transport) &&
          !excludedTransports.contains(transport);
    }).toSet();
  }
}
