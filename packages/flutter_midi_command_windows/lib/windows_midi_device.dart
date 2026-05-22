import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';
import 'package:win32/win32.dart';

import 'flutter_midi_command_windows.dart';

const _numberOfBuffers = 4;

class WindowsMidiDevice extends MidiDevice {
  final Map<int, MIDIINCAPS> _ins = {};
  final Map<int, MIDIOUTCAPS> _outs = {};

  final StreamController<MidiPacket> _rxStreamCtrl;
  final StreamController<MidiSetupChange> _setupStreamController;

  final hMidiInDevicePtr = malloc<HMIDIIN>();
  final hMidiOutDevicePtr = malloc<IntPtr>();

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
    // Open input

    var mIn = _ins.entries.firstOrNull;
    if (mIn != null) {
      var id = mIn.key;
      int result = midiInOpen(
        hMidiInDevicePtr,
        id,
        callbackAddress,
        0,
        CALLBACK_FUNCTION,
      );
      if (result != 0) {
        print("OPEN ERROR($result): ${midiErrorMessage(result)}");
        return false;
      } else {
        // Setup buffer
        for (int i = 0; i < _numberOfBuffers; i++) {
          _midiInBuffers[i] = malloc<BYTE>(_bufferSize);
          _midiInHeaders[i] = malloc<MIDIHDR>();
          _midiInHeaders[i].ref.lpData = _midiInBuffers[i] as LPSTR;
          _midiInHeaders[i].ref.dwBufferLength = _bufferSize;
          _midiInHeaders[i].ref.dwFlags = 0;
          _midiInHeaders[i].ref.dwBytesRecorded = 0;

          result = midiInPrepareHeader(
            hMidiInDevicePtr.value,
            _midiInHeaders[i],
            sizeOf<MIDIHDR>(),
          );
          if (result != 0) {
            print("HDR PREP ERROR: ${midiErrorMessage(result)}");
            return false;
          }

          result = midiInAddBuffer(
            hMidiInDevicePtr.value,
            _midiInHeaders[i],
            sizeOf<MIDIHDR>(),
          );
          if (result != 0) {
            print("HDR ADD ERROR: ${midiErrorMessage(result)}");
            return false;
          }
        }

        result = midiInStart(hMidiInDevicePtr.value);
        if (result != 0) {
          print("START ERROR: ${midiErrorMessage(result)}");
          return false;
        }
      }
    }

    // Open output
    var mOut = _outs.entries.firstOrNull;
    if (mOut != null) {
      var id = mOut.key;

      int result = midiOutOpen(hMidiOutDevicePtr, id, 0, 0, CALLBACK_NULL);
      if (result != 0) {
        print("OUT OPEN ERROR: result");
        return false;
      }

      _midiOutBuffer = malloc<BYTE>(_bufferSize);
      _midiOutHeader = malloc<MIDIHDR>();
    }
    connected = true;
    _setupStreamController.add(MidiSetupChange.deviceConnected);
    return true;
  }

  bool disconnect() {
    int result;
    if (_ins.isNotEmpty) {
      result = midiInReset(hMidiInDevicePtr.value);
      if (result != 0) {
        print("RESET ERROR($result): ${midiErrorMessage(result)}");
      }

      for (int i = 0; i < _numberOfBuffers; i++) {
        if (_midiInHeaders[i] != nullptr) {
          midiInUnprepareHeader(
            hMidiInDevicePtr.value,
            _midiInHeaders[i],
            sizeOf<MIDIHDR>(),
          );
          free(_midiInHeaders[i]);
        }
        if (_midiInBuffers[i] != nullptr) {
          free(_midiInBuffers[i]);
        }
      }

      result = midiInStop(hMidiInDevicePtr.value);
      if (result != 0) {
        print("STOP ERROR($result): ${midiErrorMessage(result)}");
      }

      result = midiInClose(hMidiInDevicePtr.value);
      if (result != 0) {
        print("CLOSE ERROR($result): ${midiErrorMessage(result)}");
      }

      free(hMidiInDevicePtr);
    }

    if (_outs.isNotEmpty) {
      result = midiOutClose(hMidiOutDevicePtr.value);
      if (result != 0) {
        print("OUT CLOSE ERROR($result): ${midiErrorMessage(result)}");
      }
      free(hMidiOutDevicePtr);
    }

    free(_midiOutBuffer);
    free(_midiOutHeader);

    connected = false;
    return true;
  }

  addInput(int id, MIDIINCAPS input) {
    _ins[id] = input;
    inputPorts.add(MidiPort(id, MidiPortType.IN));
  }

  addOutput(int id, MIDIOUTCAPS output) {
    _outs[id] = output;
    outputPorts.add(MidiPort(id, MidiPortType.OUT));
  }

  containsMidiIn(int input) => hMidiInDevicePtr.value == input;

  _resetHeader(Pointer<MIDIHDR> midiHdrPointer) {
    midiInAddBuffer(hMidiInDevicePtr.value, midiHdrPointer, sizeOf<MIDIHDR>());
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
        _midiOutBuffer == nullptr ||
        _midiOutHeader == nullptr) {
      return;
    }

    // Set data in out buffer
    _midiOutBuffer.asTypedList(data.length).setAll(0, data);
    _midiOutHeader.ref.lpData = _midiOutBuffer as LPSTR;
    _midiOutHeader.ref.dwBytesRecorded =
        _midiOutHeader.ref.dwBufferLength = data.length;
    _midiOutHeader.ref.dwFlags = 0;

    int result = midiOutPrepareHeader(
      hMidiOutDevicePtr.value,
      _midiOutHeader,
      sizeOf<MIDIHDR>(),
    );
    if (result != 0) {
      print("HDR OUT PREP ERROR: ${midiErrorMessage(result)}");
    }

    result = midiOutLongMsg(
      hMidiOutDevicePtr.value,
      _midiOutHeader,
      sizeOf<MIDIHDR>(),
    );
    if (result != 0) {
      print("SEND ERROR($result): ${midiErrorMessage(result)}");
    }

    result = midiOutUnprepareHeader(
      hMidiOutDevicePtr.value,
      _midiOutHeader,
      sizeOf<MIDIHDR>(),
    );
    if (result != 0) {
      print("OUT UNPREPARE ERROR($result): ${midiErrorMessage(result)}");
    }
  }
}
