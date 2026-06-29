#import "FlutterMidiCommandPlugin.h"
#if __has_include(<flutter_midi_command_darwin/flutter_midi_command_darwin-Swift.h>)
#import <flutter_midi_command_darwin/flutter_midi_command_darwin-Swift.h>
#else
#import "flutter_midi_command_darwin-Swift.h"
#endif

@implementation FlutterMidiCommandPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  [SwiftFlutterMidiCommandPlugin registerWithRegistrar:registrar];
}
@end
