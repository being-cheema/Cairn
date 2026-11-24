#!/usr/bin/env python3
"""Writes Cairn.xcodeproj, so the app can be opened, run and signed from Xcode.

The real build is still build.sh (it assembles the icon, search-mcp and the
developer-tools packages, and signs for release). This project is for looking
at and trying settings: Signing & Capabilities, build settings, the debugger.
Run it again after adding or removing a source file:  python3 Xcode/make_project.py
"""
import hashlib, os, re
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
def uid(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def q(s): return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'

app_files = sorted(f for f in os.listdir(f"{ROOT}/Sources/Search") if f.endswith(".swift"))
api_files = sorted(f for f in os.listdir(f"{ROOT}/Sources/SearchPluginAPI") if f.endswith(".swift"))
version = open(f"{ROOT}/VERSION").read().strip() if os.path.exists(f"{ROOT}/VERSION") else "1.0.19"
resources = [("Search.sdef", "Search.sdef"), ("search-mcp", "search-mcp")]
resources = [(n, p) for n, p in resources if os.path.exists(f"{ROOT}/{p}")]

objs = []  # (id, dict-text)
def add(i, body): objs.append((i, body))

# file references
refs = {}
def fileref(path, kind, group_name):
    i = uid("ref:" + path)
    refs[path] = i
    add(i, f'isa = PBXFileReference; lastKnownFileType = {kind}; name = {q(os.path.basename(path))}; path = {q(path)}; sourceTree = SOURCE_ROOT;')
    return i
src_app = [fileref(f"Sources/Search/{f}", "sourcecode.swift", "Search") for f in app_files]
src_api = [fileref(f"Sources/SearchPluginAPI/{f}", "sourcecode.swift", "API") for f in api_files]
res_refs = [fileref(p, "text.xml" if p.endswith(".sdef") else "text.script.sh", "Res") for _, p in resources]
plist_ref = fileref("Xcode/Info.plist", "text.plist.xml", "Cfg")
ent_ref = fileref("Search.entitlements", "text.plist.entitlements", "Cfg")
pkg_ref = fileref("Package.swift", "sourcecode.swift", "Cfg")
product_app = uid("product:app"); product_lib = uid("product:lib")
add(product_app, 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Cairn.app; sourceTree = BUILT_PRODUCTS_DIR;')
add(product_lib, 'isa = PBXFileReference; explicitFileType = archive.ar; includeInIndex = 0; path = libSearchPluginAPI.a; sourceTree = BUILT_PRODUCTS_DIR;')

def buildfiles(tag, ids):
    out = []
    for r in ids:
        b = uid(f"bf:{tag}:{r}")
        add(b, f'isa = PBXBuildFile; fileRef = {r};')
        out.append(b)
    return out
bf_app = buildfiles("app", src_app)
bf_api = buildfiles("api", src_api)
bf_res = buildfiles("res", res_refs)
lib_bf = uid("bf:link:lib"); add(lib_bf, f'isa = PBXBuildFile; fileRef = {product_lib};')

# groups
def group(name, children, path=None):
    i = uid("group:" + name)
    add(i, f'isa = PBXGroup; children = ({", ".join(children)}); name = {q(name)}; sourceTree = "<group>";')
    return i
g_app = group("Search", src_app); g_api = group("SearchPluginAPI", src_api)
g_cfg = group("Config", [plist_ref, ent_ref, pkg_ref] + res_refs)
g_prod = group("Products", [product_app, product_lib])
g_main = uid("group:main")
add(g_main, f'isa = PBXGroup; children = ({g_app}, {g_api}, {g_cfg}, {g_prod}); sourceTree = "<group>";')

# build phases
def phase(isa, tag, files):
    i = uid(f"phase:{tag}")
    add(i, f'isa = {isa}; buildActionMask = 2147483647; files = ({", ".join(files)}); runOnlyForDeploymentPostprocessing = 0;')
    return i
ph_app_src = phase("PBXSourcesBuildPhase", "app-src", bf_app)
ph_app_fw = phase("PBXFrameworksBuildPhase", "app-fw", [lib_bf])
ph_app_res = phase("PBXResourcesBuildPhase", "app-res", bf_res)
ph_api_src = phase("PBXSourcesBuildPhase", "api-src", bf_api)
ph_api_fw = phase("PBXFrameworksBuildPhase", "api-fw", [])

# configurations
def configs(tag, common, debug_extra, release_extra):
    ids = []
    for name, extra in (("Debug", debug_extra), ("Release", release_extra)):
        i = uid(f"cfg:{tag}:{name}")
        settings = {**common, **extra}
        body = "; ".join(f"{k} = {q(v) if isinstance(v, str) else v}" for k, v in settings.items())
        add(i, f'isa = XCBuildConfiguration; buildSettings = {{{body};}}; name = {name};')
        ids.append(i)
    lst = uid(f"cfglist:{tag}")
    add(lst, f'isa = XCConfigurationList; buildConfigurations = ({", ".join(ids)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
    return lst
proj_cfg = configs("project", {
    "MACOSX_DEPLOYMENT_TARGET": "14.0", "SDKROOT": "macosx", "SWIFT_VERSION": "5.0",
    "ALWAYS_SEARCH_USER_PATHS": "NO", "CLANG_ENABLE_MODULES": "YES", "ENABLE_STRICT_OBJC_MSGSEND": "YES",
}, {"SWIFT_OPTIMIZATION_LEVEL": "-Onone", "ONLY_ACTIVE_ARCH": "YES", "DEBUG_INFORMATION_FORMAT": "dwarf"},
   {"SWIFT_OPTIMIZATION_LEVEL": "-O", "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym", "SWIFT_COMPILATION_MODE": "wholemodule"})
app_cfg = configs("app", {
    "PRODUCT_NAME": "Cairn", "PRODUCT_BUNDLE_IDENTIFIER": "io.github.being-cheema.cairn",
    "INFOPLIST_FILE": "Xcode/Info.plist", "GENERATE_INFOPLIST_FILE": "NO",
    "MARKETING_VERSION": version, "CURRENT_PROJECT_VERSION": "1",
    "CODE_SIGN_ENTITLEMENTS": "Search.entitlements", "CODE_SIGN_STYLE": "Automatic",
    "DEVELOPMENT_TEAM": "8KF98RXL4J", "ENABLE_HARDENED_RUNTIME": "YES",
    "COMBINE_HIDPI_IMAGES": "YES", "LD_RUNPATH_SEARCH_PATHS": "@executable_path/../Frameworks",
    "SWIFT_VERSION": "5.0", "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
}, {}, {})
lib_cfg = configs("lib", {
    "PRODUCT_NAME": "SearchPluginAPI", "SKIP_INSTALL": "YES", "DEFINES_MODULE": "YES",
    "SWIFT_VERSION": "5.0", "CODE_SIGN_STYLE": "Automatic",
}, {}, {})

# targets
lib_t = uid("target:lib")
add(lib_t, f'isa = PBXNativeTarget; buildConfigurationList = {lib_cfg}; buildPhases = ({ph_api_src}, {ph_api_fw}); buildRules = (); dependencies = (); name = SearchPluginAPI; productName = SearchPluginAPI; productReference = {product_lib}; productType = "com.apple.product-type.library.static";')
dep_proxy = uid("proxy:lib"); dep = uid("dep:lib")
proj = uid("project")
add(dep_proxy, f'isa = PBXContainerItemProxy; containerPortal = {proj}; proxyType = 1; remoteGlobalIDString = {lib_t}; remoteInfo = SearchPluginAPI;')
add(dep, f'isa = PBXTargetDependency; target = {lib_t}; targetProxy = {dep_proxy};')
app_t = uid("target:app")
add(app_t, f'isa = PBXNativeTarget; buildConfigurationList = {app_cfg}; buildPhases = ({ph_app_src}, {ph_app_fw}, {ph_app_res}); buildRules = (); dependencies = ({dep}); name = Cairn; productName = Cairn; productReference = {product_app}; productType = "com.apple.product-type.application";')
add(proj, f'isa = PBXProject; attributes = {{BuildIndependentTargetsInParallel = 1; LastUpgradeCheck = 2600;}}; buildConfigurationList = {proj_cfg}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {g_main}; productRefGroup = {g_prod}; projectDirPath = ""; projectRoot = ""; targets = ({app_t}, {lib_t});')

out = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {", "\t};", "\tobjectVersion = 56;", "\tobjects = {"]
for i, body in objs: out.append(f"\t\t{i} = {{{body}}};")
out += ["\t};", f"\trootObject = {proj};", "}"]
os.makedirs(f"{ROOT}/Cairn.xcodeproj", exist_ok=True)
open(f"{ROOT}/Cairn.xcodeproj/project.pbxproj", "w").write("\n".join(out) + "\n")
print(f"Cairn.xcodeproj: {len(app_files)} app sources, {len(api_files)} plugin API sources")
