#!/usr/bin/env python3
"""Generate CornerOrbit's standalone three-target Xcode project deterministically."""
from pathlib import Path
import hashlib
import json
import sys

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / 'CornerOrbit.xcodeproj'
CHECK = '--check' in sys.argv[1:]
if set(sys.argv[1:]) - {'--check'}:
    raise SystemExit('Usage: python3 Scripts/generate-project.py [--check]')


def ident(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()


def quote(value):
    return json.dumps(str(value))


def relative(path):
    path.resolve().relative_to(ROOT.resolve())
    return path.relative_to(ROOT).as_posix()


objects = []


def obj(key, isa, fields):
    objects.append(f'\t\t{ident(key)} = {{ isa = {isa}; {fields} }};')


def refs(keys):
    return '(' + ', '.join(ident(key) for key in keys) + ')'


sources = {
    'CornerCore': sorted((ROOT / 'Sources/CornerCore').glob('**/*.swift')),
    'CornerOrbit': sorted((ROOT / 'Sources/CornerOrbit').glob('**/*.swift')),
    'CornerOrbitTests': sorted((ROOT / 'Tests/CornerOrbitTests').glob('**/*.swift')),
}
if not all(sources.values()):
    raise SystemExit('All three targets need their finalized source files before project generation.')
file_keys = []
for target, paths in sources.items():
    for path in paths:
        name = relative(path)
        key = 'file:' + name
        file_keys.append(key)
        obj(key, 'PBXFileReference', f'lastKnownFileType = sourcecode.swift; path = {quote(name)}; sourceTree = SOURCE_ROOT;')
        obj('build:' + name, 'PBXBuildFile', f'fileRef = {ident(key)};')

resource_keys = []
resources = [ROOT / 'build/AppIcon.icns'] + sorted(path for path in (ROOT / 'Resources').glob('**/*') if path.is_file() and path.name != 'Info.plist')
for path in resources:
    name = relative(path)
    key = 'file:' + name
    kind = {'.icns': 'image.icns', '.png': 'image.png', '.json': 'text.json', '.txt': 'text'}.get(path.suffix, 'file')
    file_keys.append(key)
    obj(key, 'PBXFileReference', f'lastKnownFileType = {kind}; path = {quote(name)}; sourceTree = SOURCE_ROOT;')
    build_key = 'resource:' + name
    obj(build_key, 'PBXBuildFile', f'fileRef = {ident(key)};')
    resource_keys.append(build_key)

products = {
    'CornerCore': ('libCornerCore.a', 'archive.ar'),
    'CornerOrbit': ('CornerOrbit.app', 'wrapper.application'),
    'CornerOrbitTests': ('CornerOrbitTests.xctest', 'wrapper.cfbundle'),
}
for target, (name, kind) in products.items():
    obj('product:' + target, 'PBXFileReference', f'explicitFileType = {kind}; includeInIndex = 0; path = {name}; sourceTree = BUILT_PRODUCTS_DIR;')
obj('group:products', 'PBXGroup', f'children = {refs(["product:" + t for t in products])}; name = Products; sourceTree = "<group>";')
obj('group:main', 'PBXGroup', f'children = {refs(file_keys + ["group:products"])}; sourceTree = "<group>";')

dependencies = {'CornerCore': [], 'CornerOrbit': ['CornerCore'], 'CornerOrbitTests': ['CornerCore', 'CornerOrbit']}
for target, deps in dependencies.items():
    dependency_keys = []
    for dependency in deps:
        key = f'dependency:{target}:{dependency}'
        proxy = key + ':proxy'
        obj(proxy, 'PBXContainerItemProxy', f'containerPortal = {ident("project")}; proxyType = 1; remoteGlobalIDString = {ident("target:" + dependency)}; remoteInfo = {dependency};')
        obj(key, 'PBXTargetDependency', f'target = {ident("target:" + dependency)}; targetProxy = {ident(proxy)};')
        dependency_keys.append(key)
    obj('sources:' + target, 'PBXSourcesBuildPhase', f'buildActionMask = 2147483647; files = {refs(["build:" + relative(path) for path in sources[target]])}; runOnlyForDeploymentPostprocessing = 0;')
    links = []
    if 'CornerCore' in deps:
        key = 'link:' + target + ':CornerCore'
        obj(key, 'PBXBuildFile', f'fileRef = {ident("product:CornerCore")};')
        links.append(key)
    obj('frameworks:' + target, 'PBXFrameworksBuildPhase', f'buildActionMask = 2147483647; files = {refs(links)}; runOnlyForDeploymentPostprocessing = 0;')
    obj('resources:' + target, 'PBXResourcesBuildPhase', f'buildActionMask = 2147483647; files = {refs(resource_keys if target == "CornerOrbit" else [])}; runOnlyForDeploymentPostprocessing = 0;')
    product_type = 'com.apple.product-type.library.static' if target == 'CornerCore' else 'com.apple.product-type.application' if target == 'CornerOrbit' else 'com.apple.product-type.bundle.unit-test'
    obj('target:' + target, 'PBXNativeTarget', f'buildConfigurationList = {ident("configs:" + target)}; buildPhases = {refs(["sources:" + target, "frameworks:" + target, "resources:" + target])}; buildRules = (); dependencies = {refs(dependency_keys)}; name = {target}; productName = {target}; productReference = {ident("product:" + target)}; productType = {quote(product_type)};')

for scope in ['project', *products]:
    keys = []
    for configuration in ['Debug', 'Release']:
        settings = {
            'SDKROOT': 'macosx', 'MACOSX_DEPLOYMENT_TARGET': '14.0', 'SWIFT_VERSION': '6.0',
            'CLANG_ENABLE_MODULES': 'YES', 'SWIFT_STRICT_CONCURRENCY': 'complete',
            'CODE_SIGNING_ALLOWED': 'NO', 'SUPPORTED_PLATFORMS': 'macosx',
            'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if configuration == 'Debug' else '-O',
            'DEBUG_INFORMATION_FORMAT': 'dwarf' if configuration == 'Debug' else 'dwarf-with-dsym',
            'ONLY_ACTIVE_ARCH': 'YES' if configuration == 'Debug' else 'NO',
            'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'DEBUG' if configuration == 'Debug' else '',
        }
        if configuration == 'Release':
            settings['ARCHS'] = 'arm64 x86_64'
        if scope != 'project':
            settings.update({'PRODUCT_NAME': '$(TARGET_NAME)', 'PRODUCT_MODULE_NAME': scope,
                             'SWIFT_INCLUDE_PATHS': '$(inherited) $(BUILT_PRODUCTS_DIR)', 'ENABLE_TESTABILITY': 'YES'})
        if scope == 'CornerCore':
            settings.update({'DEFINES_MODULE': 'YES', 'MACH_O_TYPE': 'staticlib', 'SKIP_INSTALL': 'YES', 'SWIFT_INSTALL_OBJC_HEADER': 'NO'})
        if scope == 'CornerOrbit':
            settings.update({'INFOPLIST_FILE': 'Resources/Info.plist', 'PRODUCT_BUNDLE_IDENTIFIER': 'com.sknitd.CornerOrbit',
                             'OTHER_LDFLAGS': '$(inherited) -lsqlite3',
                             'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/../Frameworks'})
        if scope == 'CornerOrbitTests':
            settings.update({'GENERATE_INFOPLIST_FILE': 'YES', 'PRODUCT_BUNDLE_IDENTIFIER': 'com.sknitd.CornerOrbitTests',
                             'OTHER_LDFLAGS': '$(inherited) -lsqlite3',
                             'TEST_HOST': '$(BUILT_PRODUCTS_DIR)/CornerOrbit.app/Contents/MacOS/CornerOrbit',
                             'BUNDLE_LOADER': '$(TEST_HOST)',
                             'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks'})
        contents = ' '.join(f'{key} = {quote(value)};' for key, value in sorted(settings.items()))
        key = f'config:{scope}:{configuration}'
        obj(key, 'XCBuildConfiguration', f'buildSettings = {{ {contents} }}; name = {configuration};')
        keys.append(key)
    obj('configs:' + scope, 'XCConfigurationList', f'buildConfigurations = {refs(keys)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj('project', 'PBXProject', f'attributes = {{ LastUpgradeCheck = 1600; }}; buildConfigurationList = {ident("configs:project")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {ident("group:main")}; productRefGroup = {ident("group:products")}; projectDirPath = ""; projectRoot = ""; targets = {refs(["target:" + t for t in products])};')
project_text = '// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n' + '\n'.join(objects) + f'\n\t}};\n\trootObject = {ident("project")};\n}}\n'


def save_or_check(path, content):
    if CHECK:
        if not path.is_file() or path.read_text() != content:
            raise SystemExit('Generated project is stale. Run python3 Scripts/generate-project.py and review its changes.')
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)


def buildable(target):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident("target:" + target)}" BuildableName="{products[target][0]}" BlueprintName="{target}" ReferencedContainer="container:CornerOrbit.xcodeproj"/>'


scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{buildable('CornerOrbit')}</BuildActionEntry>
<BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">{buildable('CornerOrbitTests')}</BuildActionEntry>
</BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{buildable('CornerOrbitTests')}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable('CornerOrbit')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugServiceExtension="internal"><BuildableProductRunnable runnableDebuggingMode="0">{buildable('CornerOrbit')}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>'''
save_or_check(PROJECT / 'project.pbxproj', project_text)
save_or_check(PROJECT / 'xcshareddata/xcschemes/CornerOrbit.xcscheme', scheme)
print(f'{"Verified" if CHECK else "Generated"} CornerOrbit.xcodeproj ({sum(map(len, sources.values()))} source files, 3 targets)')
