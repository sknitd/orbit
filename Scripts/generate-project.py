#!/usr/bin/env python3
"""Generate the checked-in Xcode project deterministically using the standard library."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "OrbitDrop.xcodeproj"
PROJECT.mkdir(exist_ok=True)

def ident(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()

def quote(value):
    return json.dumps(str(value))

objects = []
def obj(key, isa, fields):
    objects.append(f"\t\t{ident(key)} = {{ isa = {isa}; {fields} }};")
    return ident(key)

def refs(keys):
    return "(" + ", ".join(ident(key) for key in keys) + ")"

sources = {
    "OrbitCore": sorted(ROOT.glob("Sources/OrbitCore/*.swift")),
    "OrbitDrop": sorted(ROOT.glob("Sources/OrbitDrop/**/*.swift")),
    "OrbitDropTests": sorted(ROOT.glob("Tests/OrbitDropTests/*.swift")),
}
if not all(sources.values()):
    raise SystemExit("All three targets need source files before project generation.")
file_keys = []
for target, paths in sources.items():
    for path in paths:
        relative = path.relative_to(ROOT).as_posix()
        key = "file:" + relative
        file_keys.append(key)
        obj(key, "PBXFileReference", f"lastKnownFileType = sourcecode.swift; path = {quote(relative)}; sourceTree = SOURCE_ROOT;")
        obj("build:" + relative, "PBXBuildFile", f"fileRef = {ident(key)};")

obj("file:Resources/AppIcon.png", "PBXFileReference", 'lastKnownFileType = image.png; path = Resources/AppIcon.png; sourceTree = SOURCE_ROOT;')
file_keys.append("file:Resources/AppIcon.png")
obj("resource:icon", "PBXBuildFile", f"fileRef = {ident('file:Resources/AppIcon.png')};")
products = {"OrbitCore": ("libOrbitCore.a", "archive.ar"), "OrbitDrop": ("OrbitDrop.app", "wrapper.application"), "OrbitDropTests": ("OrbitDropTests.xctest", "wrapper.cfbundle")}
for target, (path, kind) in products.items():
    obj("product:" + target, "PBXFileReference", f"explicitFileType = {kind}; includeInIndex = 0; path = {path}; sourceTree = BUILT_PRODUCTS_DIR;")
obj("group:products", "PBXGroup", f"children = {refs(['product:' + t for t in products])}; name = Products; sourceTree = \"<group>\";")
obj("group:main", "PBXGroup", f"children = {refs(file_keys + ['group:products'])}; sourceTree = \"<group>\";")
for name in ["app-core", "tests-core"]:
    obj("link:" + name, "PBXBuildFile", f"fileRef = {ident('product:OrbitCore')};")

dependencies = {"OrbitCore": [], "OrbitDrop": ["OrbitCore"], "OrbitDropTests": ["OrbitCore", "OrbitDrop"]}
for target, deps in dependencies.items():
    dependency_keys = []
    for dependency in deps:
        key = f"dependency:{target}:{dependency}"
        proxy = key + ":proxy"
        obj(proxy, "PBXContainerItemProxy", f"containerPortal = {ident('project')}; proxyType = 1; remoteGlobalIDString = {ident('target:' + dependency)}; remoteInfo = {dependency};")
        obj(key, "PBXTargetDependency", f"target = {ident('target:' + dependency)}; targetProxy = {ident(proxy)};")
        dependency_keys.append(key)
    build_keys = ["build:" + p.relative_to(ROOT).as_posix() for p in sources[target]]
    obj("sources:" + target, "PBXSourcesBuildPhase", f"buildActionMask = 2147483647; files = {refs(build_keys)}; runOnlyForDeploymentPostprocessing = 0;")
    links = ["link:app-core"] if target == "OrbitDrop" else (["link:tests-core"] if target == "OrbitDropTests" else [])
    obj("frameworks:" + target, "PBXFrameworksBuildPhase", f"buildActionMask = 2147483647; files = {refs(links)}; runOnlyForDeploymentPostprocessing = 0;")
    resource_keys = ["resource:icon"] if target == "OrbitDrop" else []
    obj("resources:" + target, "PBXResourcesBuildPhase", f"buildActionMask = 2147483647; files = {refs(resource_keys)}; runOnlyForDeploymentPostprocessing = 0;")
    product_type = {"OrbitCore": "com.apple.product-type.library.static", "OrbitDrop": "com.apple.product-type.application", "OrbitDropTests": "com.apple.product-type.bundle.unit-test"}[target]
    phases = ["sources:" + target, "frameworks:" + target, "resources:" + target]
    obj("target:" + target, "PBXNativeTarget", f"buildConfigurationList = {ident('configs:' + target)}; buildPhases = {refs(phases)}; buildRules = (); dependencies = {refs(dependency_keys)}; name = {target}; productName = {target}; productReference = {ident('product:' + target)}; productType = {quote(product_type)};")

for scope in ["project", *products]:
    keys = []
    for configuration in ["Debug", "Release"]:
        settings = {
            "SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "14.0", "SWIFT_VERSION": "6.0",
            "CLANG_ENABLE_MODULES": "YES", "SWIFT_STRICT_CONCURRENCY": "complete",
            "CODE_SIGNING_ALLOWED": "NO", "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if configuration == "Debug" else "-O",
            "DEBUG_INFORMATION_FORMAT": "dwarf" if configuration == "Debug" else "dwarf-with-dsym",
            "ONLY_ACTIVE_ARCH": "YES" if configuration == "Debug" else "NO",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG" if configuration == "Debug" else "",
        }
        if scope != "project":
            settings.update({"PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_MODULE_NAME": scope,
                "SWIFT_INCLUDE_PATHS": "$(inherited) $(BUILT_PRODUCTS_DIR)", "ENABLE_TESTABILITY": "YES"})
        if scope == "OrbitCore":
            settings.update({"DEFINES_MODULE": "YES", "MACH_O_TYPE": "staticlib", "SKIP_INSTALL": "YES", "SWIFT_INSTALL_OBJC_HEADER": "NO"})
        if scope == "OrbitDrop":
            settings.update({"INFOPLIST_FILE": "Resources/Info.plist", "PRODUCT_BUNDLE_IDENTIFIER": "com.sknitd.OrbitDrop",
                "SWIFT_OBJC_BRIDGING_HEADER": "Sources/OrbitDrop/WebPBridge.h",
                "HEADER_SEARCH_PATHS": "$(inherited) $(SRCROOT)/build/WebP/include",
                "OTHER_LDFLAGS": "$(inherited) -L$(SRCROOT)/build/WebP/lib -lwebp -lsharpyuv",
                "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks"})
        if scope == "OrbitDropTests":
            settings.update({"GENERATE_INFOPLIST_FILE": "YES", "PRODUCT_BUNDLE_IDENTIFIER": "com.sknitd.OrbitDropTests",
                "HEADER_SEARCH_PATHS": "$(inherited) $(SRCROOT)/build/WebP/include",
                "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/OrbitDrop.app/Contents/MacOS/OrbitDrop", "BUNDLE_LOADER": "$(TEST_HOST)",
                "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks"})
        contents = " ".join(f"{key} = {quote(value)};" for key, value in sorted(settings.items()))
        key = f"config:{scope}:{configuration}"
        obj(key, "XCBuildConfiguration", f"buildSettings = {{ {contents} }}; name = {configuration};")
        keys.append(key)
    obj("configs:" + scope, "XCConfigurationList", f"buildConfigurations = {refs(keys)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")
obj("project", "PBXProject", f"attributes = {{ LastUpgradeCheck = 1600; }}; buildConfigurationList = {ident('configs:project')}; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {ident('group:main')}; productRefGroup = {ident('group:products')}; projectDirPath = \"\"; projectRoot = \"\"; targets = {refs(['target:' + t for t in products])};")
(PROJECT / "project.pbxproj").write_text("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n" + "\n".join(objects) + f"\n\t}};\n\trootObject = {ident('project')};\n}}\n")

def buildable(target):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident("target:" + target)}" BuildableName="{products[target][0]}" BlueprintName="{target}" ReferencedContainer="container:OrbitDrop.xcodeproj"/>'
scheme_dir = PROJECT / "xcshareddata/xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{buildable('OrbitDrop')}</BuildActionEntry>
<BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">{buildable('OrbitDropTests')}</BuildActionEntry>
</BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{buildable('OrbitDropTests')}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable('OrbitDrop')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugServiceExtension="internal"><BuildableProductRunnable runnableDebuggingMode="0">{buildable('OrbitDrop')}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>'''
(scheme_dir / "OrbitDrop.xcscheme").write_text(scheme)
print(f"Generated {PROJECT} ({sum(map(len, sources.values()))} source files)")
