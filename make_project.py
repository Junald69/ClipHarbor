from pathlib import Path
from hashlib import sha1

root = Path(__file__).parent
proj = root/'ClipHarbor.xcodeproj'
proj.mkdir(exist_ok=True)

files = [
    'ClipHarborApp.swift',
    'BrowserScreen.swift',
    'SaveVideoSheet.swift',
    'FileManagerView.swift',
    'VideoFolderManager.swift',
    'VideoThumbnailManager.swift',
    'TrashManager.swift',
    'TrashView.swift',
    'FileManagerSettingsView.swift',
    'VideoExportManager.swift',
    'BrowserModel.swift',
    'TabManager.swift',
    'TabSwitcherView.swift',
    'MediaScannerScript.swift',
    'TrackedVideo.swift',
    'MediaCandidate.swift',
    'DownloadModels.swift',
    'DownloadCenter.swift',
    'BackgroundDownloadManager.swift',
    'RequestSecurity.swift',
    'HistoryManager.swift',
    'HistoryView.swift',
    'BookmarkManager.swift',
    'BookmarkView.swift',
    'FileNaming.swift',
    'VaultModels.swift',
    'VaultCrypto.swift',
    'VaultManager.swift',
    'PrivateVaultView.swift',
    'AppSettingsManager.swift',
    'AppSettingsView.swift',
    'VaultSettingsView.swift',
    'VaultStealth.swift',
    'VideoPlaybackCoordinator.swift',
    'PlaybackPlaylistContext.swift',
    'CustomVideoPlayerView.swift',
    'ZoomableImageView.swift',
    'PlaybackSpeedFormatter.swift',
    'PlayerControlsOverlay.swift',
    'VideoTrimmerView.swift',
    'ModernVideoPlayerView.swift',
    'ContentBlockerManager.swift',
    'ZipArchiveManager.swift',
    'TextDocumentCodec.swift',
    'TextDocumentEditorSheet.swift',
    'AudioPlayerSheet.swift',
]

test_files = [
    'VaultFaultInjectionTests.swift',
]

resources = [
    'Assets.xcassets',
    'Localizable.xcstrings',
    'InfoPlist.xcstrings',
    'blocker_rules.json',
    'blocker_metadata.json',
    'PrivacyInfo.xcprivacy',
]

def ident(s): return sha1(s.encode()).hexdigest()[:24].upper()
def e(s): return f'{ident(s)} /* {s} */'

out = ['// !$*UTF8*$!', '{','\tarchiveVersion = 1;','\tclasses = {};','\tobjectVersion = 56;','\tobjects = {','']
out.append('/* Begin PBXBuildFile section */')
for name in files:
    out.append(f'\t\t{e("build "+name)} = {{isa = PBXBuildFile; fileRef = {e("file "+name)}; }};')
for name in resources:
    out.append(f'\t\t{e("build "+name)} = {{isa = PBXBuildFile; fileRef = {e("file "+name)}; }};')
for name in test_files:
    out.append(f'\t\t{e("test build "+name)} = {{isa = PBXBuildFile; fileRef = {e("test file "+name)}; }};')
out.append(f'\t\t{e("build pkg ZIPFoundation")} = {{isa = PBXBuildFile; productRef = {e("pkg product ZIPFoundation")}; }};')
out.append('/* End PBXBuildFile section */\n')

out.append('/* Begin PBXContainerItemProxy section */')
out.extend([
    f'\t\t{e("container proxy")} = {{',
    '\t\t\tisa = PBXContainerItemProxy;',
    f'\t\t\tcontainerPortal = {e("project")};',
    '\t\t\tproxyType = 1;',
    f'\t\t\tremoteGlobalIDString = {ident("target")};',
    '\t\t\tremoteInfo = ClipHarbor;',
    '\t\t};',
    '/* End PBXContainerItemProxy section */\n'
])

out.append('/* Begin PBXFileReference section */')
out.append(f'\t\t{e("file Info.plist")} = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};')
for name in files:
    out.append(f'\t\t{e("file "+name)} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};')
for name in resources:
    if name.endswith('.xcassets'):
        file_type = "folder.assetcatalog"
    elif name.endswith('.xcstrings'):
        file_type = "text.json.xcstrings"
    elif name.endswith('.xcprivacy'):
        file_type = "text.xml"
    else:
        file_type = "text.json"
    out.append(f'\t\t{e("file "+name)} = {{isa = PBXFileReference; lastKnownFileType = {file_type}; path = {name}; sourceTree = "<group>"; }};')
for name in test_files:
    out.append(f'\t\t{e("test file "+name)} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};')
out.append(f'\t\t{e("product app")} = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = ClipHarbor.app; sourceTree = BUILT_PRODUCTS_DIR; }};')
out.append(f'\t\t{e("product test")} = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = ClipHarborTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};')
out.append('/* End PBXFileReference section */\n')

out.append('/* Begin PBXGroup section */')
out.extend([
    f'\t\t{e("main group")} = {{',
    '\t\t\tisa = PBXGroup;',
    f'\t\t\tchildren = ({e("source group")}, {e("tests group")}, {e("product group")}, );',
    '\t\t\tsourceTree = "<group>";',
    '\t\t};',
    f'\t\t{e("source group")} = {{',
    '\t\t\tisa = PBXGroup;',
    '\t\t\tchildren = (',
    f'\t\t\t\t{e("file Info.plist")},',
])
for name in files: out.append(f'\t\t\t\t{e("file "+name)},')
for name in resources: out.append(f'\t\t\t\t{e("file "+name)},')
out.extend([
    '\t\t\t);',
    '\t\t\tpath = ClipHarbor;',
    '\t\t\tsourceTree = "<group>";',
    '\t\t};',
    f'\t\t{e("tests group")} = {{',
    '\t\t\tisa = PBXGroup;',
    '\t\t\tchildren = (',
])
for name in test_files: out.append(f'\t\t\t\t{e("test file "+name)},')
out.extend([
    '\t\t\t);',
    '\t\t\tpath = ClipHarborTests;',
    '\t\t\tsourceTree = "<group>";',
    '\t\t};',
    f'\t\t{e("product group")} = {{',
    '\t\t\tisa = PBXGroup;',
    f'\t\t\tchildren = ({e("product app")}, {e("product test")}, );',
    '\t\t\tname = Products;',
    '\t\t\tsourceTree = "<group>";',
    '\t\t};',
    '/* End PBXGroup section */\n'
])

out.extend([
    '/* Begin PBXFrameworksBuildPhase section */',
    f'\t\t{e("frameworks phase")} = {{',
    '\t\t\tisa = PBXFrameworksBuildPhase;',
    '\t\t\tbuildActionMask = 2147483647;',
    '\t\t\tfiles = (',
    f'\t\t\t\t{e("build pkg ZIPFoundation")},',
    '\t\t\t);',
    '\t\t\trunOnlyForDeploymentPostprocessing = 0;',
    '\t\t};',
    '/* End PBXFrameworksBuildPhase section */\n',
    '/* Begin PBXNativeTarget section */',
    f'\t\t{e("target")} = {{',
    '\t\t\tisa = PBXNativeTarget;',
    f'\t\t\tbuildConfigurationList = {e("target configs")};',
    f'\t\t\tbuildPhases = ({e("sources phase")}, {e("frameworks phase")}, {e("resources phase")}, );',
    '\t\t\tbuildRules = ();',
    '\t\t\tdependencies = ();',
    '\t\t\tname = ClipHarbor;',
    f'\t\t\tpackageProductDependencies = ({e("pkg product ZIPFoundation")}, );',
    f'\t\t\tproductReference = {e("product app")};',
    '\t\t\tproductName = ClipHarbor;',
    '\t\t\tproductType = "com.apple.product-type.application";',
    '\t\t};',
    f'\t\t{e("test target")} = {{',
    '\t\t\tisa = PBXNativeTarget;',
    f'\t\t\tbuildConfigurationList = {e("test target configs")};',
    f'\t\t\tbuildPhases = ({e("test sources phase")}, );',
    '\t\t\tbuildRules = ();',
    f'\t\t\tdependencies = ({e("target dependency")}, );',
    '\t\t\tname = ClipHarborTests;',
    f'\t\t\tproductReference = {e("product test")};',
    '\t\t\tproductName = ClipHarborTests;',
    '\t\t\tproductType = "com.apple.product-type.bundle.unit-test";',
    '\t\t};',
    '/* End PBXNativeTarget section */\n',
    '/* Begin PBXProject section */',
    f'\t\t{e("project")} = {{',
    '\t\t\tisa = PBXProject;',
    '\t\t\tattributes = {',
    '\t\t\t\tBuildIndependentTargetsInParallel = 1;',
    '\t\t\t\tLastUpgradeCheck = 1600;',
    f'\t\t\t\tTargetAttributes = {{{e("target")} = {{CreatedOnToolsVersion = 16.0; }}; {e("test target")} = {{CreatedOnToolsVersion = 16.0; TestTargetID = {ident("target")}; }}; }};',
    '\t\t\t};',
    f'\t\t\tbuildConfigurationList = {e("project configs")};',
    '\t\t\tcompatibilityVersion = "Xcode 14.0";',
    '\t\t\tdevelopmentRegion = en;',
    '\t\t\thasScannedForEncodings = 0;',
    '\t\t\tknownRegions = (en, ja, Base, );',
    f'\t\t\tmainGroup = {e("main group")};',
    f'\t\t\tpackageReferences = ({e("pkg ref ZIPFoundation")}, );',
    f'\t\t\tproductRefGroup = {e("product group")};',
    '\t\t\tprojectDirPath = "";',
    '\t\t\tprojectRoot = "";',
    f'\t\t\ttargets = ({e("target")}, {e("test target")}, );',
    '\t\t};',
    '/* End PBXProject section */\n',
    '/* Begin PBXSourcesBuildPhase section */',
    f'\t\t{e("sources phase")} = {{',
    '\t\t\tisa = PBXSourcesBuildPhase;',
    '\t\t\tbuildActionMask = 2147483647;',
    '\t\t\tfiles = (',
])
for name in files: out.append(f'\t\t\t\t{e("build "+name)},')
out.extend([
    '\t\t\t);',
    '\t\t\trunOnlyForDeploymentPostprocessing = 0;',
    '\t\t};',
    f'\t\t{e("test sources phase")} = {{',
    '\t\t\tisa = PBXSourcesBuildPhase;',
    '\t\t\tbuildActionMask = 2147483647;',
    '\t\t\tfiles = (',
])
for name in test_files: out.append(f'\t\t\t\t{e("test build "+name)},')
out.extend([
    '\t\t\t);',
    '\t\t\trunOnlyForDeploymentPostprocessing = 0;',
    '\t\t};',
    '/* End PBXSourcesBuildPhase section */\n',
    '/* Begin PBXResourcesBuildPhase section */',
    f'\t\t{e("resources phase")} = {{',
    '\t\t\tisa = PBXResourcesBuildPhase;',
    '\t\t\tbuildActionMask = 2147483647;',
    '\t\t\tfiles = (',
])
for name in resources: out.append(f'\t\t\t\t{e("build "+name)},')
out.extend([
    '\t\t\t);',
    '\t\t\trunOnlyForDeploymentPostprocessing = 0;',
    '\t\t};',
    '/* End PBXResourcesBuildPhase section */\n',
    '/* Begin PBXTargetDependency section */',
    f'\t\t{e("target dependency")} = {{',
    '\t\t\tisa = PBXTargetDependency;',
    f'\t\t\ttarget = {e("target")};',
    f'\t\t\ttargetProxy = {e("container proxy")};',
    '\t\t};',
    '/* End PBXTargetDependency section */\n'
])

out.append('/* Begin XCBuildConfiguration section */')
for kind in ['Debug', 'Release']:
    o = 'project ' + kind
    settings = {
        'ALWAYS_SEARCH_USER_PATHS': 'NO',
        'CLANG_ENABLE_MODULES': 'YES',
        'SWIFT_VERSION': '5.0',
        'SDKROOT': 'iphoneos',
        'IPHONEOS_DEPLOYMENT_TARGET': '17.0',
        'SWIFT_OPTIMIZATION_LEVEL': '"-Onone"' if kind == 'Debug' else '"-O"',
        'ENABLE_TESTABILITY': 'YES' if kind == 'Debug' else 'NO',
        'ONLY_ACTIVE_ARCH': 'YES' if kind == 'Debug' else 'NO',
        'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'DEBUG' if kind == 'Debug' else '""'
    }
    out.extend([f'\t\t{e(o)} = {{', '\t\t\tisa = XCBuildConfiguration;', '\t\t\tbuildSettings = {'])
    for key, val in settings.items(): out.append(f'\t\t\t\t{key} = {val};')
    out.extend(['\t\t\t};', f'\t\t\tname = {kind};', '\t\t};'])

for kind in ['Debug', 'Release']:
    o = 'target ' + kind
    settings = {
        'CODE_SIGN_STYLE': 'Automatic' if kind == 'Debug' else 'Manual',
        'CURRENT_PROJECT_VERSION': '1',
        'MARKETING_VERSION': '1.0.0',
        'GENERATE_INFOPLIST_FILE': 'YES',
        'INFOPLIST_FILE': 'ClipHarbor/Info.plist',
        'INFOPLIST_KEY_CFBundleDisplayName': 'ClipHarbor',
        'INFOPLIST_KEY_UILaunchScreen_Generation': 'YES',
        'INFOPLIST_KEY_UIApplicationSceneManifest_Generation': 'YES',
        'INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents': 'YES',
        'INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone': '"UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"',
        'IPHONEOS_DEPLOYMENT_TARGET': '17.0',
        'SWIFT_VERSION': '5.0',
        'TARGETED_DEVICE_FAMILY': '"1"',
        'PRODUCT_BUNDLE_IDENTIFIER': 'com.junald69.clipharbor',
        'PRODUCT_NAME': '"$(TARGET_NAME)"',
        'SWIFT_EMIT_LOC_STRINGS': 'YES',
        'ASSETCATALOG_COMPILER_APPICON_NAME': 'AppIcon',
        'ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS': 'YES',
        'SUPPORTED_PLATFORMS': '"iphoneos iphonesimulator"',
        'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'DEBUG' if kind == 'Debug' else '""'
    }
    if kind == 'Release':
        settings['CODE_SIGN_IDENTITY'] = '"Apple Distribution"'
        settings['DEVELOPMENT_TEAM'] = '"$(DEVELOPMENT_TEAM)"'
        settings['PROVISIONING_PROFILE_SPECIFIER'] = '"$(APP_PROVISIONING_PROFILE_SPECIFIER)"'
    out.extend([f'\t\t{e(o)} = {{', '\t\t\tisa = XCBuildConfiguration;', '\t\t\tbuildSettings = {'])
    for key, val in settings.items(): out.append(f'\t\t\t\t{key} = {val};')
    out.extend(['\t\t\t};', f'\t\t\tname = {kind};', '\t\t};'])

for kind in ['Debug', 'Release']:
    o = 'test target ' + kind
    settings = {
        'BUNDLE_LOADER': '"$(TEST_HOST)"',
        'TEST_HOST': '"$(BUILT_PRODUCTS_DIR)/ClipHarbor.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/ClipHarbor"',
        'PRODUCT_BUNDLE_IDENTIFIER': 'com.junald69.clipharborTests',
        'PRODUCT_NAME': '"$(TARGET_NAME)"',
        'IPHONEOS_DEPLOYMENT_TARGET': '17.0',
        'SWIFT_VERSION': '5.0',
        'TARGETED_DEVICE_FAMILY': '"1"',
        'SDKROOT': 'iphoneos',
        'SUPPORTED_PLATFORMS': '"iphoneos iphonesimulator"',
        'GENERATE_INFOPLIST_FILE': 'YES'
    }
    out.extend([f'\t\t{e(o)} = {{', '\t\t\tisa = XCBuildConfiguration;', '\t\t\tbuildSettings = {'])
    for key, val in settings.items(): out.append(f'\t\t\t\t{key} = {val};')
    out.extend(['\t\t\t};', f'\t\t\tname = {kind};', '\t\t};'])

out.append('/* End XCBuildConfiguration section */\n')

out.extend([
    '/* Begin XCConfigurationList section */',
    f'\t\t{e("project configs")} = {{', '\t\t\tisa = XCConfigurationList;',
    f'\t\t\tbuildConfigurations = ({e("project Debug")}, {e("project Release")}, );',
    '\t\t\tdefaultConfigurationIsVisible = 0;', '\t\t\tdefaultConfigurationName = Release;', '\t\t};',
    f'\t\t{e("target configs")} = {{', '\t\t\tisa = XCConfigurationList;',
    f'\t\t\tbuildConfigurations = ({e("target Debug")}, {e("target Release")}, );',
    '\t\t\tdefaultConfigurationIsVisible = 0;', '\t\t\tdefaultConfigurationName = Release;', '\t\t};',
    f'\t\t{e("test target configs")} = {{', '\t\t\tisa = XCConfigurationList;',
    f'\t\t\tbuildConfigurations = ({e("test target Debug")}, {e("test target Release")}, );',
    '\t\t\tdefaultConfigurationIsVisible = 0;', '\t\t\tdefaultConfigurationName = Release;', '\t\t};',
    '/* End XCConfigurationList section */\n',
    '/* Begin XCRemoteSwiftPackageReference section */',
    f'\t\t{e("pkg ref ZIPFoundation")} = {{',
    '\t\t\tisa = XCRemoteSwiftPackageReference;',
    '\t\t\trepositoryURL = "https://github.com/weichsel/ZIPFoundation.git";',
    '\t\t\trequirement = {',
    '\t\t\t\tkind = exactVersion;',
    '\t\t\t\tversion = 0.9.20;',
    '\t\t\t};',
    '\t\t};',
    '/* End XCRemoteSwiftPackageReference section */\n',
    '/* Begin XCSwiftPackageProductDependency section */',
    f'\t\t{e("pkg product ZIPFoundation")} = {{',
    '\t\t\tisa = XCSwiftPackageProductDependency;',
    f'\t\t\tpackage = {e("pkg ref ZIPFoundation")};',
    '\t\t\tproductName = ZIPFoundation;',
    '\t\t};',
    '/* End XCSwiftPackageProductDependency section */', '\t};',
    f'\trootObject = {e("project")};', '}'
])

(proj/'project.pbxproj').write_text('\n'.join(out)+'\n', encoding='utf-8')

schemeFolder = proj/'xcshareddata'/'xcschemes'
schemeFolder.mkdir(parents=True, exist_ok=True)
schemeFolder.joinpath('ClipHarbor.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries>
      <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
        <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident('target')}" BuildableName="ClipHarbor.app" BlueprintName="ClipHarbor" ReferencedContainer="container:ClipHarbor.xcodeproj"/>
      </BuildActionEntry>
      <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">
        <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident('test target')}" BuildableName="ClipHarborTests.xctest" BlueprintName="ClipHarborTests" ReferencedContainer="container:ClipHarbor.xcodeproj"/>
      </BuildActionEntry>
    </BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
    <Testables>
      <TestableReference skipped="NO">
        <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident('test target')}" BuildableName="ClipHarborTests.xctest" BlueprintName="ClipHarborTests" ReferencedContainer="container:ClipHarbor.xcodeproj"/>
      </TestableReference>
    </Testables>
  </TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
    <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident('target')}" BuildableName="ClipHarbor.app" BlueprintName="ClipHarbor" ReferencedContainer="container:ClipHarbor.xcodeproj"/></BuildableProductRunnable>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident('target')}" BuildableName="ClipHarbor.app" BlueprintName="ClipHarbor" ReferencedContainer="container:ClipHarbor.xcodeproj"/></BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''', encoding='utf-8')

print('Generated', proj)
