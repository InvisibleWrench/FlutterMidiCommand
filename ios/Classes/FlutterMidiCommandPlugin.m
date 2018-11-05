#import "FlutterMidiCommandPlugin.h"
#import <flutter_midi_command/flutter_midi_command-Swift.h>

@implementation FlutterMidiCommandPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  [SwiftFlutterMidiCommandPlugin registerWithRegistrar:registrar];
}
@end
