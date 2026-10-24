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
    'VideoThumbnailGenerator.swift',
    'MediaVerification.swift',
    'BrowserModel.swift',
    'MediaScannerScript.swift',
    'TrackedVideo.swift',
    'MediaCandidate.swift',
    'DownloadModels.swift',
    'DownloadCenter.swift',
    'RequestSecurity.swift',
    'FileNaming.swift',
]

def ident(s): return sha1(s.encode()).hexdigest()[:24].upper()
def e(s): return f'{ident(s)} /* {s} */'

out = ['// !$*UTF8*$!', '{','\tarchiveVersion = 1;','\tclasses = {};','\tobjectVersion = 56;','\tobjects = {','']
out.append('/* Begin PBXBuildFile section */')
for name in files:
    out.append(f'\t\t{e("build "+name)} = {{isa = PBXBuildFile; fileRef = {e("file "+name)}; }};')
out.append('/* End PBXBuildFile section */\n')
out.append('/* Begin PBXFileReference section */')
out.append(f'\t\t{e("file Info.plist")} = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};')
for name in files:
    out.append(f'\t\t{e("file "+name)} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};')
out.append(f'\t\t{e("product app")} = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = ClipHarbor.app; sourceTree = BUILT_PRODUCTS_DIR; }};')
out.append('/* End PBXFileReference section */\n')
out.append('/* Begin PBXGroup section */')
out.extend([
 f'\t\t{e("main group")} = {{',
 '\t\t\tisa = PBXGroup;',
 f'\t\t\tchildren = ({e("source group")}, {e("product group")}, );',
 '\t\t\tsourceTree = "<group>";',
 '\t\t};',
 f'\t\t{e("source group")} = {{',
 '\t\t\tisa = PBXGroup;',
 '\t\t\tchildren = (',
 f'\t\t\t\t{e("file Info.plist")},',
])
for name in files:out.append(f'\t\t\t\t{e("file "+name)},')
out.extend(['\t\t\t);','\t\t\tpath = ClipHarbor;','\t\t\tsourceTree = "<group>";','\t\t};',
 f'\t\t{e("product group")} = {{',
 '\t\t\tisa = PBXGroup;',f'\t\t\tchildren = ({e("product app")}, );',
 '\t\t\tname = Products;','\t\t\tsourceTree = "<group>";','\t\t};','/* End PBXGroup section */\n'])
out.extend([
 '/* Begin PBXNativeTarget section */',
 f'\t\t{e("target")} = {{',
 '\t\t\tisa = PBXNativeTarget;',
 f'\t\t\tbuildConfigurationList = {e("target configs")};',
 f'\t\t\tbuildPhases = ({e("sources phase")}, );',
 '\t\t\tbuildRules = ();','\t\t\tdependencies = ();',
 '\t\t\tname = ClipHarbor;',
 f'\t\t\tproductReference = {e("product app")};',
 '\t\t\tproductName = ClipHarbor;',
 '\t\t\tproductType = "com.apple.product-type.application";',
 '\t\t};','/* End PBXNativeTarget section */\n',
 '/* Begin PBXProject section */',
 f'\t\t{e("project")} = {{','\t\t\tisa = PBXProject;',
 '\t\t\tattributes = {','\t\t\t\tBuildIndependentTargetsInParallel = 1;',
 '\t\t\t\tLastUpgradeCheck = 1600;',
 f'\t\t\t\tTargetAttributes = {{{e("target")} = {{CreatedOnToolsVersion = 16.0; }}; }};',
 '\t\t\t};',
 f'\t\t\tbuildConfigurationList = {e("project configs")};',
 '\t\t\tcompatibilityVersion = "Xcode 14.0";',
 '\t\t\tdevelopmentRegion = ja;',
 '\t\t\thasScannedForEncodings = 0;',
 '\t\t\tknownRegions = (ja, en, Base, );',
 f'\t\t\tmainGroup = {e("main group")};',
 f'\t\t\tproductRefGroup = {e("product group")};',
 '\t\t\tprojectDirPath = "";',
 '\t\t\tprojectRoot = "";',
 '\t\t\ttargets = ('+e('target')+', );',
 '\t\t};','/* End PBXProject section */\n',
 '/* Begin PBXSourcesBuildPhase section */',
 f'\t\t{e("sources phase")} = {{','\t\t\tisa = PBXSourcesBuildPhase;',
 '\t\t\tbuildActionMask = 2147483647;',
 '\t\t\tfiles = (',
])
for name in files:out.append(f'\t\t\t\t{e("build "+name)},')
out.extend(['\t\t\t);','\t\t\trunOnlyForDeploymentPostprocessing = 0;','\t\t};','/* End PBXSourcesBuildPhase section */\n'])
out.append('/* Begin XCBuildConfiguration section */')
for kind in ['Debug','Release']:
    o = 'project '+kind
    settings = {'ALWAYS_SEARCH_USER_PATHS':'NO','CLANG_ENABLE_MODULES':'YES','SWIFT_VERSION':'5.0',
                'SDKROOT':'iphoneos','IPHONEOS_DEPLOYMENT_TARGET':'17.0',
                'SWIFT_OPTIMIZATION_LEVEL':'"-Onone"' if kind=='Debug' else '"-O"',
                'ENABLE_TESTABILITY':'YES' if kind=='Debug' else 'NO'}
    out.extend([f'\t\t{e(o)} = {{','\t\t\tisa = XCBuildConfiguration;','\t\t\tbuildSettings = {'])
    for key, val in settings.items():out.append(f'\t\t\t\t{key} = {val};')
    out.extend(['\t\t\t};',f'\t\t\tname = {kind};','\t\t};'])
for kind in ['Debug','Release']:
    o = 'target '+kind
    settings = {'CODE_SIGN_STYLE':'Automatic',
                'CURRENT_PROJECT_VERSION':'4','MARKETING_VERSION':'2.2.1',
                'GENERATE_INFOPLIST_FILE':'YES',
                'INFOPLIST_FILE':'ClipHarbor/Info.plist',
                'INFOPLIST_KEY_CFBundleDisplayName':'ClipHarbor',
                'INFOPLIST_KEY_UILaunchScreen_Generation':'YES',
                'INFOPLIST_KEY_UIApplicationSceneManifest_Generation':'YES',
                'INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents':'YES',
                'INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone':'"UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"',
                'IPHONEOS_DEPLOYMENT_TARGET':'17.0',
                'SWIFT_VERSION':'5.0',
                'TARGETED_DEVICE_FAMILY':'"1"',
                'PRODUCT_BUNDLE_IDENTIFIER':'com.example.ClipHarbor',
                'PRODUCT_NAME':'"$(TARGET_NAME)"',
                'SWIFT_EMIT_LOC_STRINGS':'YES',
                'ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS':'YES',
                'SUPPORTED_PLATFORMS':'"iphoneos iphonesimulator"'}
    out.extend([f'\t\t{e(o)} = {{','\t\t\tisa = XCBuildConfiguration;','\t\t\tbuildSettings = {'])
    for key, val in settings.items():out.append(f'\t\t\t\t{key} = {val};')
    out.extend(['\t\t\t};',f'\t\t\tname = {kind};','\t\t};'])
out.append('/* End XCBuildConfiguration section */\n')
out.extend(['/* Begin XCConfigurationList section */',
    f'\t\t{e("project configs")} = {{','\t\t\tisa = XCConfigurationList;',
    f'\t\t\tbuildConfigurations = ({e("project Debug")}, {e("project Release")}, );',
    '\t\t\tdefaultConfigurationIsVisible = 0;','\t\t\tdefaultConfigurationName = Release;','\t\t};',
    f'\t\t{e("target configs")} = {{','\t\t\tisa = XCConfigurationList;',
    f'\t\t\tbuildConfigurations = ({e("target Debug")}, {e("target Release")}, );',
    '\t\t\tdefaultConfigurationIsVisible = 0;','\t\t\tdefaultConfigurationName = Release;','\t\t};',
    '/* End XCConfigurationList section */','\t};',
    f'\trootObject = {e("project")};','}'])
(proj/'project.pbxproj').write_text('\n'.join(out)+'\n',encoding='utf-8')

schemeFolder = proj/'xcshareddata'/'xcschemes'
schemeFolder.mkdir(parents=True,exist_ok=True)
schemeFolder.joinpath('ClipHarbor.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries>
      <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
        <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident('target')}" BuildableName="ClipHarbor.app" BlueprintName="ClipHarbor" ReferencedContainer="container:ClipHarbor.xcodeproj"/>
      </BuildActionEntry>
    </BuildActionEntries>
  </BuildAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
    <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident('target')}" BuildableName="ClipHarbor.app" BlueprintName="ClipHarbor" ReferencedContainer="container:ClipHarbor.xcodeproj"/></BuildableProductRunnable>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident('target')}" BuildableName="ClipHarbor.app" BlueprintName="ClipHarbor" ReferencedContainer="container:ClipHarbor.xcodeproj"/></BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''',encoding='utf-8')
print('Generated',proj)
