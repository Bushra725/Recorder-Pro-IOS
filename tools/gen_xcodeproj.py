#!/usr/bin/env python3
"""Generates ScreenRecPro.xcodeproj (three targets, Swift packages, Crashlytics
run script) from the files on disk. Re-run after adding or removing files.

Usage: gen_xcodeproj.py <project root>
"""
import hashlib
import os
import sys

ROOT = os.path.abspath(sys.argv[1])
PROJ = "ScreenRecPro"
LANGS = ["en", "es", "pt-BR", "fr", "de", "ar", "hi", "id"]


def oid(*parts):
    return hashlib.md5("/".join(parts).encode()).hexdigest()[:24].upper()


def q(s):
    s = str(s)
    if s and all(c.isalnum() or c in "._/$" for c in s) and not s.startswith("$("):
        return s
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def files_under(rel, exts):
    out = []
    for dp, dns, fns in os.walk(os.path.join(ROOT, rel)):
        dns[:] = sorted(d for d in dns if not d.endswith((".xcassets", ".lproj")))
        for f in sorted(fns):
            if f.endswith(exts):
                out.append(os.path.relpath(os.path.join(dp, f), ROOT))
    return out


app_swift = files_under("ScreenRecPro", (".swift",))
ext_swift = files_under("ScreenRecBroadcast", (".swift",))
wid_swift = files_under("ScreenRecLiveActivity", (".swift",))
shared_all = ["Shared/AppGroup.swift", "Shared/RecordingActivity.swift"]

targets = {
    "ScreenRecPro": {
        "type": "com.apple.product-type.application", "product": "ScreenRecPro.app",
        "sources": app_swift + shared_all,
        "resources": ["ScreenRecPro/Resources/Assets.xcassets", "ScreenRecPro/Resources/GoogleService-Info.plist",
                      "ScreenRecPro/Resources/PrivacyInfo.xcprivacy", "VG:Localizable.strings", "VG:InfoPlist.strings"],
        "packages": ["FirebaseCore", "FirebaseCrashlytics", "FirebaseAnalytics", "FirebaseRemoteConfig",
                     "GoogleMobileAds", "UserMessagingPlatform", "AdjustSdk"],
        "bundle": "com.ol.mob.screen.recorder.app",
        "plist": "ScreenRecPro/Info.plist", "ent": "ScreenRecPro/ScreenRecPro.entitlements",
        "deploy": "16.0",
    },
    "ScreenRecBroadcast": {
        "type": "com.apple.product-type.app-extension", "product": "ScreenRecBroadcast.appex",
        "sources": ext_swift + ["Shared/AppGroup.swift"],
        "resources": ["ScreenRecBroadcast/PrivacyInfo.xcprivacy", "VG:Localizable.strings"],
        "packages": [], "bundle": "com.ol.mob.screen.recorder.app.broadcast",
        "plist": "ScreenRecBroadcast/Info.plist", "ent": "ScreenRecBroadcast/ScreenRecBroadcast.entitlements",
        "deploy": "16.0", "system": ["ReplayKit.framework"],
    },
    "ScreenRecLiveActivity": {
        "type": "com.apple.product-type.app-extension", "product": "ScreenRecLiveActivity.appex",
        "sources": wid_swift + shared_all,
        "resources": ["VG:Localizable.strings"],
        "packages": [], "bundle": "com.ol.mob.screen.recorder.app.liveactivity",
        "plist": "ScreenRecLiveActivity/Info.plist", "ent": "ScreenRecLiveActivity/ScreenRecLiveActivity.entitlements",
        "deploy": "16.2", "system": ["WidgetKit.framework", "SwiftUI.framework"],
    },
}

packages = {
    "firebase-ios-sdk": ("https://github.com/firebase/firebase-ios-sdk.git", "12.0.0",
                         ["FirebaseCore", "FirebaseCrashlytics", "FirebaseAnalytics", "FirebaseRemoteConfig"]),
    "swift-package-manager-google-mobile-ads": (
        "https://github.com/googleads/swift-package-manager-google-mobile-ads.git", "12.0.0", ["GoogleMobileAds"]),
    "swift-package-manager-google-user-messaging-platform": (
        "https://github.com/googleads/swift-package-manager-google-user-messaging-platform.git", "3.0.0",
        ["UserMessagingPlatform"]),
    "ios_sdk": ("https://github.com/adjust/ios_sdk.git", "5.0.0", ["AdjustSdk"]),
}
product_pkg = {p: name for name, (_, _, prods) in packages.items() for p in prods}

objs = {}   # id -> text block


def add(i, body):
    objs[i] = body


# ---------------------------------------------------------------- file refs
FILETYPES = {".swift": "sourcecode.swift", ".plist": "text.plist.xml", ".xcassets": "folder.assetcatalog",
             ".entitlements": "text.plist.entitlements", ".xcprivacy": "text.plist.xml",
             ".storekit": "text.json", ".strings": "text.plist.strings", ".md": "net.daringfireball.markdown"}

all_files = sorted(set(
    app_swift + ext_swift + wid_swift + shared_all +
    ["ScreenRecPro/Resources/Assets.xcassets", "ScreenRecPro/Resources/GoogleService-Info.plist",
     "ScreenRecPro/Resources/PrivacyInfo.xcprivacy", "ScreenRecPro/Resources/ScreenRecPro.storekit",
     "ScreenRecBroadcast/PrivacyInfo.xcprivacy",
     "ScreenRecPro/Info.plist", "ScreenRecPro/ScreenRecPro.entitlements",
     "ScreenRecBroadcast/Info.plist", "ScreenRecBroadcast/ScreenRecBroadcast.entitlements",
     "ScreenRecLiveActivity/Info.plist", "ScreenRecLiveActivity/ScreenRecLiveActivity.entitlements"]))

for path in all_files:
    name = os.path.basename(path)
    ext = os.path.splitext(name)[1]
    add(oid("ref", path),
        f"{{isa = PBXFileReference; lastKnownFileType = {FILETYPES.get(ext, 'text')}; "
        f"path = {q(name)}; sourceTree = \"<group>\"; }}")

# variant groups for .strings
for vg in ["Localizable.strings", "InfoPlist.strings"]:
    kids = []
    for lang in LANGS:
        rid = oid("vgref", vg, lang)
        add(rid, f"{{isa = PBXFileReference; lastKnownFileType = text.plist.strings; name = {q(lang)}; "
                 f"path = {q(lang + '.lproj/' + vg)}; sourceTree = \"<group>\"; }}")
        kids.append(rid)
    add(oid("vg", vg), "{isa = PBXVariantGroup; children = (" + "".join(f"{k}, " for k in kids) +
        f"); name = {q(vg)}; sourceTree = \"<group>\"; }}")

# products
for t, spec in targets.items():
    ptype = "wrapper.application" if spec["product"].endswith(".app") else "wrapper.app-extension"
    add(oid("product", t), f"{{isa = PBXFileReference; explicitFileType = {q(ptype)}; includeInIndex = 0; "
                           f"path = {q(spec['product'])}; sourceTree = BUILT_PRODUCTS_DIR; }}")

# system frameworks
sysfw = sorted({f for s in targets.values() for f in s.get("system", [])})
for fw in sysfw:
    add(oid("sysfw", fw), f"{{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = {q(fw)}; "
                          f"path = {q('System/Library/Frameworks/' + fw)}; sourceTree = SDKROOT; }}")

# ---------------------------------------------------------------- groups
groups = {}  # rel dir -> list of child ids


def ensure_group(rel):
    if rel in groups:
        return
    groups[rel] = []
    parent = os.path.dirname(rel)
    if rel:
        ensure_group(parent)
        groups[parent].append(("group", rel))


ensure_group("")
for path in all_files:
    d = os.path.dirname(path)
    ensure_group(d)
    groups[d].append(("file", path))
ensure_group("ScreenRecPro/Resources")
groups["ScreenRecPro/Resources"].append(("vg", "Localizable.strings"))
groups["ScreenRecPro/Resources"].append(("vg", "InfoPlist.strings"))


def child_id(kind, key):
    return {"group": oid("group", key), "file": oid("ref", key), "vg": oid("vg", key)}[kind]


def sort_key(item):
    kind, key = item
    return (0 if kind == "group" else 1, os.path.basename(key).lower())


for rel, kids in groups.items():
    kids_sorted = sorted(set(kids), key=sort_key)
    ids = [child_id(k, v) for k, v in kids_sorted]
    if rel == "":
        ids += [oid("group", "#Frameworks"), oid("group", "#Products")]
        add(oid("group", rel), "{isa = PBXGroup; children = (" + "".join(f"{i}, " for i in ids) +
            "); sourceTree = \"<group>\"; }")
    else:
        add(oid("group", rel), "{isa = PBXGroup; children = (" + "".join(f"{i}, " for i in ids) +
            f"); path = {q(os.path.basename(rel))}; sourceTree = \"<group>\"; }}")

add(oid("group", "#Products"), "{isa = PBXGroup; children = (" +
    "".join(f"{oid('product', t)}, " for t in targets) + "); name = Products; sourceTree = \"<group>\"; }")
add(oid("group", "#Frameworks"), "{isa = PBXGroup; children = (" +
    "".join(f"{oid('sysfw', f)}, " for f in sysfw) + "); name = Frameworks; sourceTree = \"<group>\"; }")

# ---------------------------------------------------------------- packages
for name, (url, ver, prods) in packages.items():
    add(oid("pkg", name), f"{{isa = XCRemoteSwiftPackageReference; repositoryURL = {q(url)}; "
                          f"requirement = {{kind = upToNextMajorVersion; minimumVersion = {q(ver)}; }}; }}")
for t, spec in targets.items():
    for p in spec["packages"]:
        add(oid("pkgdep", t, p), f"{{isa = XCSwiftPackageProductDependency; package = {oid('pkg', product_pkg[p])}; "
                                 f"productName = {q(p)}; }}")

# ---------------------------------------------------------------- targets
configs = ["Debug", "Release"]


def target_settings(t, spec, cfg):
    s = {
        "CODE_SIGN_STYLE": "Automatic",
        "DEVELOPMENT_TEAM": "",
        "CODE_SIGN_ENTITLEMENTS": spec["ent"],
        "INFOPLIST_FILE": spec["plist"],
        "GENERATE_INFOPLIST_FILE": "NO",
        "PRODUCT_BUNDLE_IDENTIFIER": spec["bundle"],
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "IPHONEOS_DEPLOYMENT_TARGET": spec["deploy"],
        "TARGETED_DEVICE_FAMILY": "1",
        "SUPPORTS_MACCATALYST": "NO",
        "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
        "SWIFT_VERSION": "5.0",
        "SWIFT_EMIT_LOC_STRINGS": "NO",
        "MARKETING_VERSION": "1.0.0",
        "CURRENT_PROJECT_VERSION": "1",
        "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
    }
    if spec["product"].endswith(".app"):
        s.update({
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
            "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
            "OTHER_LDFLAGS": "$(inherited) -ObjC",
            # Crashlytics' run script reads the dSYM and Info.plist outside the sandbox.
            "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
        })
    else:
        s.update({
            "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks",
            "APPLICATION_EXTENSION_API_ONLY": "YES",
            "SKIP_INSTALL": "YES",
        })
    return s


PROJECT_COMMON = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
    "CLANG_ANALYZER_NONNULL": "YES",
    "CLANG_CXX_LANGUAGE_STANDARD": "gnu++20",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "CLANG_ENABLE_OBJC_WEAK": "YES",
    "COPY_PHASE_STRIP": "NO",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "GCC_C_LANGUAGE_STANDARD": "gnu17",
    "GCC_NO_COMMON_BLOCKS": "YES",
    "IPHONEOS_DEPLOYMENT_TARGET": "16.0",
    "LOCALIZATION_PREFERS_STRING_CATALOGS": "NO",
    "SDKROOT": "iphoneos",
}
PROJECT_CFG = {
    "Debug": {"DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym", "ENABLE_TESTABILITY": "YES",
              "GCC_OPTIMIZATION_LEVEL": "0", "GCC_PREPROCESSOR_DEFINITIONS": "DEBUG=1 $(inherited)",
              "ONLY_ACTIVE_ARCH": "YES", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)",
              "SWIFT_OPTIMIZATION_LEVEL": "-Onone", "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE"},
    "Release": {"DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym", "ENABLE_NS_ASSERTIONS": "NO",
                "SWIFT_COMPILATION_MODE": "wholemodule", "SWIFT_OPTIMIZATION_LEVEL": "-O",
                "VALIDATE_PRODUCT": "YES", "MTL_ENABLE_DEBUG_INFO": "NO"},
}


def settings_block(d):
    return "{" + "".join(f"{q(k)} = {q(v)}; " for k, v in sorted(d.items())) + "}"


for cfg in configs:
    add(oid("projcfg", cfg), f"{{isa = XCBuildConfiguration; buildSettings = "
                             f"{settings_block({**PROJECT_COMMON, **PROJECT_CFG[cfg]})}; name = {cfg}; }}")
add(oid("projcfglist"), "{isa = XCConfigurationList; buildConfigurations = (" +
    "".join(f"{oid('projcfg', c)}, " for c in configs) + "); defaultConfigurationIsVisible = 0; "
    "defaultConfigurationName = Release; }")

CRASHLYTICS_SCRIPT = '"${BUILD_DIR%/Build/*}/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/run"\n'
CRASHLYTICS_INPUTS = [
    "${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}",
    "${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}/Contents/Resources/DWARF/${PRODUCT_NAME}",
    "${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}/Contents/Info.plist",
    "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/GoogleService-Info.plist",
    "$(TARGET_BUILD_DIR)/$(EXECUTABLE_PATH)",
    "${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}/Contents/Resources/DWARF/${PRODUCT_NAME}.debug.dylib",
]

for t, spec in targets.items():
    phases = []
    # Sources
    bfs = []
    for src in spec["sources"]:
        bf = oid("bf-src", t, src)
        add(bf, f"{{isa = PBXBuildFile; fileRef = {oid('ref', src)}; }}")
        bfs.append(bf)
    add(oid("phase-src", t), "{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (" +
        "".join(f"{b}, " for b in bfs) + "); runOnlyForDeploymentPostprocessing = 0; }")
    phases.append(oid("phase-src", t))
    # Frameworks
    bfs = []
    for p in spec["packages"]:
        bf = oid("bf-pkg", t, p)
        add(bf, f"{{isa = PBXBuildFile; productRef = {oid('pkgdep', t, p)}; }}")
        bfs.append(bf)
    for fw in spec.get("system", []):
        bf = oid("bf-fw", t, fw)
        add(bf, f"{{isa = PBXBuildFile; fileRef = {oid('sysfw', fw)}; }}")
        bfs.append(bf)
    add(oid("phase-fw", t), "{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (" +
        "".join(f"{b}, " for b in bfs) + "); runOnlyForDeploymentPostprocessing = 0; }")
    phases.append(oid("phase-fw", t))
    # Resources
    bfs = []
    for r in spec["resources"]:
        bf = oid("bf-res", t, r)
        ref = oid("vg", r[3:]) if r.startswith("VG:") else oid("ref", r)
        add(bf, f"{{isa = PBXBuildFile; fileRef = {ref}; }}")
        bfs.append(bf)
    add(oid("phase-res", t), "{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (" +
        "".join(f"{b}, " for b in bfs) + "); runOnlyForDeploymentPostprocessing = 0; }")
    phases.append(oid("phase-res", t))

    deps = []
    if t == "ScreenRecPro":
        # Embed the two extensions
        bfs = []
        for ext in ["ScreenRecBroadcast", "ScreenRecLiveActivity"]:
            bf = oid("bf-embed", ext)
            add(bf, f"{{isa = PBXBuildFile; fileRef = {oid('product', ext)}; "
                    f"settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }}")
            bfs.append(bf)
            proxy = oid("proxy", ext)
            add(proxy, f"{{isa = PBXContainerItemProxy; containerPortal = {oid('project')}; proxyType = 1; "
                       f"remoteGlobalIDString = {oid('target', ext)}; remoteInfo = {ext}; }}")
            dep = oid("dep", ext)
            add(dep, f"{{isa = PBXTargetDependency; target = {oid('target', ext)}; targetProxy = {proxy}; }}")
            deps.append(dep)
        add(oid("phase-embed"), "{isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = \"\"; "
            "dstSubfolderSpec = 13; files = (" + "".join(f"{b}, " for b in bfs) +
            "); name = \"Embed Foundation Extensions\"; runOnlyForDeploymentPostprocessing = 0; }")
        phases.append(oid("phase-embed"))
        # Crashlytics dSYM upload
        add(oid("phase-crashlytics"),
            "{isa = PBXShellScriptBuildPhase; alwaysOutOfDate = 1; buildActionMask = 2147483647; files = ( ); "
            "inputFileListPaths = ( ); inputPaths = (" + "".join(f"{q(i)}, " for i in CRASHLYTICS_INPUTS) +
            "); name = \"Upload dSYMs to Crashlytics\"; outputFileListPaths = ( ); outputPaths = ( ); "
            "runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/sh; "
            f"shellScript = {q(CRASHLYTICS_SCRIPT)}; showEnvVarsInLog = 0; }}")
        phases.append(oid("phase-crashlytics"))

    for cfg in configs:
        add(oid("tcfg", t, cfg), f"{{isa = XCBuildConfiguration; buildSettings = "
                                 f"{settings_block(target_settings(t, spec, cfg))}; name = {cfg}; }}")
    add(oid("tcfglist", t), "{isa = XCConfigurationList; buildConfigurations = (" +
        "".join(f"{oid('tcfg', t, c)}, " for c in configs) + "); defaultConfigurationIsVisible = 0; "
        "defaultConfigurationName = Release; }")

    pkgdeps = "".join(f"{oid('pkgdep', t, p)}, " for p in spec["packages"])
    add(oid("target", t),
        f"{{isa = PBXNativeTarget; buildConfigurationList = {oid('tcfglist', t)}; buildPhases = (" +
        "".join(f"{p}, " for p in phases) + "); buildRules = ( ); dependencies = (" +
        "".join(f"{d}, " for d in deps) + f"); name = {t}; packageProductDependencies = ({pkgdeps}); "
        f"productName = {t}; productReference = {oid('product', t)}; productType = {q(spec['type'])}; }}")

target_attrs = "".join(f"{oid('target', t)} = {{CreatedOnToolsVersion = 16.0; }}; " for t in targets)
add(oid("project"),
    "{isa = PBXProject; attributes = {BuildIndependentTargetsInParallel = 1; LastSwiftUpdateCheck = 1600; "
    f"LastUpgradeCheck = 1600; TargetAttributes = {{{target_attrs}}}; }}; "
    f"buildConfigurationList = {oid('projcfglist')}; compatibilityVersion = \"Xcode 14.0\"; "
    "developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (" +
    "".join(f"{q(l)}, " for l in LANGS + ["Base"]) + f"); mainGroup = {oid('group', '')}; "
    "packageReferences = (" + "".join(f"{oid('pkg', n)}, " for n in packages) + "); "
    f"productRefGroup = {oid('group', '#Products')}; projectDirPath = \"\"; projectRoot = \"\"; targets = (" +
    "".join(f"{oid('target', t)}, " for t in targets) + "); }")

# ---------------------------------------------------------------- write
by_isa = {}
for i, body in objs.items():
    isa = body.split("isa = ", 1)[1].split(";", 1)[0]
    by_isa.setdefault(isa, []).append((i, body))

lines = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {", "\t};", "\tobjectVersion = 60;",
         "\tobjects = {", ""]
for isa in sorted(by_isa):
    lines.append(f"/* Begin {isa} section */")
    for i, body in sorted(by_isa[isa]):
        lines.append(f"\t\t{i} = {body};")
    lines.append(f"/* End {isa} section */")
    lines.append("")
lines += ["\t};", f"\trootObject = {oid('project')};", "}", ""]

xcodeproj = os.path.join(ROOT, f"{PROJ}.xcodeproj")
os.makedirs(os.path.join(xcodeproj, "project.xcworkspace", "xcshareddata"), exist_ok=True)
os.makedirs(os.path.join(xcodeproj, "xcshareddata", "xcschemes"), exist_ok=True)
with open(os.path.join(xcodeproj, "project.pbxproj"), "w") as f:
    f.write("\n".join(lines))
with open(os.path.join(xcodeproj, "project.xcworkspace", "contents.xcworkspacedata"), "w") as f:
    f.write('<?xml version="1.0" encoding="UTF-8"?>\n<Workspace\n   version = "1.0">\n'
            '   <FileRef\n      location = "self:">\n   </FileRef>\n</Workspace>\n')
with open(os.path.join(xcodeproj, "project.xcworkspace", "xcshareddata", "IDEWorkspaceChecks.plist"), "w") as f:
    f.write('<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
            '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n'
            '\t<key>IDEDidComputeMac32BitWarning</key>\n\t<true/>\n</dict>\n</plist>\n')

app = oid("target", "ScreenRecPro")
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{app}" BuildableName = "ScreenRecPro.app" BlueprintName = "ScreenRecPro" ReferencedContainer = "container:ScreenRecPro.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{app}" BuildableName = "ScreenRecPro.app" BlueprintName = "ScreenRecPro" ReferencedContainer = "container:ScreenRecPro.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
      <StoreKitConfigurationFileReference identifier = "../../ScreenRecPro/Resources/ScreenRecPro.storekit">
      </StoreKitConfigurationFileReference>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
'''
with open(os.path.join(xcodeproj, "xcshareddata", "xcschemes", "ScreenRecPro.xcscheme"), "w") as f:
    f.write(scheme)
print(f"{len(objs)} objects; app sources {len(targets['ScreenRecPro']['sources'])}, "
      f"broadcast {len(targets['ScreenRecBroadcast']['sources'])}, widget {len(targets['ScreenRecLiveActivity']['sources'])}")
