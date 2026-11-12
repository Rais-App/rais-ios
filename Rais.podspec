Pod::Spec.new do |s|
  s.name             = 'Rais'
  s.version          = '1.0.0'
  s.summary          = 'The Raïs checkout inside your iOS app, drawn with native controls.'
  s.description      = 'RaisCheckout shows a Raïs payment in a native screen: card fields, saved cards, the bank code and the result, with light and dark mode and an appearance you can customize.'
  s.homepage         = 'https://rais.app/sdk'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Raïs' => 'support@rais.app' }
  s.source           = { :git => 'https://github.com/rais-app/rais-ios.git', :tag => s.version.to_s }
  s.ios.deployment_target = '15.0'
  s.swift_versions   = ['5.9']
  s.source_files     = 'Sources/Rais/**/*.swift'
  s.resource_bundles = { 'RaisResources' => ['Sources/Rais/Resources/**/*'] }
  s.frameworks       = 'UIKit', 'WebKit', 'SwiftUI', 'QuickLook'
end
