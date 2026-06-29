#
# Shared Darwin (iOS + macOS) podspec for flutter_midi_command_darwin.
# Required because the package pubspec sets `sharedDarwinSource: true`, so
# Flutter looks for a single podspec inside the `darwin/` directory.
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_midi_command_darwin'
  s.version          = '1.0.0'
  s.summary          = 'A Flutter plugin for sending and receiving MIDI messages'
  s.description      = <<-DESC
A Flutter plugin for sending and receiving MIDI messages between Flutter and
physical and virtual MIDI devices.
                       DESC
  s.homepage         = 'https://github.com/InvisibleWrench/FlutterMidiCommand'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Invisible Wrench ApS' => 'hello@invisiblewrench.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'

  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '13.1'
  s.osx.deployment_target = '10.15'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
