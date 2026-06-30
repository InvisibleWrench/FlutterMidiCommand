// ignore_for_file: non_constant_identifier_names, constant_identifier_names, camel_case_types, library_private_types_in_public_api

import 'dart:ffi' as ffi;

const int SND_SEQ_OPEN_DUPLEX = 3;
const int SND_SEQ_ADDRESS_UNKNOWN = 253;
const int SND_SEQ_ADDRESS_SUBSCRIBERS = 254;
const int SND_SEQ_PORT_CAP_READ = 1;
const int SND_SEQ_PORT_CAP_WRITE = 2;
const int SND_SEQ_PORT_CAP_SUBS_READ = 32;
const int SND_SEQ_PORT_CAP_SUBS_WRITE = 64;
const int SND_SEQ_PORT_TYPE_MIDI_GENERIC = 2;
const int SND_SEQ_PORT_TYPE_HARDWARE = 65536;
const int SND_SEQ_PORT_TYPE_APPLICATION = 1048576;
const int SND_SEQ_QUEUE_DIRECT = 253;

abstract class SndSeqEventType {
  static const int clock = 36;
  static const int start = 30;
  static const int continueEvent = 31;
  static const int stop = 32;
  static const int clientStart = 60;
  static const int clientExit = 61;
  static const int clientChange = 62;
  static const int portStart = 63;
  static const int portExit = 64;
  static const int portChange = 65;
  static const int portSubscribed = 66;
  static const int portUnsubscribed = 67;
}

final class snd_seq_addr extends ffi.Struct {
  @ffi.UnsignedChar()
  external int client;

  @ffi.UnsignedChar()
  external int port;
}

final class snd_seq_connect extends ffi.Struct {
  external snd_seq_addr sender;
  external snd_seq_addr dest;
}

final class snd_seq_real_time extends ffi.Struct {
  @ffi.UnsignedInt()
  external int tvSec;

  @ffi.UnsignedInt()
  external int tvNsec;
}

final class snd_seq_timestamp extends ffi.Union {
  @ffi.UnsignedInt()
  external int tick;

  external snd_seq_real_time time;
}

final class snd_seq_ev_note extends ffi.Struct {
  @ffi.UnsignedChar()
  external int channel;

  @ffi.UnsignedChar()
  external int note;

  @ffi.UnsignedChar()
  external int velocity;

  @ffi.UnsignedChar()
  external int offVelocity;

  @ffi.UnsignedInt()
  external int duration;
}

final class snd_seq_ev_ctrl extends ffi.Struct {
  @ffi.UnsignedChar()
  external int channel;

  @ffi.Array.multi([3])
  external ffi.Array<ffi.UnsignedChar> unused;

  @ffi.UnsignedInt()
  external int param;

  @ffi.Int()
  external int value;
}

final class snd_seq_ev_raw8 extends ffi.Struct {
  @ffi.Array.multi([12])
  external ffi.Array<ffi.UnsignedChar> d;
}

final class snd_seq_ev_raw32 extends ffi.Struct {
  @ffi.Array.multi([3])
  external ffi.Array<ffi.UnsignedInt> d;
}

@ffi.Packed(1)
final class snd_seq_ev_ext extends ffi.Struct {
  @ffi.UnsignedInt()
  external int len;

  external ffi.Pointer<ffi.Void> ptr;
}

final class snd_seq_result extends ffi.Struct {
  @ffi.Int()
  external int event;

  @ffi.Int()
  external int result;
}

final class snd_seq_queue_skew extends ffi.Struct {
  @ffi.UnsignedInt()
  external int value;

  @ffi.UnsignedInt()
  external int base;
}

final class snd_seq_ev_queue_control extends ffi.Struct {
  @ffi.UnsignedChar()
  external int queue;

  @ffi.Array.multi([3])
  external ffi.Array<ffi.UnsignedChar> unused;

  external _QueueParam param;
}

final class _QueueParam extends ffi.Union {
  @ffi.Int()
  external int value;

  external snd_seq_timestamp time;

  @ffi.UnsignedInt()
  external int position;

  external snd_seq_queue_skew skew;

  @ffi.Array.multi([2])
  external ffi.Array<ffi.UnsignedInt> d32;

  @ffi.Array.multi([8])
  external ffi.Array<ffi.UnsignedChar> d8;
}

final class snd_seq_event extends ffi.Struct {
  @ffi.UnsignedChar()
  external int type;

  @ffi.UnsignedChar()
  external int flags;

  @ffi.UnsignedChar()
  external int tag;

  @ffi.UnsignedChar()
  external int queue;

  external snd_seq_timestamp time;
  external snd_seq_addr source;
  external snd_seq_addr dest;
  external _EventData data;
}

final class _EventData extends ffi.Union {
  external snd_seq_ev_note note;
  external snd_seq_ev_ctrl control;
  external snd_seq_ev_raw8 raw8;
  external snd_seq_ev_raw32 raw32;
  external snd_seq_ev_ext ext;
  external snd_seq_ev_queue_control queue;
  external snd_seq_timestamp time;
  external snd_seq_addr addr;
  external snd_seq_connect connect;
  external snd_seq_result result;
}

final class snd_seq extends ffi.Opaque {}

final class snd_seq_client_info extends ffi.Opaque {}

final class snd_seq_port_info extends ffi.Opaque {}

final class snd_midi_event extends ffi.Opaque {}

typedef SndSeq = snd_seq;
typedef SndSeqClientInfo = snd_seq_client_info;
typedef SndSeqPortInfo = snd_seq_port_info;
typedef SndSeqEvent = snd_seq_event;
typedef SndMidiEvent = snd_midi_event;

class AlsaSeqBindings {
  AlsaSeqBindings(ffi.DynamicLibrary library) : _library = library;

  final ffi.DynamicLibrary _library;

  ffi.Pointer<T> _lookup<T extends ffi.NativeType>(String name) =>
      _library.lookup<T>(name);

  late final snd_seq_open =
      _lookup<
            ffi.NativeFunction<
              ffi.Int Function(
                ffi.Pointer<ffi.Pointer<SndSeq>>,
                ffi.Pointer<ffi.Char>,
                ffi.Int,
                ffi.Int,
              )
            >
          >('snd_seq_open')
          .asFunction<
            int Function(
              ffi.Pointer<ffi.Pointer<SndSeq>>,
              ffi.Pointer<ffi.Char>,
              int,
              int,
            )
          >();

  late final snd_seq_close =
      _lookup<ffi.NativeFunction<ffi.Int Function(ffi.Pointer<SndSeq>)>>(
        'snd_seq_close',
      ).asFunction<int Function(ffi.Pointer<SndSeq>)>();

  late final snd_seq_set_client_name =
      _lookup<
        ffi.NativeFunction<
          ffi.Int Function(ffi.Pointer<SndSeq>, ffi.Pointer<ffi.Char>)
        >
      >(
        'snd_seq_set_client_name',
      ).asFunction<int Function(ffi.Pointer<SndSeq>, ffi.Pointer<ffi.Char>)>();

  late final snd_seq_client_id =
      _lookup<ffi.NativeFunction<ffi.Int Function(ffi.Pointer<SndSeq>)>>(
        'snd_seq_client_id',
      ).asFunction<int Function(ffi.Pointer<SndSeq>)>();

  late final snd_seq_set_input_buffer_size =
      _lookup<
        ffi.NativeFunction<ffi.Int Function(ffi.Pointer<SndSeq>, ffi.Size)>
      >(
        'snd_seq_set_input_buffer_size',
      ).asFunction<int Function(ffi.Pointer<SndSeq>, int)>();

  late final snd_seq_set_output_buffer_size =
      _lookup<
        ffi.NativeFunction<ffi.Int Function(ffi.Pointer<SndSeq>, ffi.Size)>
      >(
        'snd_seq_set_output_buffer_size',
      ).asFunction<int Function(ffi.Pointer<SndSeq>, int)>();

  late final snd_seq_create_simple_port =
      _lookup<
            ffi.NativeFunction<
              ffi.Int Function(
                ffi.Pointer<SndSeq>,
                ffi.Pointer<ffi.Char>,
                ffi.UnsignedInt,
                ffi.UnsignedInt,
              )
            >
          >('snd_seq_create_simple_port')
          .asFunction<
            int Function(ffi.Pointer<SndSeq>, ffi.Pointer<ffi.Char>, int, int)
          >();

  late final snd_seq_delete_simple_port =
      _lookup<
        ffi.NativeFunction<ffi.Int Function(ffi.Pointer<SndSeq>, ffi.Int)>
      >(
        'snd_seq_delete_simple_port',
      ).asFunction<int Function(ffi.Pointer<SndSeq>, int)>();

  late final snd_seq_connect_from =
      _lookup<
        ffi.NativeFunction<
          ffi.Int Function(ffi.Pointer<SndSeq>, ffi.Int, ffi.Int, ffi.Int)
        >
      >(
        'snd_seq_connect_from',
      ).asFunction<int Function(ffi.Pointer<SndSeq>, int, int, int)>();

  late final snd_seq_disconnect_from =
      _lookup<
        ffi.NativeFunction<
          ffi.Int Function(ffi.Pointer<SndSeq>, ffi.Int, ffi.Int, ffi.Int)
        >
      >(
        'snd_seq_disconnect_from',
      ).asFunction<int Function(ffi.Pointer<SndSeq>, int, int, int)>();

  late final snd_seq_connect_to =
      _lookup<
        ffi.NativeFunction<
          ffi.Int Function(ffi.Pointer<SndSeq>, ffi.Int, ffi.Int, ffi.Int)
        >
      >(
        'snd_seq_connect_to',
      ).asFunction<int Function(ffi.Pointer<SndSeq>, int, int, int)>();

  late final snd_seq_disconnect_to =
      _lookup<
        ffi.NativeFunction<
          ffi.Int Function(ffi.Pointer<SndSeq>, ffi.Int, ffi.Int, ffi.Int)
        >
      >(
        'snd_seq_disconnect_to',
      ).asFunction<int Function(ffi.Pointer<SndSeq>, int, int, int)>();

  late final snd_seq_client_info_malloc =
      _lookup<
        ffi.NativeFunction<
          ffi.Int Function(ffi.Pointer<ffi.Pointer<SndSeqClientInfo>>)
        >
      >(
        'snd_seq_client_info_malloc',
      ).asFunction<int Function(ffi.Pointer<ffi.Pointer<SndSeqClientInfo>>)>();

  late final snd_seq_client_info_free =
      _lookup<
        ffi.NativeFunction<ffi.Void Function(ffi.Pointer<SndSeqClientInfo>)>
      >(
        'snd_seq_client_info_free',
      ).asFunction<void Function(ffi.Pointer<SndSeqClientInfo>)>();

  late final snd_seq_client_info_set_client =
      _lookup<
        ffi.NativeFunction<
          ffi.Void Function(ffi.Pointer<SndSeqClientInfo>, ffi.Int)
        >
      >(
        'snd_seq_client_info_set_client',
      ).asFunction<void Function(ffi.Pointer<SndSeqClientInfo>, int)>();

  late final snd_seq_query_next_client =
      _lookup<
            ffi.NativeFunction<
              ffi.Int Function(
                ffi.Pointer<SndSeq>,
                ffi.Pointer<SndSeqClientInfo>,
              )
            >
          >('snd_seq_query_next_client')
          .asFunction<
            int Function(ffi.Pointer<SndSeq>, ffi.Pointer<SndSeqClientInfo>)
          >();

  late final snd_seq_client_info_get_client =
      _lookup<
        ffi.NativeFunction<ffi.Int Function(ffi.Pointer<SndSeqClientInfo>)>
      >(
        'snd_seq_client_info_get_client',
      ).asFunction<int Function(ffi.Pointer<SndSeqClientInfo>)>();

  late final snd_seq_client_info_get_name =
      _lookup<
            ffi.NativeFunction<
              ffi.Pointer<ffi.Char> Function(ffi.Pointer<SndSeqClientInfo>)
            >
          >('snd_seq_client_info_get_name')
          .asFunction<
            ffi.Pointer<ffi.Char> Function(ffi.Pointer<SndSeqClientInfo>)
          >();

  late final snd_seq_port_info_malloc =
      _lookup<
        ffi.NativeFunction<
          ffi.Int Function(ffi.Pointer<ffi.Pointer<SndSeqPortInfo>>)
        >
      >(
        'snd_seq_port_info_malloc',
      ).asFunction<int Function(ffi.Pointer<ffi.Pointer<SndSeqPortInfo>>)>();

  late final snd_seq_port_info_free =
      _lookup<
        ffi.NativeFunction<ffi.Void Function(ffi.Pointer<SndSeqPortInfo>)>
      >(
        'snd_seq_port_info_free',
      ).asFunction<void Function(ffi.Pointer<SndSeqPortInfo>)>();

  late final snd_seq_port_info_set_client =
      _lookup<
        ffi.NativeFunction<
          ffi.Void Function(ffi.Pointer<SndSeqPortInfo>, ffi.Int)
        >
      >(
        'snd_seq_port_info_set_client',
      ).asFunction<void Function(ffi.Pointer<SndSeqPortInfo>, int)>();

  late final snd_seq_port_info_set_port =
      _lookup<
        ffi.NativeFunction<
          ffi.Void Function(ffi.Pointer<SndSeqPortInfo>, ffi.Int)
        >
      >(
        'snd_seq_port_info_set_port',
      ).asFunction<void Function(ffi.Pointer<SndSeqPortInfo>, int)>();

  late final snd_seq_query_next_port =
      _lookup<
            ffi.NativeFunction<
              ffi.Int Function(ffi.Pointer<SndSeq>, ffi.Pointer<SndSeqPortInfo>)
            >
          >('snd_seq_query_next_port')
          .asFunction<
            int Function(ffi.Pointer<SndSeq>, ffi.Pointer<SndSeqPortInfo>)
          >();

  late final snd_seq_port_info_get_port =
      _lookup<
        ffi.NativeFunction<ffi.Int Function(ffi.Pointer<SndSeqPortInfo>)>
      >(
        'snd_seq_port_info_get_port',
      ).asFunction<int Function(ffi.Pointer<SndSeqPortInfo>)>();

  late final snd_seq_port_info_get_name =
      _lookup<
            ffi.NativeFunction<
              ffi.Pointer<ffi.Char> Function(ffi.Pointer<SndSeqPortInfo>)
            >
          >('snd_seq_port_info_get_name')
          .asFunction<
            ffi.Pointer<ffi.Char> Function(ffi.Pointer<SndSeqPortInfo>)
          >();

  late final snd_seq_port_info_get_capability =
      _lookup<
        ffi.NativeFunction<ffi.Int Function(ffi.Pointer<SndSeqPortInfo>)>
      >(
        'snd_seq_port_info_get_capability',
      ).asFunction<int Function(ffi.Pointer<SndSeqPortInfo>)>();

  late final snd_seq_port_info_get_type =
      _lookup<
        ffi.NativeFunction<ffi.Int Function(ffi.Pointer<SndSeqPortInfo>)>
      >(
        'snd_seq_port_info_get_type',
      ).asFunction<int Function(ffi.Pointer<SndSeqPortInfo>)>();

  late final snd_midi_event_new =
      _lookup<
        ffi.NativeFunction<
          ffi.Int Function(ffi.Size, ffi.Pointer<ffi.Pointer<SndMidiEvent>>)
        >
      >(
        'snd_midi_event_new',
      ).asFunction<int Function(int, ffi.Pointer<ffi.Pointer<SndMidiEvent>>)>();

  late final snd_midi_event_free =
      _lookup<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<SndMidiEvent>)>>(
        'snd_midi_event_free',
      ).asFunction<void Function(ffi.Pointer<SndMidiEvent>)>();

  late final snd_midi_event_reset_encode =
      _lookup<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<SndMidiEvent>)>>(
        'snd_midi_event_reset_encode',
      ).asFunction<void Function(ffi.Pointer<SndMidiEvent>)>();

  late final snd_midi_event_reset_decode =
      _lookup<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<SndMidiEvent>)>>(
        'snd_midi_event_reset_decode',
      ).asFunction<void Function(ffi.Pointer<SndMidiEvent>)>();

  late final snd_midi_event_encode =
      _lookup<
            ffi.NativeFunction<
              ffi.Int Function(
                ffi.Pointer<SndMidiEvent>,
                ffi.Pointer<ffi.UnsignedChar>,
                ffi.Int,
                ffi.Pointer<SndSeqEvent>,
              )
            >
          >('snd_midi_event_encode')
          .asFunction<
            int Function(
              ffi.Pointer<SndMidiEvent>,
              ffi.Pointer<ffi.UnsignedChar>,
              int,
              ffi.Pointer<SndSeqEvent>,
            )
          >();

  late final snd_midi_event_decode =
      _lookup<
            ffi.NativeFunction<
              ffi.Int Function(
                ffi.Pointer<SndMidiEvent>,
                ffi.Pointer<ffi.UnsignedChar>,
                ffi.Int,
                ffi.Pointer<SndSeqEvent>,
              )
            >
          >('snd_midi_event_decode')
          .asFunction<
            int Function(
              ffi.Pointer<SndMidiEvent>,
              ffi.Pointer<ffi.UnsignedChar>,
              int,
              ffi.Pointer<SndSeqEvent>,
            )
          >();

  late final snd_seq_event_output_direct =
      _lookup<
            ffi.NativeFunction<
              ffi.Int Function(ffi.Pointer<SndSeq>, ffi.Pointer<SndSeqEvent>)
            >
          >('snd_seq_event_output_direct')
          .asFunction<
            int Function(ffi.Pointer<SndSeq>, ffi.Pointer<SndSeqEvent>)
          >();

  late final snd_seq_event_input =
      _lookup<
            ffi.NativeFunction<
              ffi.Int Function(
                ffi.Pointer<SndSeq>,
                ffi.Pointer<ffi.Pointer<SndSeqEvent>>,
              )
            >
          >('snd_seq_event_input')
          .asFunction<
            int Function(
              ffi.Pointer<SndSeq>,
              ffi.Pointer<ffi.Pointer<SndSeqEvent>>,
            )
          >();

  late final snd_seq_free_event =
      _lookup<ffi.NativeFunction<ffi.Int Function(ffi.Pointer<SndSeqEvent>)>>(
        'snd_seq_free_event',
      ).asFunction<int Function(ffi.Pointer<SndSeqEvent>)>();
}
