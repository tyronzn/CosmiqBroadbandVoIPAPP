#
# Local pod wrapping the native SIP engine for iOS.
#
# Everything this pod needs is staged into it by tools/build_native_ios.sh:
# the prebuilt libre/baresip archives, the C wrapper source, and the re and
# baresip headers that wrapper includes. Nothing here reaches outside the pod
# directory, because CocoaPods rejects file patterns that climb above the
# podspec.
#
# Why a pod at all: the alternative is editing Runner.xcodeproj/project.pbxproj
# to add the archives, the header search paths and the frameworks. That file is
# generated, merge-hostile, and cannot be edited safely from a Windows box
# where the rest of this app is developed. A podspec is plain text.
#
Pod::Spec.new do |s|
  s.name         = 'CosmiqSip'
  s.version      = '1.0.0'
  s.summary      = 'Native SIP engine (baresip + libre) for Cosmiq Broadband VoIP.'
  s.description  = <<-DESC
    The same C engine the Android app runs, behind the same cosmiq_sip.h API.
    Built without OpenSSL or mbedTLS: on Apple targets libre uses CommonCrypto
    for AES and HMAC, and TLS compiles out entirely.
  DESC
  s.homepage     = 'https://cosmiqbroadband.co.za'
  s.license      = { :type => 'Proprietary',
                     :text => 'Copyright Cosmiq Broadband. All rights reserved.' }
  s.author       = { 'Cosmiq Broadband' => 'info@cosmiqbroadband.co.za' }
  s.source       = { :path => '.' }
  s.platform     = :ios, '13.0'

  # Fail with something actionable. Without this the error is a wall of
  # CocoaPods output about missing file patterns, which says nothing about the
  # actual cause.
  unless File.exist?(File.join(__dir__, 'lib', 'libbaresip.a'))
    raise <<~MSG

      CosmiqSip: the native engine has not been built.

        tools/fetch_native.sh
        tools/build_native_ios.sh

      Both must run on macOS before `pod install`. codemagic.yaml does this
      automatically; a local Mac build needs it done by hand.
    MSG
  end

  # Classes/ is committed; src/, include/, lib/ and vendor-include/ are staged
  # by the build script and gitignored.
  #
  # The Swift bridge lives in this pod rather than in ios/Runner/ for a
  # practical reason: adding a file to the Runner target means editing
  # Runner.xcodeproj/project.pbxproj, and CocoaPods compiles its own sources
  # without anyone touching that file. Swift and C coexist here because
  # use_frameworks! makes this a real framework target, where Swift sees the
  # public C headers through the generated umbrella header.
  s.source_files        = 'Classes/*.swift', 'src/*.c', 'include/*.h'
  s.public_header_files = 'include/*.h'
  s.vendored_libraries  = 'lib/libre.a', 'lib/libbaresip.a'
  s.preserve_paths      = 'vendor-include/**/*', 'lib/*.a'

  s.dependency 'Flutter'
  s.swift_version = '5.0'

  # CoreAudio and AudioToolbox are what baresip's audiounit module links
  # against; it drives kAudioUnitSubType_VoiceProcessingIO, which is also what
  # gives the call echo cancellation and AGC for free. AVFoundation is for the
  # AVAudioSession the Swift bridge configures - the module does not touch it.
  s.frameworks = 'AudioToolbox', 'CoreAudio', 'AVFoundation', 'CFNetwork'
  s.libraries  = 'z', 'resolv'

  # The host app is built with use_frameworks!, so a pod carrying static
  # archives has to say so or they are not linked into the final binary.
  s.static_framework = true

  s.pod_target_xcconfig = {
    'HEADER_SEARCH_PATHS' => '"$(PODS_TARGET_SRCROOT)/vendor-include"',
    # The archives are one architecture at a time (see build_native_ios.sh),
    # so do not let Xcode try to build slices they do not contain.
    'ONLY_ACTIVE_ARCH' => 'YES',
  }
end
