#!/usr/bin/env python3
"""Generates ios/RoofTrace.xcodeproj/project.pbxproj.

A hand-maintained pbxproj is brittle; this script builds a valid one
deterministically from the on-disk source tree so the file references, build
phases, and two targets (RoofTrace app + RoofTraceTests) stay in sync. Run from
ios/.  It is committed so the project can be regenerated if a file is added.
"""
import os
import hashlib

HERE = os.path.dirname(os.path.abspath(__file__))

APP_SOURCES = [
    "RoofTrace/App/RoofTraceApp.swift",
    "RoofTrace/Config/AppConfig.swift",
    "RoofTrace/Models/CaptureSessionManifest.swift",
    "RoofTrace/Models/CaptureSessionState.swift",
    "RoofTrace/Models/MatrixSerializer.swift",
    "RoofTrace/Models/PromptLibrary.swift",
    "RoofTrace/Services/ARSessionManager.swift",
    "RoofTrace/Services/DepthMapEncoder.swift",
    "RoofTrace/Services/GPSProvider.swift",
    "RoofTrace/Services/MeshExporter.swift",
    "RoofTrace/Services/MultipartUploader.swift",
    "RoofTrace/Services/TokenValidator.swift",
    "RoofTrace/ViewModels/CaptureViewModel.swift",
    "RoofTrace/Views/CapturePromptView.swift",
    "RoofTrace/Views/SetupCheckView.swift",
    "RoofTrace/Views/TokenEntryView.swift",
    "RoofTrace/Views/UploadProgressView.swift",
]

TEST_SOURCES = [
    "RoofTraceTests/CaptureSessionStateTests.swift",
    "RoofTraceTests/DepthMapEncoderTests.swift",
    "RoofTraceTests/FixtureParseTests.swift",
    "RoofTraceTests/ManifestSerializationTests.swift",
    "RoofTraceTests/MatrixSerializerTests.swift",
    "RoofTraceTests/MultipartEncoderTests.swift",
    "RoofTraceTests/TokenValidationTests.swift",
    "RoofTraceTests/UploadRetryTests.swift",
]

# Bundled into the TEST target so FixtureParseTests / ManifestSerializationTests
# can load session.json at runtime via Bundle(for:).url(forResource:).
TEST_RESOURCES = [
    "../spec/fixtures/ios_sessions/synthetic_house/session.json",
]

DEBUG_XCCONFIG = "RoofTrace/Config/Debug.xcconfig"
RELEASE_XCCONFIG = "RoofTrace/Config/Release.xcconfig"
INFO_PLIST = "RoofTrace/Info.plist"


def oid(key: str) -> str:
    """Deterministic 24-hex-char object id from a stable key."""
    return hashlib.sha1(key.encode()).hexdigest()[:24].upper()


def main():
    lines = []
    file_refs = {}        # path -> fileRef oid
    build_files = {}      # (path, target) -> buildFile oid

    def fref(path):
        if path not in file_refs:
            file_refs[path] = oid("fref:" + path)
        return file_refs[path]

    def bfile(path, target):
        k = (path, target)
        if k not in build_files:
            build_files[k] = oid("bfile:%s:%s" % (path, target))
        return build_files[k]

    # Target / product oids
    APP_TARGET = oid("target:app")
    TEST_TARGET = oid("target:test")
    APP_PRODUCT = oid("product:app")
    TEST_PRODUCT = oid("product:test")
    PROJECT = oid("project:root")
    MAIN_GROUP = oid("group:main")
    PRODUCTS_GROUP = oid("group:products")
    APP_GROUP = oid("group:app")
    TESTS_GROUP = oid("group:tests")
    APP_SRC_PHASE = oid("phase:appsrc")
    APP_RES_PHASE = oid("phase:appres")
    APP_FRAMEWORKS_PHASE = oid("phase:appfw")
    TEST_SRC_PHASE = oid("phase:testsrc")
    TEST_RES_PHASE = oid("phase:testres")
    TEST_FRAMEWORKS_PHASE = oid("phase:testfw")
    TEST_HOST_DEP = oid("dep:testhost")
    TEST_TARGET_PROXY = oid("proxy:testhost")
    APP_BUILD_LIST = oid("buildlist:app")
    TEST_BUILD_LIST = oid("buildlist:test")
    PROJ_BUILD_LIST = oid("buildlist:proj")
    APP_DEBUG_CFG = oid("cfg:app:debug")
    APP_RELEASE_CFG = oid("cfg:app:release")
    TEST_DEBUG_CFG = oid("cfg:test:debug")
    TEST_RELEASE_CFG = oid("cfg:test:release")
    PROJ_DEBUG_CFG = oid("cfg:proj:debug")
    PROJ_RELEASE_CFG = oid("cfg:proj:release")
    DEBUG_XCCONFIG_REF = fref(DEBUG_XCCONFIG)
    RELEASE_XCCONFIG_REF = fref(RELEASE_XCCONFIG)
    INFO_PLIST_REF = fref(INFO_PLIST)

    L = lines.append
    L("// !$*UTF8*$!")
    L("{")
    L("\tarchiveVersion = 1;")
    L("\tclasses = {};")
    L("\tobjectVersion = 56;")
    L("\tobjects = {")

    # PBXBuildFile
    L("/* Begin PBXBuildFile section */")
    for p in APP_SOURCES:
        L('\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };'
          % (bfile(p, "app"), os.path.basename(p), fref(p), os.path.basename(p)))
    for p in TEST_SOURCES:
        L('\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };'
          % (bfile(p, "test"), os.path.basename(p), fref(p), os.path.basename(p)))
    for p in TEST_RESOURCES:
        L('\t\t%s /* %s in Resources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };'
          % (bfile(p, "testres"), os.path.basename(p), fref(p), os.path.basename(p)))
    L("/* End PBXBuildFile section */")

    # PBXContainerItemProxy
    L("/* Begin PBXContainerItemProxy section */")
    L("\t\t%s /* PBXContainerItemProxy */ = {" % TEST_TARGET_PROXY)
    L("\t\t\tisa = PBXContainerItemProxy;")
    L("\t\t\tcontainerPortal = %s /* Project object */;" % PROJECT)
    L("\t\t\tproxyType = 1;")
    L("\t\t\tremoteGlobalIDString = %s;" % APP_TARGET)
    L("\t\t\tremoteInfo = RoofTrace;")
    L("\t\t};")
    L("/* End PBXContainerItemProxy section */")

    # PBXFileReference
    L("/* Begin PBXFileReference section */")
    # Path is relative to the owning group. The app group has path "RoofTrace"
    # and the tests group has path "RoofTraceTests", so strip that first segment.
    def group_relative(p):
        parts = p.split("/", 1)
        return parts[1] if len(parts) == 2 else parts[0]
    for p in APP_SOURCES + TEST_SOURCES:
        L('\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "%s"; sourceTree = "<group>"; };'
          % (fref(p), os.path.basename(p), group_relative(p)))
    for p in TEST_RESOURCES:
        # Resource lives outside ios/ (spec/fixtures/...); reference it relative
        # to the project's SOURCE_ROOT (= ios/).
        L('\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = text.json; name = "%s"; path = "%s"; sourceTree = SOURCE_ROOT; };'
          % (fref(p), os.path.basename(p), os.path.basename(p), p))
    L('\t\t%s /* Debug.xcconfig */ = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = "Config/Debug.xcconfig"; sourceTree = "<group>"; };' % DEBUG_XCCONFIG_REF)
    L('\t\t%s /* Release.xcconfig */ = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = "Config/Release.xcconfig"; sourceTree = "<group>"; };' % RELEASE_XCCONFIG_REF)
    L('\t\t%s /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "Info.plist"; sourceTree = "<group>"; };' % INFO_PLIST_REF)
    L('\t\t%s /* RoofTrace.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "RoofTrace.app"; sourceTree = BUILT_PRODUCTS_DIR; };' % APP_PRODUCT)
    L('\t\t%s /* RoofTraceTests.xctest */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = "RoofTraceTests.xctest"; sourceTree = BUILT_PRODUCTS_DIR; };' % TEST_PRODUCT)
    L("/* End PBXFileReference section */")

    # PBXFrameworksBuildPhase
    L("/* Begin PBXFrameworksBuildPhase section */")
    for ph in (APP_FRAMEWORKS_PHASE, TEST_FRAMEWORKS_PHASE):
        L("\t\t%s /* Frameworks */ = {" % ph)
        L("\t\t\tisa = PBXFrameworksBuildPhase;")
        L("\t\t\tbuildActionMask = 2147483647;")
        L("\t\t\tfiles = (")
        L("\t\t\t);")
        L("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
        L("\t\t};")
    L("/* End PBXFrameworksBuildPhase section */")

    # PBXGroup
    L("/* Begin PBXGroup section */")
    # main group
    L("\t\t%s = {" % MAIN_GROUP)
    L("\t\t\tisa = PBXGroup;")
    L("\t\t\tchildren = (")
    L("\t\t\t\t%s /* RoofTrace */," % APP_GROUP)
    L("\t\t\t\t%s /* RoofTraceTests */," % TESTS_GROUP)
    L("\t\t\t\t%s /* Products */," % PRODUCTS_GROUP)
    L("\t\t\t);")
    L("\t\t\tsourceTree = \"<group>\";")
    L("\t\t};")
    # products
    L("\t\t%s /* Products */ = {" % PRODUCTS_GROUP)
    L("\t\t\tisa = PBXGroup;")
    L("\t\t\tchildren = (")
    L("\t\t\t\t%s /* RoofTrace.app */," % APP_PRODUCT)
    L("\t\t\t\t%s /* RoofTraceTests.xctest */," % TEST_PRODUCT)
    L("\t\t\t);")
    L("\t\t\tname = Products;")
    L("\t\t\tsourceTree = \"<group>\";")
    L("\t\t};")
    # app group (flat — children are the swift files + plist + xcconfigs)
    L("\t\t%s /* RoofTrace */ = {" % APP_GROUP)
    L("\t\t\tisa = PBXGroup;")
    L("\t\t\tchildren = (")
    for p in APP_SOURCES:
        L("\t\t\t\t%s /* %s */," % (fref(p), os.path.basename(p)))
    L("\t\t\t\t%s /* Debug.xcconfig */," % DEBUG_XCCONFIG_REF)
    L("\t\t\t\t%s /* Release.xcconfig */," % RELEASE_XCCONFIG_REF)
    L("\t\t\t\t%s /* Info.plist */," % INFO_PLIST_REF)
    L("\t\t\t);")
    L("\t\t\tpath = RoofTrace;")
    L("\t\t\tsourceTree = \"<group>\";")
    L("\t\t};")
    # tests group
    L("\t\t%s /* RoofTraceTests */ = {" % TESTS_GROUP)
    L("\t\t\tisa = PBXGroup;")
    L("\t\t\tchildren = (")
    for p in TEST_SOURCES:
        L("\t\t\t\t%s /* %s */," % (fref(p), os.path.basename(p)))
    for p in TEST_RESOURCES:
        L("\t\t\t\t%s /* %s */," % (fref(p), os.path.basename(p)))
    L("\t\t\t);")
    L("\t\t\tpath = RoofTraceTests;")
    L("\t\t\tsourceTree = \"<group>\";")
    L("\t\t};")
    L("/* End PBXGroup section */")

    # PBXNativeTarget
    L("/* Begin PBXNativeTarget section */")
    L("\t\t%s /* RoofTrace */ = {" % APP_TARGET)
    L("\t\t\tisa = PBXNativeTarget;")
    L("\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXNativeTarget \"RoofTrace\" */;" % APP_BUILD_LIST)
    L("\t\t\tbuildPhases = (")
    L("\t\t\t\t%s /* Sources */," % APP_SRC_PHASE)
    L("\t\t\t\t%s /* Frameworks */," % APP_FRAMEWORKS_PHASE)
    L("\t\t\t\t%s /* Resources */," % APP_RES_PHASE)
    L("\t\t\t);")
    L("\t\t\tbuildRules = ();")
    L("\t\t\tdependencies = ();")
    L("\t\t\tname = RoofTrace;")
    L("\t\t\tproductName = RoofTrace;")
    L("\t\t\tproductReference = %s /* RoofTrace.app */;" % APP_PRODUCT)
    L("\t\t\tproductType = \"com.apple.product-type.application\";")
    L("\t\t};")
    L("\t\t%s /* RoofTraceTests */ = {" % TEST_TARGET)
    L("\t\t\tisa = PBXNativeTarget;")
    L("\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXNativeTarget \"RoofTraceTests\" */;" % TEST_BUILD_LIST)
    L("\t\t\tbuildPhases = (")
    L("\t\t\t\t%s /* Sources */," % TEST_SRC_PHASE)
    L("\t\t\t\t%s /* Frameworks */," % TEST_FRAMEWORKS_PHASE)
    L("\t\t\t\t%s /* Resources */," % TEST_RES_PHASE)
    L("\t\t\t);")
    L("\t\t\tbuildRules = ();")
    L("\t\t\tdependencies = (")
    L("\t\t\t\t%s /* PBXTargetDependency */," % TEST_HOST_DEP)
    L("\t\t\t);")
    L("\t\t\tname = RoofTraceTests;")
    L("\t\t\tproductName = RoofTraceTests;")
    L("\t\t\tproductReference = %s /* RoofTraceTests.xctest */;" % TEST_PRODUCT)
    L("\t\t\tproductType = \"com.apple.product-type.bundle.unit-test\";")
    L("\t\t};")
    L("/* End PBXNativeTarget section */")

    # PBXProject
    L("/* Begin PBXProject section */")
    L("\t\t%s /* Project object */ = {" % PROJECT)
    L("\t\t\tisa = PBXProject;")
    L("\t\t\tattributes = {")
    L("\t\t\t\tLastSwiftUpdateCheck = 1600;")
    L("\t\t\t\tLastUpgradeCheck = 1600;")
    L("\t\t\t\tTargetAttributes = {")
    L("\t\t\t\t\t%s = {CreatedOnToolsVersion = 16.0;};" % APP_TARGET)
    L("\t\t\t\t\t%s = {CreatedOnToolsVersion = 16.0; TestTargetID = %s;};" % (TEST_TARGET, APP_TARGET))
    L("\t\t\t\t};")
    L("\t\t\t};")
    L("\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXProject \"RoofTrace\" */;" % PROJ_BUILD_LIST)
    L("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
    L("\t\t\tdevelopmentRegion = en;")
    L("\t\t\thasScannedForEncodings = 0;")
    L("\t\t\tknownRegions = (en, Base);")
    L("\t\t\tmainGroup = %s;" % MAIN_GROUP)
    L("\t\t\tproductRefGroup = %s /* Products */;" % PRODUCTS_GROUP)
    L("\t\t\tprojectDirPath = \"\";")
    L("\t\t\tprojectRoot = \"\";")
    L("\t\t\ttargets = (")
    L("\t\t\t\t%s /* RoofTrace */," % APP_TARGET)
    L("\t\t\t\t%s /* RoofTraceTests */," % TEST_TARGET)
    L("\t\t\t);")
    L("\t\t};")
    L("/* End PBXProject section */")

    # PBXResourcesBuildPhase
    L("/* Begin PBXResourcesBuildPhase section */")
    L("\t\t%s /* Resources */ = {" % APP_RES_PHASE)
    L("\t\t\tisa = PBXResourcesBuildPhase;")
    L("\t\t\tbuildActionMask = 2147483647;")
    L("\t\t\tfiles = ();")
    L("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    L("\t\t};")
    L("\t\t%s /* Resources */ = {" % TEST_RES_PHASE)
    L("\t\t\tisa = PBXResourcesBuildPhase;")
    L("\t\t\tbuildActionMask = 2147483647;")
    L("\t\t\tfiles = (")
    for p in TEST_RESOURCES:
        L("\t\t\t\t%s /* %s in Resources */," % (bfile(p, "testres"), os.path.basename(p)))
    L("\t\t\t);")
    L("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    L("\t\t};")
    L("/* End PBXResourcesBuildPhase section */")

    # PBXSourcesBuildPhase
    L("/* Begin PBXSourcesBuildPhase section */")
    L("\t\t%s /* Sources */ = {" % APP_SRC_PHASE)
    L("\t\t\tisa = PBXSourcesBuildPhase;")
    L("\t\t\tbuildActionMask = 2147483647;")
    L("\t\t\tfiles = (")
    for p in APP_SOURCES:
        L("\t\t\t\t%s /* %s in Sources */," % (bfile(p, "app"), os.path.basename(p)))
    L("\t\t\t);")
    L("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    L("\t\t};")
    L("\t\t%s /* Sources */ = {" % TEST_SRC_PHASE)
    L("\t\t\tisa = PBXSourcesBuildPhase;")
    L("\t\t\tbuildActionMask = 2147483647;")
    L("\t\t\tfiles = (")
    for p in TEST_SOURCES:
        L("\t\t\t\t%s /* %s in Sources */," % (bfile(p, "test"), os.path.basename(p)))
    L("\t\t\t);")
    L("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    L("\t\t};")
    L("/* End PBXSourcesBuildPhase section */")

    # PBXTargetDependency
    L("/* Begin PBXTargetDependency section */")
    L("\t\t%s /* PBXTargetDependency */ = {" % TEST_HOST_DEP)
    L("\t\t\tisa = PBXTargetDependency;")
    L("\t\t\ttarget = %s /* RoofTrace */;" % APP_TARGET)
    L("\t\t\ttargetProxy = %s /* PBXContainerItemProxy */;" % TEST_TARGET_PROXY)
    L("\t\t};")
    L("/* End PBXTargetDependency section */")

    # XCBuildConfiguration
    L("/* Begin XCBuildConfiguration section */")

    def project_cfg(oid_, name, xcconfig_ref):
        L("\t\t%s /* %s */ = {" % (oid_, name))
        L("\t\t\tisa = XCBuildConfiguration;")
        L("\t\t\tbaseConfigurationReference = %s;" % xcconfig_ref)
        L("\t\t\tbuildSettings = {")
        L("\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;")
        L("\t\t\t\tCLANG_ENABLE_MODULES = YES;")
        L("\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;")
        L("\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;")
        L("\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;")
        L("\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;")
        L("\t\t\t\tSDKROOT = iphoneos;")
        L("\t\t\t\tSWIFT_VERSION = 5.0;")
        if name == "Debug":
            L("\t\t\t\tONLY_ACTIVE_ARCH = YES;")
            L("\t\t\t\tENABLE_TESTABILITY = YES;")
            L("\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;")
            L("\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-Onone\";")
            L("\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (\"DEBUG=1\", \"$(inherited)\");")
            L("\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;")
        else:
            L("\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-O\";")
            L("\t\t\t\tDEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\";")
            L("\t\t\t\tVALIDATE_PRODUCT = YES;")
        L("\t\t\t};")
        L("\t\t\tname = %s;" % name)
        L("\t\t};")

    project_cfg(PROJ_DEBUG_CFG, "Debug", DEBUG_XCCONFIG_REF)
    project_cfg(PROJ_RELEASE_CFG, "Release", RELEASE_XCCONFIG_REF)

    def app_cfg(oid_, name):
        L("\t\t%s /* %s */ = {" % (oid_, name))
        L("\t\t\tisa = XCBuildConfiguration;")
        L("\t\t\tbuildSettings = {")
        L("\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;")
        L("\t\t\t\tCODE_SIGN_STYLE = Automatic;")
        L("\t\t\t\tCURRENT_PROJECT_VERSION = 1;")
        L("\t\t\t\tGENERATE_INFOPLIST_FILE = NO;")
        L("\t\t\t\tINFOPLIST_FILE = \"RoofTrace/Info.plist\";")
        L("\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;")
        L("\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (\"$(inherited)\", \"@executable_path/Frameworks\");")
        L("\t\t\t\tMARKETING_VERSION = 1.0.0;")
        L("\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = \"dev.biograph.rooftrace\";")
        L("\t\t\t\tPRODUCT_NAME = \"$(TARGET_NAME)\";")
        L("\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;")
        L("\t\t\t\tSWIFT_VERSION = 5.0;")
        L("\t\t\t\tTARGETED_DEVICE_FAMILY = \"1,2\";")
        L("\t\t\t};")
        L("\t\t\tname = %s;" % name)
        L("\t\t};")

    app_cfg(APP_DEBUG_CFG, "Debug")
    app_cfg(APP_RELEASE_CFG, "Release")

    def test_cfg(oid_, name):
        L("\t\t%s /* %s */ = {" % (oid_, name))
        L("\t\t\tisa = XCBuildConfiguration;")
        L("\t\t\tbuildSettings = {")
        L("\t\t\t\tBUNDLE_LOADER = \"$(TEST_HOST)\";")
        L("\t\t\t\tCODE_SIGN_STYLE = Automatic;")
        L("\t\t\t\tCURRENT_PROJECT_VERSION = 1;")
        L("\t\t\t\tGENERATE_INFOPLIST_FILE = YES;")
        L("\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;")
        L("\t\t\t\tMARKETING_VERSION = 1.0.0;")
        L("\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = \"dev.biograph.rooftrace.tests\";")
        L("\t\t\t\tPRODUCT_NAME = \"$(TARGET_NAME)\";")
        L("\t\t\t\tSWIFT_EMIT_LOC_STRINGS = NO;")
        L("\t\t\t\tSWIFT_VERSION = 5.0;")
        L("\t\t\t\tTARGETED_DEVICE_FAMILY = \"1,2\";")
        L("\t\t\t\tTEST_HOST = \"$(BUILT_PRODUCTS_DIR)/RoofTrace.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/RoofTrace\";")
        L("\t\t\t};")
        L("\t\t\tname = %s;" % name)
        L("\t\t};")

    test_cfg(TEST_DEBUG_CFG, "Debug")
    test_cfg(TEST_RELEASE_CFG, "Release")
    L("/* End XCBuildConfiguration section */")

    # XCConfigurationList
    L("/* Begin XCConfigurationList section */")

    def cfg_list(oid_, label, debug, release):
        L("\t\t%s /* %s */ = {" % (oid_, label))
        L("\t\t\tisa = XCConfigurationList;")
        L("\t\t\tbuildConfigurations = (")
        L("\t\t\t\t%s /* Debug */," % debug)
        L("\t\t\t\t%s /* Release */," % release)
        L("\t\t\t);")
        L("\t\t\tdefaultConfigurationIsVisible = 0;")
        L("\t\t\tdefaultConfigurationName = Release;")
        L("\t\t};")

    cfg_list(PROJ_BUILD_LIST, "Build configuration list for PBXProject \"RoofTrace\"", PROJ_DEBUG_CFG, PROJ_RELEASE_CFG)
    cfg_list(APP_BUILD_LIST, "Build configuration list for PBXNativeTarget \"RoofTrace\"", APP_DEBUG_CFG, APP_RELEASE_CFG)
    cfg_list(TEST_BUILD_LIST, "Build configuration list for PBXNativeTarget \"RoofTraceTests\"", TEST_DEBUG_CFG, TEST_RELEASE_CFG)
    L("/* End XCConfigurationList section */")

    L("\t};")
    L("\trootObject = %s /* Project object */;" % PROJECT)
    L("}")

    out_dir = os.path.join(HERE, "RoofTrace.xcodeproj")
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "project.pbxproj"), "w") as f:
        f.write("\n".join(lines) + "\n")

    # Shared scheme so `xcodebuild -scheme RoofTrace` resolves on CI.
    scheme_dir = os.path.join(out_dir, "xcshareddata", "xcschemes")
    os.makedirs(scheme_dir, exist_ok=True)
    scheme = SCHEME_TEMPLATE.format(app_target=APP_TARGET, test_target=TEST_TARGET)
    with open(os.path.join(scheme_dir, "RoofTrace.xcscheme"), "w") as f:
        f.write(scheme)

    print("wrote", os.path.join(out_dir, "project.pbxproj"))
    print("wrote", os.path.join(scheme_dir, "RoofTrace.xcscheme"))


SCHEME_TEMPLATE = '''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.7">
   <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            <BuildableReference
               BuildableIdentifier="primary"
               BlueprintIdentifier="{app_target}"
               BuildableName="RoofTrace.app"
               BlueprintName="RoofTrace"
               ReferencedContainer="container:RoofTrace.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
      <Testables>
         <TestableReference skipped="NO">
            <BuildableReference
               BuildableIdentifier="primary"
               BlueprintIdentifier="{test_target}"
               BuildableName="RoofTraceTests.xctest"
               BlueprintName="RoofTraceTests"
               ReferencedContainer="container:RoofTrace.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">
         <BuildableReference
            BuildableIdentifier="primary"
            BlueprintIdentifier="{app_target}"
            BuildableName="RoofTrace.app"
            BlueprintName="RoofTrace"
            ReferencedContainer="container:RoofTrace.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">
   </ProfileAction>
   <AnalyzeAction buildConfiguration="Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES">
   </ArchiveAction>
</Scheme>
'''

if __name__ == "__main__":
    main()
