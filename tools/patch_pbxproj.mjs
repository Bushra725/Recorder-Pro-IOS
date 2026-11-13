import crypto from "crypto";
import fs from "fs";
import path from "path";

const ROOT = process.cwd();
const PBX = path.join(ROOT, "ScreenRecPro.xcodeproj", "project.pbxproj");
let text = fs.readFileSync(PBX, "utf8");

const oid = (...parts) =>
  crypto.createHash("md5").update(parts.join("/")).digest("hex").slice(0, 24).toUpperCase();

const files = [
  "ScreenRecPro/Analytics/AdjustTracker.swift",
  "ScreenRecPro/Analytics/RemoteConfigManager.swift",
];

const refs = Object.fromEntries(files.map((f) => [f, oid("ref", f)]));
const bfs = Object.fromEntries(files.map((f) => [f, oid("bf-src", "ScreenRecPro", f)]));

const pkgAdj = oid("pkg", "ios_sdk");
const depRC = oid("pkgdep", "ScreenRecPro", "FirebaseRemoteConfig");
const depAdj = oid("pkgdep", "ScreenRecPro", "AdjustSdk");
const bfRC = oid("bf-pkg", "ScreenRecPro", "FirebaseRemoteConfig");
const bfAdj = oid("bf-pkg", "ScreenRecPro", "AdjustSdk");
const groupAnalytics = oid("group", "ScreenRecPro/Analytics");

// --- File references
for (const f of files) {
  const name = path.basename(f);
  const block = `\t\t${refs[f]} = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ${name}; sourceTree = "<group>"; };\n`;
  if (!text.includes(refs[f])) {
    text = text.replace(
      "/* End PBXFileReference section */",
      block + "/* End PBXFileReference section */",
    );
  }
}

// --- Build files (sources)
for (const f of files) {
  const block = `\t\t${bfs[f]} = {isa = PBXBuildFile; fileRef = ${refs[f]}; };\n`;
  if (!text.includes(bfs[f])) {
    text = text.replace(
      "/* End PBXBuildFile section */",
      block + "/* End PBXBuildFile section */",
    );
  }
}

// --- Package product build files
for (const [id, dep] of [
  [bfRC, depRC],
  [bfAdj, depAdj],
]) {
  const block = `\t\t${id} = {isa = PBXBuildFile; productRef = ${dep}; };\n`;
  if (!text.includes(id)) {
    text = text.replace(
      "/* End PBXBuildFile section */",
      block + "/* End PBXBuildFile section */",
    );
  }
}

// --- Analytics group + attach to ScreenRecPro group
const analyticsGroup = `\t\t${groupAnalytics} = {isa = PBXGroup; children = (${refs[files[0]]}, ${refs[files[1]]}, ); path = Analytics; sourceTree = "<group>"; };\n`;
if (!text.includes(groupAnalytics)) {
  text = text.replace("/* End PBXGroup section */", analyticsGroup + "/* End PBXGroup section */");
}

// ScreenRecPro group children — insert Analytics group id after opening children
text = text.replace(
  /(242C64E87529E9048A1EF9B2 = \{isa = PBXGroup; children = \()/,
  `$1${groupAnalytics}, `,
);

// --- Sources build phase: append new bfs before "); runOnlyForDeploymentPostprocessing = 0; };" on main target sources
text = text.replace(
  /(38D5C74DA8AC564663DE3B3C = \{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = \()([^)]+)(\); runOnlyForDeploymentPostprocessing = 0; \};)/,
  (full, a, mid, c) => {
    if (mid.includes(bfs[files[0]])) return full;
    return `${a}${mid}${bfs[files[0]]}, ${bfs[files[1]]}, ${c}`;
  },
);

// --- Frameworks build phase
text = text.replace(
  /(2355384C0D642DA0E4BABD88 = \{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = \()([^)]+)(\); runOnlyForDeploymentPostprocessing = 0; \};)/,
  (full, a, mid, c) => {
    if (mid.includes(bfRC)) return full;
    return `${a}${mid}${bfRC}, ${bfAdj}, ${c}`;
  },
);

// --- Package references
const pkgBlock = `\t\t${pkgAdj} = {isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/adjust/ios_sdk.git"; requirement = {kind = upToNextMajorVersion; minimumVersion = 5.0.0; }; };\n`;
if (!text.includes(pkgAdj)) {
  text = text.replace(
    "/* End XCRemoteSwiftPackageReference section */",
    pkgBlock + "/* End XCRemoteSwiftPackageReference section */",
  );
}

// --- Package product deps
const depBlocks = [
  `\t\t${depRC} = {isa = XCSwiftPackageProductDependency; package = EC914B8139F53BCF6E442486; productName = FirebaseRemoteConfig; };\n`,
  `\t\t${depAdj} = {isa = XCSwiftPackageProductDependency; package = ${pkgAdj}; productName = AdjustSdk; };\n`,
];
for (const block of depBlocks) {
  const id = block.match(/^\t\t([A-F0-9]+)/)[1];
  if (!text.includes(id)) {
    text = text.replace(
      "/* End XCSwiftPackageProductDependency section */",
      block + "/* End XCSwiftPackageProductDependency section */",
    );
  }
}

// --- Native target packageProductDependencies
text = text.replace(
  /(name = ScreenRecPro; packageProductDependencies = \()([^)]+)(\);)/,
  (full, a, mid, c) => {
    if (mid.includes(depRC)) return full;
    return `${a}${mid}${depRC}, ${depAdj}, ${c}`;
  },
);

// --- Project packageReferences
text = text.replace(
  /(packageReferences = \()([^)]+)(\);)/,
  (full, a, mid, c) => {
    if (mid.includes(pkgAdj)) return full;
    return `${a}${mid}${pkgAdj}, ${c}`;
  },
);

fs.writeFileSync(PBX, text);
console.log("patched", {
  refs,
  bfs,
  pkgAdj,
  depRC,
  depAdj,
  groupAnalytics,
});
