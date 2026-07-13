import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';
import 'package:win32/win32.dart';

import 'flutter_midi_command_windows.dart';

const _numberOfBuffers = 4;

class WindowsMidiDevice extends MidiDevice {
  final Set<int> _ins = <int>{};
  final Set<int> _outs = <int>{};

  final StreamController<MidiPacket> _rxStreamCtrl;
  final StreamController<MidiSetupChange> _setupStreamController;

  final hMidiInDevicePtr = malloc<Pointer>();
  final hMidiOutDevicePtr = malloc<Pointer>();
  int _midiInHandle = 0;
  int _midiOutHandle = 0;
  bool _disconnecting = false;

  // win32 6 handle types (HMIDIIN/HMIDIOUT) are Pointer-based extension types.
  // We keep the handles as int addresses for callback matching and rebuild the
  // typed handle on demand when calling the winmm functions.
  HMIDIIN get _hMidiIn => HMIDIIN(Pointer.fromAddress(_midiInHandle));
  HMIDIOUT get _hMidiOut => HMIDIOUT(Pointer.fromAddress(_midiOutHandle));

  int callbackAddress;

  final _bufferSize = 8192;

  final List<Pointer<MIDIHDR>> _midiInHeaders = List.generate(
    _numberOfBuffers,
    (index) => nullptr,
  );
  final List<Pointer<BYTE>> _midiInBuffers = List.generate(
    _numberOfBuffers,
    (index) => nullptr,
  );

  Pointer<MIDIHDR> _midiOutHeader = nullptr;
  Pointer<BYTE> _midiOutBuffer = nullptr;

  WindowsMidiDevice(
    String id,
    String name,
    this._rxStreamCtrl,
    this._setupStreamController,
    this.callbackAddress,
  ) : super(id, name, MidiDeviceType.serial, false);

  /// Connect to the device, ie. open input and output ports
  /// NOTE: Currently only the first input/output port is considered
  bool connect() {
    _disconnecting = false;

    // Open input

    var mIn = _ins.firstOrNull;
    if (mIn != null) {
      var id = mIn;
      int result = midiInOpen(
        hMidiInDevicePtr,
        id,
        callbackAddress,
        0,
        CALLBACK_FUNCTION,
      );
      if (result != 0) {
        debugPrint("OPEN ERROR($result): ${midiErrorMessage(result)}");
        return false;
      } else {
        _midiInHandle = hMidiInDevicePtr.value.address;

        // Setup buffer
        for (int i = 0; i < _numberOfBuffers; i++) {
          _midiInBuffers[i] = malloc<BYTE>(_bufferSize);
          _midiInHeaders[i] = malloc<MIDIHDR>();
          _midiInHeaders[i].ref.lpData = PSTR(_midiInBuffers[i].cast());
          _midiInHeaders[i].ref.dwBufferLength = _bufferSize;
          _midiInHeaders[i].ref.dwFlags = 0;
          _midiInHeaders[i].ref.dwBytesRecorded = 0;

          result = midiInPrepareHeader(
            HMIDIIN(hMidiInDevicePtr.value),
            _midiInHeaders[i],
            sizeOf<MIDIHDR>(),
          );
          if (result != 0) {
            debugPrint("HDR PREP ERROR: ${midiErrorMessage(result)}");
            return false;
          }

          result = midiInAddBuffer(
            HMIDIIN(hMidiInDevicePtr.value),
            _midiInHeaders[i],
            sizeOf<MIDIHDR>(),
          );
          if (result != 0) {
            debugPrint("HDR ADD ERROR: ${midiErrorMessage(result)}");
            return false;
          }
        }

        result = midiInStart(HMIDIIN(hMidiInDevicePtr.value));
        if (result != 0) {
          debugPrint("START ERROR: ${midiErrorMessage(result)}");
          return false;
        }
      }
    }

    // Open output
    var mOut = _outs.firstOrNull;
    if (mOut != null) {
      var id = mOut;

      int result = midiOutOpen(hMidiOutDevicePtr, id, 0, 0, CALLBACK_NULL);
      if (result != 0) {
        debugPrint("OUT OPEN ERROR: result");
        return false;
      }
      _midiOutHandle = hMidiOutDevicePtr.value.address;

      _midiOutBuffer = malloc<BYTE>(_bufferSize);
      _midiOutHeader = malloc<MIDIHDR>();
    }
    connected = true;
    _setupStreamController.add(MidiSetupChange.deviceConnected);
    return true;
  }

  bool disconnect() {
    if (_disconnecting) {
      return true;
    }

    _disconnecting = true;
    int result;
    if (_midiInHandle != 0) {
      result = midiInStop(_hMidiIn);
      if (result != 0) {
        debugPrint("STOP ERROR($result): ${midiErrorMessage(result)}");
      }

      result = midiInReset(_hMidiIn);
      if (result != 0) {
        debugPrint("RESET ERROR($result): ${midiErrorMessage(result)}");
      }

      for (int i = 0; i < _numberOfBuffers; i++) {
        if (_midiInHeaders[i] != nullptr) {
          midiInUnprepareHeader(_hMidiIn, _midiInHeaders[i], sizeOf<MIDIHDR>());
          free(_midiInHeaders[i]);
          _midiInHeaders[i] = nullptr;
        }
        if (_midiInBuffers[i] != nullptr) {
          free(_midiInBuffers[i]);
          _midiInBuffers[i] = nullptr;
        }
      }

      result = midiInClose(_hMidiIn);
      if (result != 0) {
        debugPrint("CLOSE ERROR($result): ${midiErrorMessage(result)}");
      }
      _midiInHandle = 0;
      hMidiInDevicePtr.value = nullptr;
    }

    if (_midiOutHandle != 0) {
      result = midiOutReset(_hMidiOut);
      if (result != 0) {
        debugPrint("OUT RESET ERROR($result): ${midiErrorMessage(result)}");
      }

      result = midiOutClose(_hMidiOut);
      if (result != 0) {
        debugPrint("OUT CLOSE ERROR($result): ${midiErrorMessage(result)}");
      }
      _midiOutHandle = 0;
      hMidiOutDevicePtr.value = nullptr;
    }

    if (_midiOutBuffer != nullptr) {
      free(_midiOutBuffer);
      _midiOutBuffer = nullptr;
    }
    if (_midiOutHeader != nullptr) {
      free(_midiOutHeader);
      _midiOutHeader = nullptr;
    }

    connected = false;
    return true;
  }

  bool get isDisconnecting => _disconnecting;

  void addInput(int id) {
    _ins.add(id);
    inputPorts.add(MidiPort(id, MidiPortType.IN));
  }

  void addOutput(int id) {
    _outs.add(id);
    outputPorts.add(MidiPort(id, MidiPortType.OUT));
  }

  containsMidiIn(int input) => _midiInHandle != 0 && _midiInHandle == input;

  _resetHeader(Pointer<MIDIHDR> midiHdrPointer) {
    if (_disconnecting || _midiInHandle == 0) {
      return;
    }
    midiInAddBuffer(_hMidiIn, midiHdrPointer, sizeOf<MIDIHDR>());
  }

  handleData(Uint8List data, int timestamp) {
    // print('handle data $data');
    _rxStreamCtrl.add(MidiPacket(data, timestamp, this));
  }

  handleSysexData(Uint8List data, Pointer<MIDIHDR> midiHdrPointer) {
    // print('handle SysEX: $data');
    _rxStreamCtrl.add(MidiPacket(data, 0, this));
    _resetHeader(midiHdrPointer);
  }

  send(Uint8List data) async {
    if (_outs.isEmpty ||
        _disconnecting ||
        _midiOutHandle == 0 ||
        _midiOutBuffer == nullptr ||
        _midiOutHeader == nullptr) {
      return;
    }

    // Set data in out buffer
    _midiOutBuffer.asTypedList(data.length).setAll(0, data);
    _midiOutHeader.ref.lpData = PSTR(_midiOutBuffer.cast());
    _midiOutHeader.ref.dwBytesRecorded =
        _midiOutHeader.ref.dwBufferLength = data.length;
    _midiOutHeader.ref.dwFlags = 0;

    int result = midiOutPrepareHeader(
      _hMidiOut,
      _midiOutHeader,
      sizeOf<MIDIHDR>(),
    );
    if (result != 0) {
      debugPrint("HDR OUT PREP ERROR: ${midiErrorMessage(result)}");
    }

    result = midiOutLongMsg(_hMidiOut, _midiOutHeader, sizeOf<MIDIHDR>());
    if (result != 0) {
      debugPrint("SEND ERROR($result): ${midiErrorMessage(result)}");
    }

    result = midiOutUnprepareHeader(
      _hMidiOut,
      _midiOutHeader,
      sizeOf<MIDIHDR>(),
    );
    if (result != 0) {
      debugPrint("OUT UNPREPARE ERROR($result): ${midiErrorMessage(result)}");
    }
  }
}
