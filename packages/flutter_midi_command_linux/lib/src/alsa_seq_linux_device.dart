import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_midi_command_linux/flutter_midi_command_linux.dart';

import 'alsa_seq_bindings.dart';

String _nativeString(Pointer<Char> pointer) {
  if (pointer == nullptr) {
    return '';
  }
  return pointer.cast<Utf8>().toDartString();
}

AlsaSeqBindings _openAlsa() {
  return AlsaSeqBindings(DynamicLibrary.open('libasound.so.2'));
}

class AlsaSeqLinuxDevice implements LinuxMidiPortDevice {
  AlsaSeqLinuxDevice._(
    this._context, {
    required this.client,
    required this.port,
    required this.id,
    required this.name,
    required this.hasInput,
    required this.hasOutput,
  });

  final _AlsaSeqContext _context;
  final int client;
  final int port;
  final StreamController<LinuxMidiPacket> _receivedMessages =
      StreamController<LinuxMidiPacket>.broadcast();
  bool _connected = false;

  @override
  final String id;

  @override
  final String name;

  @override
  final bool hasInput;

  @override
  final bool hasOutput;

  @override
  Stream<LinuxMidiPacket> get receivedMessages => _receivedMessages.stream;

  static String stableId(int client, int port) => 'aseq:$client:$port';

  static List<AlsaSeqLinuxDevice> getDevices({
    bool includeSystem = false,
    bool includeMidiThrough = false,
  }) {
    return _AlsaSeqContext.instance.enumerate(
      includeSystem: includeSystem,
      includeMidiThrough: includeMidiThrough,
    );
  }

  static void closeSharedContext() {
    _AlsaSeqContext.closeInstance();
  }

  @override
  Future<bool> connect() async {
    if (_connected) {
      return true;
    }
    if (!_context.ensureOpen()) {
      return false;
    }

    _context.registerDevice(this);

    var ok = true;
    if (hasInput) {
      ok = _context.connectFrom(client, port) && ok;
    }
    if (hasOutput) {
      ok = _context.connectTo(client, port) && ok;
    }

    if (!ok) {
      if (hasInput) {
        _context.disconnectFrom(client, port);
      }
      if (hasOutput) {
        _context.disconnectTo(client, port);
      }
      _context.unregisterDevice(this);
      return false;
    }

    _connected = true;
    return true;
  }

  @override
  void send(Uint8List midiMessage) {
    if (!_connected || !hasOutput) {
      return;
    }
    _context.send(midiMessage, client: client, port: port);
  }

  @override
  Future<void> disconnect() async {
    if (!_connected) {
      return;
    }
    if (hasInput) {
      _context.disconnectFrom(client, port);
    }
    if (hasOutput) {
      _context.disconnectTo(client, port);
    }
    _context.unregisterDevice(this);
    _connected = false;
  }

  void emit(Uint8List data, int timestamp) {
    if (!_receivedMessages.isClosed) {
      _receivedMessages.add(LinuxMidiPacket(data, timestamp));
    }
  }

  void forceDisconnected() {
    _connected = false;
  }
}

class _AlsaSeqContext {
  _AlsaSeqContext._();

  static _AlsaSeqContext? _shared;

  static _AlsaSeqContext get instance => _shared ??= _AlsaSeqContext._();

  static void closeInstance() {
    _shared?.close();
    _shared = null;
  }

  AlsaSeqBindings? _alsa;
  Pointer<SndSeq>? _seq;
  int _clientId = -1;
  int _localInPort = -1;
  int _localOutPort = -1;
  Pointer<SndMidiEvent>? _midiCodec;
  Pointer<SndSeqEvent>? _eventOut;
  Isolate? _rxIsolate;
  ReceivePort? _rxPort;
  ReceivePort? _rxErrorPort;

  final Map<String, Set<AlsaSeqLinuxDevice>> _devicesByEndpoint =
      <String, Set<AlsaSeqLinuxDevice>>{};

  bool get ready =>
      _alsa != null &&
      _seq != null &&
      _seq != nullptr &&
      _localInPort >= 0 &&
      _localOutPort >= 0;

  bool ensureOpen() {
    if (ready) {
      return true;
    }

    final alsa = _alsa ??= _openAlsa();
    final seqPtrPtr = calloc<Pointer<SndSeq>>();
    final name = 'default'.toNativeUtf8();
    try {
      final result = alsa.snd_seq_open(
        seqPtrPtr,
        name.cast<Char>(),
        SND_SEQ_OPEN_DUPLEX,
        0,
      );
      if (result < 0 || seqPtrPtr.value == nullptr) {
        return false;
      }

      _seq = seqPtrPtr.value;
      final clientName = 'flutter_midi_command'.toNativeUtf8();
      try {
        alsa.snd_seq_set_client_name(_seq!, clientName.cast<Char>());
      } finally {
        malloc.free(clientName);
      }

      _clientId = alsa.snd_seq_client_id(_seq!);
      alsa.snd_seq_set_input_buffer_size(_seq!, 4096);
      alsa.snd_seq_set_output_buffer_size(_seq!, 4096);

      final inName = 'flutter_midi_command:in'.toNativeUtf8();
      final outName = 'flutter_midi_command:out'.toNativeUtf8();
      try {
        _localInPort = alsa.snd_seq_create_simple_port(
          _seq!,
          inName.cast<Char>(),
          SND_SEQ_PORT_CAP_WRITE | SND_SEQ_PORT_CAP_SUBS_WRITE,
          SND_SEQ_PORT_TYPE_MIDI_GENERIC | SND_SEQ_PORT_TYPE_APPLICATION,
        );
        _localOutPort = alsa.snd_seq_create_simple_port(
          _seq!,
          outName.cast<Char>(),
          SND_SEQ_PORT_CAP_READ | SND_SEQ_PORT_CAP_SUBS_READ,
          SND_SEQ_PORT_TYPE_MIDI_GENERIC | SND_SEQ_PORT_TYPE_APPLICATION,
        );
      } finally {
        malloc.free(inName);
        malloc.free(outName);
      }

      if (_localInPort < 0 || _localOutPort < 0) {
        close();
        return false;
      }

      alsa.snd_seq_connect_from(_seq!, _localInPort, 0, 1);
      _eventOut = calloc<SndSeqEvent>();

      final codecPtrPtr = calloc<Pointer<SndMidiEvent>>();
      try {
        final codecResult = alsa.snd_midi_event_new(4096, codecPtrPtr);
        if (codecResult >= 0 && codecPtrPtr.value != nullptr) {
          _midiCodec = codecPtrPtr.value;
        }
      } finally {
        calloc.free(codecPtrPtr);
      }

      unawaited(_startRxIsolate());
      return true;
    } finally {
      malloc.free(name);
      calloc.free(seqPtrPtr);
    }
  }

  void close() {
    _rxPort?.close();
    _rxErrorPort?.close();
    _rxIsolate?.kill(priority: Isolate.immediate);
    _rxPort = null;
    _rxErrorPort = null;
    _rxIsolate = null;

    final alsa = _alsa;
    final seq = _seq;
    if (alsa != null && _midiCodec != null && _midiCodec != nullptr) {
      alsa.snd_midi_event_free(_midiCodec!);
    }
    _midiCodec = null;

    if (alsa != null && seq != null && seq != nullptr) {
      if (_localInPort >= 0) {
        alsa.snd_seq_delete_simple_port(seq, _localInPort);
      }
      if (_localOutPort >= 0) {
        alsa.snd_seq_delete_simple_port(seq, _localOutPort);
      }
      alsa.snd_seq_close(seq);
    }

    if (_eventOut != null && _eventOut != nullptr) {
      calloc.free(_eventOut!);
    }
    _eventOut = null;
    _seq = null;
    _clientId = -1;
    _localInPort = -1;
    _localOutPort = -1;
    _devicesByEndpoint.clear();
  }

  List<AlsaSeqLinuxDevice> enumerate({
    required bool includeSystem,
    required bool includeMidiThrough,
  }) {
    if (!ensureOpen()) {
      return <AlsaSeqLinuxDevice>[];
    }

    final alsa = _alsa!;
    final seq = _seq!;
    final ports = <_SeqPortInfo>[];
    final cInfoPtrPtr = calloc<Pointer<SndSeqClientInfo>>();
    final pInfoPtrPtr = calloc<Pointer<SndSeqPortInfo>>();

    try {
      if (alsa.snd_seq_client_info_malloc(cInfoPtrPtr) < 0 ||
          alsa.snd_seq_port_info_malloc(pInfoPtrPtr) < 0) {
        return <AlsaSeqLinuxDevice>[];
      }

      final cInfo = cInfoPtrPtr.value;
      final pInfo = pInfoPtrPtr.value;
      alsa.snd_seq_client_info_set_client(cInfo, -1);

      while (alsa.snd_seq_query_next_client(seq, cInfo) >= 0) {
        final clientId = alsa.snd_seq_client_info_get_client(cInfo);
        if (clientId == _clientId) {
          continue;
        }
        if (!includeSystem && clientId == 0) {
          continue;
        }
        if (!includeMidiThrough && clientId == 14) {
          continue;
        }

        final clientNamePtr = alsa.snd_seq_client_info_get_name(cInfo);
        final clientName =
            _nativeString(clientNamePtr).isEmpty
                ? 'Client $clientId'
                : _nativeString(clientNamePtr);

        alsa.snd_seq_port_info_set_client(pInfo, clientId);
        alsa.snd_seq_port_info_set_port(pInfo, -1);

        while (alsa.snd_seq_query_next_port(seq, pInfo) >= 0) {
          final portType = alsa.snd_seq_port_info_get_type(pInfo);
          if ((portType & SND_SEQ_PORT_TYPE_HARDWARE) == 0) {
            continue;
          }

          final portId = alsa.snd_seq_port_info_get_port(pInfo);
          final capability = alsa.snd_seq_port_info_get_capability(pInfo);
          final hasInput =
              (capability & SND_SEQ_PORT_CAP_READ) != 0 &&
              (capability & SND_SEQ_PORT_CAP_SUBS_READ) != 0;
          final hasOutput =
              (capability & SND_SEQ_PORT_CAP_WRITE) != 0 &&
              (capability & SND_SEQ_PORT_CAP_SUBS_WRITE) != 0;

          if (!hasInput && !hasOutput) {
            continue;
          }

          ports.add(
            _SeqPortInfo(
              clientId: clientId,
              portId: portId,
              clientName: clientName,
              hasInput: hasInput,
              hasOutput: hasOutput,
            ),
          );
        }
      }
    } finally {
      if (pInfoPtrPtr.value != nullptr) {
        alsa.snd_seq_port_info_free(pInfoPtrPtr.value);
      }
      if (cInfoPtrPtr.value != nullptr) {
        alsa.snd_seq_client_info_free(cInfoPtrPtr.value);
      }
      calloc.free(pInfoPtrPtr);
      calloc.free(cInfoPtrPtr);
    }

    final byClient = <int, List<_SeqPortInfo>>{};
    for (final port in ports) {
      (byClient[port.clientId] ??= <_SeqPortInfo>[]).add(port);
    }

    final devices = <AlsaSeqLinuxDevice>[];
    for (final clientPorts in byClient.values) {
      clientPorts.sort((a, b) => a.portId.compareTo(b.portId));
      final count = clientPorts.length;
      for (var i = 0; i < clientPorts.length; i++) {
        final port = clientPorts[i];
        devices.add(
          AlsaSeqLinuxDevice._(
            this,
            client: port.clientId,
            port: port.portId,
            id: AlsaSeqLinuxDevice.stableId(port.clientId, port.portId),
            name:
                count == 1 ? port.clientName : '${port.clientName} [${i + 1}]',
            hasInput: port.hasInput,
            hasOutput: port.hasOutput,
          ),
        );
      }
    }

    return devices;
  }

  void registerDevice(AlsaSeqLinuxDevice device) {
    (_devicesByEndpoint[_endpointKey(device.client, device.port)] ??=
            <AlsaSeqLinuxDevice>{})
        .add(device);
  }

  void unregisterDevice(AlsaSeqLinuxDevice device) {
    final devices =
        _devicesByEndpoint[_endpointKey(device.client, device.port)];
    devices?.remove(device);
    if (devices != null && devices.isEmpty) {
      _devicesByEndpoint.remove(_endpointKey(device.client, device.port));
    }
  }

  bool connectFrom(int client, int port) {
    if (!ensureOpen()) {
      return false;
    }
    return _alsa!.snd_seq_connect_from(_seq!, _localInPort, client, port) >= 0;
  }

  bool disconnectFrom(int client, int port) {
    if (!ready) {
      return true;
    }
    return _alsa!.snd_seq_disconnect_from(_seq!, _localInPort, client, port) >=
        0;
  }

  bool connectTo(int client, int port) {
    if (!ensureOpen()) {
      return false;
    }
    return _alsa!.snd_seq_connect_to(_seq!, _localOutPort, client, port) >= 0;
  }

  bool disconnectTo(int client, int port) {
    if (!ready) {
      return true;
    }
    return _alsa!.snd_seq_disconnect_to(_seq!, _localOutPort, client, port) >=
        0;
  }

  void send(Uint8List midi, {required int client, required int port}) {
    if (!ready || _midiCodec == null || _midiCodec == nullptr) {
      return;
    }

    final ev = _eventOut!;
    ev.ref.source.client = _clientId;
    ev.ref.source.port = _localOutPort;
    ev.ref.queue = SND_SEQ_QUEUE_DIRECT;
    ev.ref.dest.client = client;
    ev.ref.dest.port = port;

    if (midi.length == 1) {
      switch (midi[0]) {
        case 0xF8:
          ev.ref.type = SndSeqEventType.clock;
          _alsa!.snd_seq_event_output_direct(_seq!, ev);
          return;
        case 0xFA:
          ev.ref.type = SndSeqEventType.start;
          _alsa!.snd_seq_event_output_direct(_seq!, ev);
          return;
        case 0xFB:
          ev.ref.type = SndSeqEventType.continueEvent;
          _alsa!.snd_seq_event_output_direct(_seq!, ev);
          return;
        case 0xFC:
          ev.ref.type = SndSeqEventType.stop;
          _alsa!.snd_seq_event_output_direct(_seq!, ev);
          return;
      }
    }

    _alsa!.snd_midi_event_reset_encode(_midiCodec!);
    final buffer = calloc<Uint8>(midi.length);
    try {
      for (var i = 0; i < midi.length; i++) {
        buffer[i] = midi[i];
      }

      var offset = 0;
      while (offset < midi.length) {
        final consumed = _alsa!.snd_midi_event_encode(
          _midiCodec!,
          (buffer + offset).cast<UnsignedChar>(),
          midi.length - offset,
          ev,
        );
        if (consumed <= 0) {
          break;
        }
        offset += consumed;

        ev.ref.source.client = _clientId;
        ev.ref.source.port = _localOutPort;
        ev.ref.queue = SND_SEQ_QUEUE_DIRECT;
        ev.ref.dest.client = client;
        ev.ref.dest.port = port;
        _alsa!.snd_seq_event_output_direct(_seq!, ev);
      }
    } finally {
      calloc.free(buffer);
    }
  }

  Future<void> _startRxIsolate() async {
    if (!ready || _rxIsolate != null) {
      return;
    }

    _rxPort = ReceivePort();
    _rxErrorPort = ReceivePort();

    _rxPort!.listen((message) {
      if (message is! List<Object?> || message.isEmpty) {
        return;
      }
      final tag = message[0];
      if (tag == 'midi' && message.length == 4) {
        final client = message[1] as int;
        final port = message[2] as int;
        final data = message[3] as Uint8List;
        final devices = _devicesByEndpoint[_endpointKey(client, port)];
        if (devices == null) {
          return;
        }
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        for (final device in devices) {
          device.emit(data, timestamp);
        }
      } else if (tag == 'hotplug' && message.length == 4) {
        _handleHotplug(message[1] as int, message[2] as int, message[3] as int);
      }
    });

    _rxErrorPort!.listen((_) {
      close();
    });

    _rxIsolate = await Isolate.spawn(
      _seqRxIsolateEntry,
      _SeqRxArgs(_rxPort!.sendPort, _seq!.address),
      onError: _rxErrorPort!.sendPort,
    );
  }

  void _handleHotplug(int type, int client, int port) {
    if (type == SndSeqEventType.portExit) {
      final devices = _devicesByEndpoint.remove(_endpointKey(client, port));
      for (final device in devices ?? const <AlsaSeqLinuxDevice>{}) {
        device.forceDisconnected();
      }
      return;
    }

    if (type == SndSeqEventType.clientExit) {
      final keys = _devicesByEndpoint.keys
          .where((key) => key.startsWith('$client:'))
          .toList(growable: false);
      for (final key in keys) {
        final devices = _devicesByEndpoint.remove(key);
        for (final device in devices ?? const <AlsaSeqLinuxDevice>{}) {
          device.forceDisconnected();
        }
      }
    }
  }
}

void _seqRxIsolateEntry(_SeqRxArgs args) {
  final alsa = _openAlsa();
  final seq = Pointer<SndSeq>.fromAddress(args.seqAddress);
  final codecPtrPtr = calloc<Pointer<SndMidiEvent>>();
  final eventPtrPtr = calloc<Pointer<SndSeqEvent>>();
  final outBuffer = calloc<Uint8>(4096);

  Pointer<SndMidiEvent> codec = nullptr;
  try {
    final codecResult = alsa.snd_midi_event_new(4096, codecPtrPtr);
    if (codecResult >= 0 && codecPtrPtr.value != nullptr) {
      codec = codecPtrPtr.value;
    }

    while (true) {
      final result = alsa.snd_seq_event_input(seq, eventPtrPtr);
      if (result < 0) {
        break;
      }

      final event = eventPtrPtr.value;
      if (event == nullptr) {
        continue;
      }

      final type = event.ref.type;
      if (_isHotplugEvent(type)) {
        final addr = event.ref.data.addr;
        args.sendPort.send(<Object?>['hotplug', type, addr.client, addr.port]);
      } else if (codec != nullptr) {
        alsa.snd_midi_event_reset_decode(codec);
        final byteCount = alsa.snd_midi_event_decode(
          codec,
          outBuffer.cast<UnsignedChar>(),
          4096,
          event,
        );
        if (byteCount > 0) {
          final bytes = Uint8List(byteCount);
          for (var i = 0; i < byteCount; i++) {
            bytes[i] = outBuffer[i];
          }
          args.sendPort.send(<Object?>[
            'midi',
            event.ref.source.client,
            event.ref.source.port,
            bytes,
          ]);
        }
      }

      alsa.snd_seq_free_event(event);
      eventPtrPtr.value = nullptr;
    }
  } finally {
    if (codec != nullptr) {
      alsa.snd_midi_event_free(codec);
    }
    calloc.free(outBuffer);
    calloc.free(eventPtrPtr);
    calloc.free(codecPtrPtr);
  }
}

bool _isHotplugEvent(int type) {
  return type == SndSeqEventType.portExit ||
      type == SndSeqEventType.clientExit ||
      type == SndSeqEventType.portStart ||
      type == SndSeqEventType.clientStart ||
      type == SndSeqEventType.portChange ||
      type == SndSeqEventType.clientChange ||
      type == SndSeqEventType.portSubscribed ||
      type == SndSeqEventType.portUnsubscribed;
}

String _endpointKey(int client, int port) => '$client:$port';

class _SeqRxArgs {
  const _SeqRxArgs(this.sendPort, this.seqAddress);

  final SendPort sendPort;
  final int seqAddress;
}

class _SeqPortInfo {
  const _SeqPortInfo({
    required this.clientId,
    required this.portId,
    required this.clientName,
    required this.hasInput,
    required this.hasOutput,
  });

  final int clientId;
  final int portId;
  final String clientName;
  final bool hasInput;
  final bool hasOutput;
}
