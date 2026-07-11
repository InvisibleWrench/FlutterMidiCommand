enum MidiConnectionStage {
  bluetoothConnect,
  serviceDiscovery,
  pairing,
  notificationSubscription,
  platformConnect,
  platformHandoff,
  connectionState,
}

class MidiConnectionException implements Exception {
  MidiConnectionException({
    required this.deviceId,
    required this.stage,
    required this.message,
    this.cause,
  });

  final String deviceId;
  final MidiConnectionStage stage;
  final String message;
  final Object? cause;

  @override
  String toString() {
    final causeText = cause == null ? '' : ' Cause: $cause';
    return 'MidiConnectionException($stage, $deviceId): $message$causeText';
  }
}

class MidiConnectionTimeoutException extends MidiConnectionException {
  MidiConnectionTimeoutException({
    required super.deviceId,
    required super.stage,
    required Duration? timeout,
    super.cause,
  }) : timeout = timeout,
       super(
         message:
             timeout == null
                 ? 'Timed out while connecting.'
                 : 'Timed out after ${timeout.inMilliseconds} ms while connecting.',
       );

  final Duration? timeout;
}

class MidiPairingRejectedException extends MidiConnectionException {
  MidiPairingRejectedException({required super.deviceId, super.cause})
    : super(
        stage: MidiConnectionStage.pairing,
        message: 'Pairing was rejected or did not complete.',
      );
}

class MidiPairingFailedException extends MidiConnectionException {
  MidiPairingFailedException({required super.deviceId, super.cause})
    : super(stage: MidiConnectionStage.pairing, message: 'Pairing failed.');
}

class MidiServiceDiscoveryException extends MidiConnectionException {
  MidiServiceDiscoveryException({required super.deviceId, super.cause})
    : super(
        stage: MidiConnectionStage.serviceDiscovery,
        message: 'The BLE MIDI service or characteristic was not found.',
      );
}

class MidiNotificationSubscriptionException extends MidiConnectionException {
  MidiNotificationSubscriptionException({required super.deviceId, super.cause})
    : super(
        stage: MidiConnectionStage.notificationSubscription,
        message: 'Could not subscribe to BLE MIDI notifications.',
      );
}

class MidiCoreMidiHandoffException extends MidiConnectionException {
  MidiCoreMidiHandoffException({required super.deviceId, super.cause})
    : super(
        stage: MidiConnectionStage.platformHandoff,
        message: 'The paired BLE MIDI device was not exposed by CoreMIDI.',
      );
}
