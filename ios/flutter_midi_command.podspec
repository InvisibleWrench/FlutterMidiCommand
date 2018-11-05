#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html
#
Pod::Spec.new do |s|
  s.name             = 'flutter_midi_command'
  s.version          = '0.0.1'
  s.summary          = 'A Flutter plugin for sending and receving midi'
  s.description      = <<-DESC
A Flutter plugin for sending and receiving midi
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Invisible Wrench' => 'morten@invisiblewrench.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'
  s.dependency 'Flutter'

  s.ios.deployment_target = '10.0'
end

