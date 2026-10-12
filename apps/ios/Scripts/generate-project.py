#!/usr/bin/env python3
"""Deterministic, dependency-free Xcode project generator. No absolute source paths."""
import hashlib, pathlib, json
root = pathlib.Path(__file__).resolve().parents[1]
project = root / 'CatpawM.xcodeproj'
project.mkdir(exist_ok=True)
def uid(value): return hashlib.sha256(value.encode()).hexdigest()[:24].upper()
def q(s): return json.dumps(s,ensure_ascii=False)
objects=[]
def obj(key, body): objects.append(f'{uid(key)} = {{ {body} }};'); return uid(key)
files=sorted(str(p.relative_to(root)) for p in (root/'Sources').rglob('*.swift'))
file_ids=[]; build_ids=[]
for path in files:
 file_ids.append(obj('file:'+path, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(path)}; sourceTree = "<group>";'))
 build_ids.append(obj('build:'+path, f'isa = PBXBuildFile; fileRef = {uid("file:"+path)};'))
testfile=obj('test-file','isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Tests/NativeTests.swift; sourceTree = \"<group>\";')
testbuild=obj('test-build',f'isa = PBXBuildFile; fileRef = {testfile};')
uifile=obj('ui-test-file','isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Tests/NativeUITests.swift; sourceTree = "<group>";')
uibuild=obj('ui-test-build',f'isa = PBXBuildFile; fileRef = {uifile};')
product=obj('product','isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = CatpawM.app; sourceTree = BUILT_PRODUCTS_DIR;')
testproduct=obj('test-product','isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = CatpawMTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
uiproduct=obj('ui-test-product','isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = CatpawMUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
products=obj('products',f'isa = PBXGroup; children = ({product},{testproduct},{uiproduct}); name = Products; sourceTree = "<group>";')
group=obj('group',f'isa = PBXGroup; children = ({",".join(file_ids+[testfile,uifile,uid("ui-resource"),uid("info-strings"),products])}); sourceTree = "<group>";')
sources=obj('sources',f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(build_ids)}); runOnlyForDeploymentPostprocessing = 0;')
frameworks=obj('frameworks','isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
uiresource=obj('ui-resource','isa = PBXFileReference; lastKnownFileType = text.json; path = Resources/UIStrings.json; sourceTree = "<group>";')
uiresourcebuild=obj('ui-resource-build',f'isa = PBXBuildFile; fileRef = {uiresource};')
infolocales=[obj('info-'+language,f'isa = PBXFileReference; lastKnownFileType = text.plist.strings; name = {q(language)}; path = {q("Resources/"+language+".lproj/InfoPlist.strings")}; sourceTree = "<group>";') for language in ['zh-Hans','en']]
infostrings=obj('info-strings',f'isa = PBXVariantGroup; children = ({",".join(infolocales)}); name = InfoPlist.strings; sourceTree = "<group>";')
infostringsbuild=obj('info-strings-build',f'isa = PBXBuildFile; fileRef = {infostrings};')
resources=obj('resources',f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({uiresourcebuild},{infostringsbuild}); runOnlyForDeploymentPostprocessing = 0;')
def configs(prefix, settings):
 ids=[]
 for name in ['Debug','Release']:
  mode='SWIFT_OPTIMIZATION_LEVEL = "-Onone"; DEBUG_INFORMATION_FORMAT = dwarf; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG; ENABLE_TESTABILITY = YES;' if name=='Debug' else 'SWIFT_OPTIMIZATION_LEVEL = "-O"; DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";'
  ids.append(obj(prefix+name,f'isa = XCBuildConfiguration; buildSettings = {{ {settings} {mode} }}; name = {name};'))
 return obj(prefix+'list',f'isa = XCConfigurationList; buildConfigurations = ({",".join(ids)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
projectconfigs=configs('project-config', 'CLANG_ENABLE_MODULES = YES; SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 17.0;')
targetconfigs=configs('target-config','PRODUCT_NAME = "$(TARGET_NAME)"; PRODUCT_BUNDLE_IDENTIFIER = com.example.CatpawM; SWIFT_VERSION = 5.0; TARGETED_DEVICE_FAMILY = "1,2"; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; INFOPLIST_FILE = Resources/Info.plist; GENERATE_INFOPLIST_FILE = NO; CODE_SIGN_STYLE = Automatic; DEVELOPMENT_TEAM = ""; ENABLE_PREVIEWS = YES; CURRENT_PROJECT_VERSION = 1; MARKETING_VERSION = 0.1.0; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks";')
target=obj('target',f'isa = PBXNativeTarget; buildConfigurationList = {targetconfigs}; buildPhases = ({sources},{frameworks},{resources}); buildRules = (); dependencies = (); name = CatpawM; productName = CatpawM; productReference = {product}; productType = "com.apple.product-type.application";')
testsources=obj('test-sources',f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({testbuild}); runOnlyForDeploymentPostprocessing = 0;')
testconfigs=configs('test-config','PRODUCT_NAME = \"$(TARGET_NAME)\"; PRODUCT_BUNDLE_IDENTIFIER = com.example.CatpawMTests; SWIFT_VERSION = 5.0; GENERATE_INFOPLIST_FILE = YES; TEST_HOST = \"$(BUILT_PRODUCTS_DIR)/CatpawM.app/CatpawM\"; BUNDLE_LOADER = \"$(TEST_HOST)\"; CODE_SIGN_STYLE = Automatic; TARGETED_DEVICE_FAMILY = \"1,2\";')
proxy=obj('test-proxy',f'isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {target}; remoteInfo = CatpawM;')
dependency=obj('test-dependency',f'isa = PBXTargetDependency; target = {target}; targetProxy = {proxy};')
testtarget=obj('test-target',f'isa = PBXNativeTarget; buildConfigurationList = {testconfigs}; buildPhases = ({testsources}); buildRules = (); dependencies = ({dependency}); name = CatpawMTests; productName = CatpawMTests; productReference = {testproduct}; productType = \"com.apple.product-type.bundle.unit-test\";')
uisources=obj('ui-test-sources',f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({uibuild}); runOnlyForDeploymentPostprocessing = 0;')
uiconfigs=configs('ui-test-config','PRODUCT_NAME = "$(TARGET_NAME)"; PRODUCT_BUNDLE_IDENTIFIER = com.example.CatpawMUITests; SWIFT_VERSION = 5.0; GENERATE_INFOPLIST_FILE = YES; TEST_TARGET_NAME = CatpawM; CODE_SIGN_STYLE = Automatic; TARGETED_DEVICE_FAMILY = "1,2";')
uitarget=obj('ui-test-target',f'isa = PBXNativeTarget; buildConfigurationList = {uiconfigs}; buildPhases = ({uisources}); buildRules = (); dependencies = ({dependency}); name = CatpawMUITests; productName = CatpawMUITests; productReference = {uiproduct}; productType = "com.apple.product-type.bundle.ui-testing";')
projectid=obj('project',f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 1500; }}; buildConfigurationList = {projectconfigs}; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh-Hans; hasScannedForEncodings = 0; knownRegions = (zh-Hans,en,Base); mainGroup = {group}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({target},{testtarget},{uitarget});')
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+'\n}; rootObject = '+projectid+'; }\n')
schemes=project/'xcshareddata/xcschemes'; schemes.mkdir(parents=True,exist_ok=True)
ref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="CatpawM.app" BlueprintName="CatpawM" ReferencedContainer="container:CatpawM.xcodeproj"/>'
(schemes/'CatpawM.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1500" version="1.7">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{testtarget}" BuildableName="CatpawMTests.xctest" BlueprintName="CatpawMTests" ReferencedContainer="container:CatpawM.xcodeproj"/></TestableReference><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uitarget}" BuildableName="CatpawMUITests.xctest" BlueprintName="CatpawMUITests" ReferencedContainer="container:CatpawM.xcodeproj"/></TestableReference></Testables></TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(f'{len(files)} sources registered in CatpawM shared scheme')
