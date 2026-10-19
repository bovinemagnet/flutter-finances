#!/usr/bin/env ruby
# frozen_string_literal: true

# Adds the iOS share extension target to Runner.xcodeproj.
#
# receive_sharing_intent needs a Share Extension target that shares an App
# Group with Runner. Creating it by hand needs Xcode, so this script makes the
# same changes with the `xcodeproj` gem and can run on any machine with Ruby:
#
#   * Runner: bundle id com.paulsnow.finance.app, Runner/Runner.entitlements
#     (App Group), CUSTOM_GROUP_ID
#   * new ShareExtension target (bundle id com.paulsnow.finance.app.ShareExtension)
#     built from ios/ShareExtension, with its own entitlements, the Flutter
#     xcconfig files as base configurations (for FLUTTER_BUILD_NAME/NUMBER)
#     and the `receive-sharing-intent` Swift package product linked
#   * the extension embedded in Runner ("Embed Foundation Extensions", placed
#     before "Thin Binary" as the plugin README requires) and added as a Runner
#     dependency
#
# The script is idempotent: running it again changes nothing. CI runs it before
# `flutter build ios`; a developer with Xcode may run it once and commit the
# resulting project.pbxproj instead.
#
# Usage (from apps/finance_app):
#   gem install --user-install xcodeproj
#   ruby ios/tool/add_share_extension.rb [path/to/Runner.xcodeproj]

require 'xcodeproj'
require 'yaml'

IOS_DIR = File.expand_path('..', __dir__)
PROJECT_PATH = ARGV[0] || File.join(IOS_DIR, 'Runner.xcodeproj')

APP_BUNDLE_ID = 'com.paulsnow.finance.app'
EXTENSION_NAME = 'ShareExtension'
EXTENSION_BUNDLE_ID = "#{APP_BUNDLE_ID}.#{EXTENSION_NAME}"
APP_GROUP = 'group.com.paulsnow.finance.app'
EMBED_PHASE_NAME = 'Embed Foundation Extensions'
# Flutter symlinks each Swift package plugin here (relative to ios/) during
# `flutter build ios`, naming the link after the plugin's versioned pub cache
# directory, for example `receive_sharing_intent-1.9.0`.
RSI_PACKAGES_DIR = 'Flutter/ephemeral/Packages/.packages'
RSI_PLUGIN = 'receive_sharing_intent'
RSI_PRODUCT = 'receive-sharing-intent'

# The resolved plugin version, from the workspace lock file (or the app's own
# lock file outside a workspace).
lock_path = [File.join(IOS_DIR, '..', '..', '..', 'pubspec.lock'), File.join(IOS_DIR, '..', 'pubspec.lock')]
            .map { |p| File.expand_path(p) }.find { |p| File.exist?(p) } or
  abort 'pubspec.lock not found; run `flutter pub get` first'
rsi_version = YAML.safe_load_file(lock_path).dig('packages', RSI_PLUGIN, 'version') or
  abort "#{RSI_PLUGIN} is not in #{lock_path}"
RSI_PACKAGE_PATH = "#{RSI_PACKAGES_DIR}/#{RSI_PLUGIN}-#{rsi_version}"

unless Xcodeproj::Project::Object.const_defined?(:XCLocalSwiftPackageReference)
  abort "xcodeproj #{Xcodeproj::VERSION} lacks local Swift package support; install 1.24 or later"
end

project = Xcodeproj::Project.open(PROJECT_PATH)
runner = project.targets.find { |t| t.name == 'Runner' } or abort 'Runner target not found'
runner_tests = project.targets.find { |t| t.name == 'RunnerTests' }

def ensure_file(group, path)
  group.files.find { |f| f.path == path } || group.new_reference(path)
end

# Runner: bundle identifier shared with the extension prefix, App Group entitlements.
runner_group = project.main_group.children.find { |g| g.display_name == 'Runner' } or
  abort 'Runner group not found'
ensure_file(runner_group, 'Runner.entitlements')
runner.build_configurations.each do |config|
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = APP_BUNDLE_ID
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
  config.build_settings['CUSTOM_GROUP_ID'] = APP_GROUP
end
runner_tests&.build_configurations&.each do |config|
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = "#{APP_BUNDLE_ID}.RunnerTests"
end

deployment_target =
  runner.build_configurations.map { |c| c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] }.compact.first ||
  project.build_configurations.map { |c| c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] }.compact.first ||
  abort('IPHONEOS_DEPLOYMENT_TARGET not found')

# Extension target and its files.
extension = project.targets.find { |t| t.name == EXTENSION_NAME }
unless extension
  extension = project.new_target(:app_extension, EXTENSION_NAME, :ios, deployment_target, nil, :swift)
  # new_target links Foundation.framework by a path inside one particular SDK
  # version; Swift links it automatically, so drop the reference.
  extension.frameworks_build_phase.files.dup.each do |build_file|
    ref = build_file.file_ref
    next unless ref&.path&.end_with?('Foundation.framework')

    build_file.remove_from_project
    parent = ref.parent
    ref.remove_from_project
    while parent.is_a?(Xcodeproj::Project::Object::PBXGroup) && parent.children.empty? &&
          parent != project.main_group
      next_parent = parent.parent
      parent.remove_from_project
      parent = next_parent
    end
  end
end

group = project.main_group.children.find { |g| g.display_name == EXTENSION_NAME } ||
        project.main_group.new_group(EXTENSION_NAME, EXTENSION_NAME)
swift_file = ensure_file(group, 'ShareViewController.swift')
ensure_file(group, 'Info.plist')
ensure_file(group, "#{EXTENSION_NAME}.entitlements")
unless extension.source_build_phase.files_references.include?(swift_file)
  extension.add_file_references([swift_file])
end

# One configuration per Runner configuration (Debug, Release, Profile).
runner.build_configurations.each do |runner_config|
  next if extension.build_configurations.any? { |c| c.name == runner_config.name }

  extension.add_build_configuration(runner_config.name, runner_config.name == 'Debug' ? :debug : :release)
end
extension.build_configurations.each do |config|
  runner_config = runner.build_configurations.find { |c| c.name == config.name }
  config.base_configuration_reference = runner_config&.base_configuration_reference
  settings = config.build_settings
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = EXTENSION_BUNDLE_ID
  settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
  settings['INFOPLIST_FILE'] = "#{EXTENSION_NAME}/Info.plist"
  settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  settings['CODE_SIGN_ENTITLEMENTS'] = "#{EXTENSION_NAME}/#{EXTENSION_NAME}.entitlements"
  settings['CUSTOM_GROUP_ID'] = APP_GROUP
  settings['IPHONEOS_DEPLOYMENT_TARGET'] = deployment_target
  settings['SWIFT_VERSION'] = '5.0'
  settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  settings['SKIP_INSTALL'] = 'YES'
  settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks']
  team = runner_config&.build_settings&.[]('DEVELOPMENT_TEAM')
  settings['DEVELOPMENT_TEAM'] = team if team
end

# Link the plugin's Swift package product (it provides RSIShareViewController).
root = project.root_object
# A reference left by an earlier plugin version is repointed, not duplicated.
package = root.package_references.find do |r|
  r.respond_to?(:relative_path) && r.relative_path.to_s.start_with?("#{RSI_PACKAGES_DIR}/#{RSI_PLUGIN}")
end
unless package
  package = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
  root.package_references << package
end
package.relative_path = RSI_PACKAGE_PATH
dependency = extension.package_product_dependencies.find { |d| d.product_name == RSI_PRODUCT }
unless dependency
  dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dependency.product_name = RSI_PRODUCT
  extension.package_product_dependencies << dependency
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dependency
  extension.frameworks_build_phase.files << build_file
end
# Xcode resolves a product only through the package that provides it.
dependency.package = package

# Embed the extension in Runner, before "Thin Binary".
embed = runner.copy_files_build_phases.find { |p| p.symbol_dst_subfolder_spec == :plug_ins }
unless embed
  embed = runner.new_copy_files_build_phase(EMBED_PHASE_NAME)
  embed.symbol_dst_subfolder_spec = :plug_ins
end
unless embed.files_references.include?(extension.product_reference)
  embedded = embed.add_file_reference(extension.product_reference, true)
  embedded.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
end
thin_binary = runner.shell_script_build_phases.find { |p| p.name == 'Thin Binary' }
if thin_binary && runner.build_phases.index(embed) > runner.build_phases.index(thin_binary)
  runner.build_phases.delete(embed)
  runner.build_phases.insert(runner.build_phases.index(thin_binary), embed)
end
runner.add_dependency(extension) unless runner.dependencies.any? { |d| d.target == extension }

project.save
puts "#{EXTENSION_NAME} (#{EXTENSION_BUNDLE_ID}) configured in #{PROJECT_PATH}"
