#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_midi_command.podspec' to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_midi_command'
  s.version          = '0.4.2'
  s.summary          = 'A Flutter plugin for sending and receiving MIDI messages'
  s.description      = <<-DESC
  'A Flutter plugin for sending and receiving MIDI messages'
                       DESC
  s.homepage         = 'http://invisiblewrench.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Invisible Wrench ApS' => 'hello@invisiblewrench.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '11.0'

  # Flutter.framework does not contain a i386 slice. Only x86_64 simulators are supported.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'VALID_ARCHS[sdk=iphonesimulator*]' => 'x86_64' }
  s.swift_version = '5.0'
end
