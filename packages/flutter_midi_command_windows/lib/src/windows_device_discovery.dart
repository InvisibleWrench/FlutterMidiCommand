import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';
import 'package:flutter_midi_command_windows/windows_midi_device.dart';

class WindowsMidiEndpointDescriptor {
  const WindowsMidiEndpointDescriptor({required this.id, required this.name});

  final int id;
  final String name;

  String get normalizedDisplayName => normalizeWindowsMidiEndpointName(name);

  String get normalizedGroupKey => normalizedDisplayName.toLowerCase();
}

List<MidiDevice> buildWindowsMidiDevices({
  required List<WindowsMidiEndpointDescriptor> inputs,
  required List<WindowsMidiEndpointDescriptor> outputs,
  required StreamController<MidiPacket> rxStreamController,
  required StreamController<MidiSetupChange> setupStreamController,
  required int callbackAddress,
  Set<String> connectedDeviceIds = const <String>{},
}) {
  final devices = <MidiDevice>[];
  final allocatedNames = <String, int>{};
  final pairedInputIds = <int>{};
  final pairedOutputIds = <int>{};

  void addDevice({
    required String baseName,
    WindowsMidiEndpointDescriptor? input,
    WindowsMidiEndpointDescriptor? output,
  }) {
    final trimmedBaseName = baseName.trim();
    final resolvedName =
        trimmedBaseName.isEmpty ? 'MIDI Device' : trimmedBaseName;
    final allocatedCount = allocatedNames[resolvedName] ?? 0;
    allocatedNames[resolvedName] = allocatedCount + 1;
    final deviceLabel =
        allocatedCount == 0 ? resolvedName : '$resolvedName ($allocatedCount)';
    final device = WindowsMidiDevice(
      deviceLabel,
      deviceLabel,
      rxStreamController,
      setupStreamController,
      callbackAddress,
    )..connected = connectedDeviceIds.contains(deviceLabel);
    if (input != null) {
      device.addInput(input.id);
      pairedInputIds.add(input.id);
    }
    if (output != null) {
      device.addOutput(output.id);
      pairedOutputIds.add(output.id);
    }
    devices.add(device);
  }

  final inputsByName = _groupEndpointsByKey(
    inputs,
    (endpoint) => endpoint.name,
  );
  final outputsByName = _groupEndpointsByKey(
    outputs,
    (endpoint) => endpoint.name,
  );
  final orderedExactNames = _orderedSharedKeys(
    inputs.map((endpoint) => endpoint.name),
    outputs.map((endpoint) => endpoint.name),
  );

  for (final name in orderedExactNames) {
    final inputEndpoints =
        inputsByName[name] ?? const <WindowsMidiEndpointDescriptor>[];
    final outputEndpoints =
        outputsByName[name] ?? const <WindowsMidiEndpointDescriptor>[];
    final pairCount = math.min(inputEndpoints.length, outputEndpoints.length);

    for (var index = 0; index < pairCount; index++) {
      addDevice(
        baseName: name,
        input: inputEndpoints[index],
        output: outputEndpoints[index],
      );
    }
  }

  final remainingInputs =
      inputs
          .where((endpoint) => !pairedInputIds.contains(endpoint.id))
          .toList();
  final remainingOutputs =
      outputs
          .where((endpoint) => !pairedOutputIds.contains(endpoint.id))
          .toList();
  final inputsByGroup = _groupEndpointsByKey(
    remainingInputs,
    (endpoint) => endpoint.normalizedGroupKey,
  );
  final outputsByGroup = _groupEndpointsByKey(
    remainingOutputs,
    (endpoint) => endpoint.normalizedGroupKey,
  );
  final orderedNormalizedGroups = _orderedSharedKeys(
    remainingInputs.map((endpoint) => endpoint.normalizedGroupKey),
    remainingOutputs.map((endpoint) => endpoint.normalizedGroupKey),
  );

  for (final groupKey in orderedNormalizedGroups) {
    final inputEndpoints =
        inputsByGroup[groupKey] ?? const <WindowsMidiEndpointDescriptor>[];
    final outputEndpoints =
        outputsByGroup[groupKey] ?? const <WindowsMidiEndpointDescriptor>[];
    if (inputEndpoints.isEmpty ||
        outputEndpoints.isEmpty ||
        inputEndpoints.length != outputEndpoints.length) {
      continue;
    }

    for (var index = 0; index < inputEndpoints.length; index++) {
      addDevice(
        baseName: inputEndpoints[index].normalizedDisplayName,
        input: inputEndpoints[index],
        output: outputEndpoints[index],
      );
    }
  }

  for (final input in inputs) {
    if (!pairedInputIds.contains(input.id)) {
      addDevice(baseName: input.name, input: input);
    }
  }

  for (final output in outputs) {
    if (!pairedOutputIds.contains(output.id)) {
      addDevice(baseName: output.name, output: output);
    }
  }

  return devices;
}

String normalizeWindowsMidiEndpointName(String name) {
  var normalized = name.trim().replaceAll(RegExp(r'\s+'), ' ');

  final bracketedDirectionPrefix = RegExp(
    r'^(midi\s*in|midi\s*out|midiin|midiout)\d*\s*\((.+)\)$',
    caseSensitive: false,
  );
  final bracketedMatch = bracketedDirectionPrefix.firstMatch(normalized);
  if (bracketedMatch != null) {
    normalized = bracketedMatch.group(2)!;
  }

  normalized = normalized.replaceFirst(
    RegExp(
      r'^(midi\s*in|midi\s*out|midiin|midiout)\d*\s*[:\-]?\s*',
      caseSensitive: false,
    ),
    '',
  );
  normalized = normalized.replaceFirst(
    RegExp(r'^(input|output)\s*[:\-]?\s*', caseSensitive: false),
    '',
  );
  normalized = normalized.replaceFirst(
    RegExp(r'\s+\((input|output)\)$', caseSensitive: false),
    '',
  );
  normalized = normalized.trim();
  return normalized.isEmpty ? name.trim() : normalized;
}

Map<String, List<WindowsMidiEndpointDescriptor>> _groupEndpointsByKey(
  List<WindowsMidiEndpointDescriptor> endpoints,
  String Function(WindowsMidiEndpointDescriptor endpoint) keySelector,
) {
  final grouped = <String, List<WindowsMidiEndpointDescriptor>>{};
  for (final endpoint in endpoints) {
    grouped
        .putIfAbsent(
          keySelector(endpoint),
          () => <WindowsMidiEndpointDescriptor>[],
        )
        .add(endpoint);
  }
  return grouped;
}

List<String> _orderedSharedKeys(
  Iterable<String> first,
  Iterable<String> second,
) {
  final firstKeys = first.toSet();
  final secondKeys = second.toSet();
  final orderedKeys = <String>[];
  final seenKeys = <String>{};

  for (final key in first) {
    if (secondKeys.contains(key) && seenKeys.add(key)) {
      orderedKeys.add(key);
    }
  }
  for (final key in second) {
    if (firstKeys.contains(key) && seenKeys.add(key)) {
      orderedKeys.add(key);
    }
  }

  return orderedKeys;
}
