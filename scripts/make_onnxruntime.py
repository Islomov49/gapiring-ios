#!/usr/bin/env python3
"""Builds Frameworks/onnxruntime.xcframework from Microsoft's signed NuGet package Microsoft.ML.OnnxRuntime.

Why NuGet: the Swift package (github.com/microsoft/onnxruntime-swift-package-manager) and the CocoaPods archives
(download.onnxruntime.ai) could not be reached when this package was built, and mirrors of them are third parties.
The NuGet package carries the same iOS xcframework and a macOS (arm64) library, signed by Microsoft Corporation.

What it checks before using a byte of it:
  1. SHA-512 of the .nupkg equals the packageHash in nuget.org's catalog;
  2. the author signature (.signature.p7s) verifies against the system roots at the publish time, its signer is
     Microsoft Corporation, and the hash it signs equals the package's own (the zip without the signature entry);
  3. the macOS library carries Microsoft's Developer ID signature (team UBF8T346G9) before it is re-signed.

Slices: ios-arm64 and ios-arm64-simulator (static, as Microsoft ships them; the simulator thinned to arm64) and
macos-arm64 (the dylib wrapped as a dynamic framework, install name changed, so re-signed ad hoc).

Writes Frameworks/onnxruntime.xcframework (the path form of the binary target) and dist/onnxruntime.xcframework.zip
with its checksum (the url form).

usage: python3 scripts/make_onnxruntime.py [version]      (needs curl, openssl 3, xcodebuild, codesign, ditto)
"""
import base64
import gzip
import hashlib
import json
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path

VERSION = sys.argv[1] if len(sys.argv) > 1 else "1.30.0"
ID = "microsoft.ml.onnxruntime"
ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".build" / "onnxruntime-nuget" / VERSION
OUT = ROOT / "Frameworks"
DIST = ROOT / "dist"   # the zip for the url form of the binary target; not in git
MS_TEAM = "UBF8T346G9"


def run(*cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw).stdout


def fetch(url, dest=None):
    if dest:
        run("curl", "-sSfL", "--compressed", "-o", str(dest), url)
        return None
    return subprocess.run(["curl", "-sSfL", "--compressed", url], check=True, capture_output=True).stdout


def openssl():
    for o in ("/opt/homebrew/bin/openssl", "/usr/local/bin/openssl", "openssl"):
        try:
            if run(o, "version").startswith("OpenSSL 3"):
                return o
        except (OSError, subprocess.CalledProcessError):
            pass
    sys.exit("needs OpenSSL 3 (brew install openssl@3): LibreSSL cannot verify the signature")


def signed_hash(path):
    """SHA-256 (base64) of a signed .nupkg as its signature covers it: without the .signature.p7s entry."""
    data = Path(path).read_bytes()
    sig = zipfile.ZipFile(path).getinfo(".signature.p7s")
    e = data.rfind(b"PK\x05\x06")
    _, disk, cd_disk, n_disk, n_total, cd_size, cd_off, clen = struct.unpack("<IHHHHIIH", data[e:e + 22])
    records, p = [], cd_off
    while p < cd_off + cd_size:
        fn, ex, cm = struct.unpack("<HHH", data[p + 28:p + 34])
        end = p + 46 + fn + ex + cm
        records.append((data[p + 46:p + 46 + fn].decode(), data[p:end]))
        p = end
    if records[-1][0] != ".signature.p7s":
        sys.exit("unexpected layout: the signature is not the last entry")
    kept = b"".join(r for n, r in records[:-1])
    h = hashlib.sha256(data[:sig.header_offset] + kept)
    h.update(struct.pack("<IHHHHIIH", 0x06054B50, disk, cd_disk, n_disk - 1, n_total - 1, len(kept), sig.header_offset, clen))
    h.update(data[e + 22:e + 22 + clen])
    return base64.b64encode(h.digest()).decode()


def verify(nupkg):
    leaf = json.loads(fetch(f"https://api.nuget.org/v3/registration5-gz-semver2/{ID}/{VERSION}.json"))
    entry = json.loads(fetch(leaf["catalogEntry"]))
    want = entry["packageHash"]
    got = base64.b64encode(hashlib.sha512(Path(nupkg).read_bytes()).digest()).decode()
    if entry["packageHashAlgorithm"] != "SHA512" or got != want:
        sys.exit(f"SHA-512 differs from nuget.org's catalog: {got} != {want}")
    print(f"  sha512 = catalog ({entry['published']})")

    o = openssl()
    with tempfile.TemporaryDirectory() as t:
        p7s = Path(t, "sig.p7s")
        p7s.write_bytes(zipfile.ZipFile(nupkg).read(".signature.p7s"))
        roots = Path(t, "roots.pem")
        roots.write_text(run("security", "find-certificate", "-a", "-p",
                             "/System/Library/Keychains/SystemRootCertificates.keychain"))
        when = datetime.fromisoformat(entry["published"].replace("Z", "+00:00")).astimezone(timezone.utc)
        content = Path(t, "content.txt")
        run(o, "cms", "-verify", "-inform", "DER", "-in", str(p7s), "-CAfile", str(roots), "-purpose", "any",
            "-attime", str(int(when.timestamp())), "-out", str(content))
        signer = run(o, "cms", "-cmsout", "-print", "-inform", "DER", "-in", str(p7s))
        if "O=Microsoft Corporation, CN=Microsoft Corporation" not in signer:
            sys.exit("the author signature is not Microsoft Corporation's")
        line = [l for l in content.read_text().splitlines() if l.startswith("2.16.840.1.101.3.4.2.1-Hash:")]
        if not line or line[0].split(":", 1)[1] != signed_hash(nupkg):
            sys.exit("the signed hash differs from the package")
    print("  author signature: Microsoft Corporation, covers the package")


def macos_framework(dylib, headers, dest):
    """The arm64 dylib as a versioned macOS framework, onnxruntime.framework."""
    sig = subprocess.run(["codesign", "-dvv", str(dylib)], capture_output=True, text=True).stderr
    if f"TeamIdentifier={MS_TEAM}" not in sig or "Developer ID Application: Microsoft Corporation" not in sig:
        sys.exit("libonnxruntime.dylib is not signed by Microsoft")
    print("  macOS library: Developer ID Application: Microsoft Corporation")
    fw = dest / "onnxruntime.framework"
    a = fw / "Versions" / "A"
    (a / "Resources").mkdir(parents=True)
    shutil.copy2(dylib, a / "onnxruntime")
    shutil.copytree(headers, a / "Headers")
    with open(a / "Resources" / "Info.plist", "wb") as f:
        plistlib.dump({"CFBundleExecutable": "onnxruntime", "CFBundleIdentifier": "com.microsoft.onnxruntime",
                       "CFBundleName": "onnxruntime", "CFBundlePackageType": "FMWK",
                       "CFBundleShortVersionString": VERSION, "CFBundleVersion": VERSION,
                       "LSMinimumSystemVersion": "14.0"}, f)
    os.symlink("A", fw / "Versions" / "Current")
    for n in ("onnxruntime", "Headers", "Resources"):
        os.symlink(f"Versions/Current/{n}", fw / n)
    run("install_name_tool", "-id", "@rpath/onnxruntime.framework/Versions/A/onnxruntime", str(a / "onnxruntime"))
    run("codesign", "--force", "--sign", "-", str(a / "onnxruntime"))
    return fw


def main():
    CACHE.mkdir(parents=True, exist_ok=True)
    nupkg = CACHE / f"{ID}.{VERSION}.nupkg"
    if not nupkg.exists():
        print(f"downloading {ID} {VERSION} from nuget.org")
        fetch(f"https://api.nuget.org/v3-flatcontainer/{ID}/{VERSION}/{ID}.{VERSION}.nupkg", nupkg)
    print("verifying")
    verify(nupkg)

    work = CACHE / "x"
    shutil.rmtree(work, ignore_errors=True)
    with zipfile.ZipFile(nupkg) as z:
        z.extract("runtimes/ios/native/onnxruntime.xcframework.zip", work)
        z.extract("runtimes/osx-arm64/native/libonnxruntime.dylib", work)
        z.extract("LICENSE", work)
        z.extract("ThirdPartyNotices.txt", work)
    run("ditto", "-x", "-k", str(work / "runtimes/ios/native/onnxruntime.xcframework.zip"), str(work / "ios-ditto"))
    ios = work / "ios-ditto" / "onnxruntime.xcframework"   # ditto keeps the symlinks of the catalyst framework

    # The platforms the package declares, Apple silicon only: each binary stays under 50 MB, so the xcframework can
    # live in a plain git repository. Mac Catalyst and the x86_64 simulator are left out.
    slices = [ios / "ios-arm64", ios / "ios-arm64_x86_64-simulator"]
    sim = slices[1] / "onnxruntime.framework" / "onnxruntime"
    run("lipo", str(sim), "-thin", "arm64", "-output", str(sim))
    mac = macos_framework(work / "runtimes/osx-arm64/native/libonnxruntime.dylib",
                          slices[0] / "onnxruntime.framework" / "Headers", work / "macos")

    target = OUT / "onnxruntime.xcframework"
    shutil.rmtree(target, ignore_errors=True)
    OUT.mkdir(exist_ok=True)
    args = ["xcodebuild", "-create-xcframework"]
    for s in slices:
        args += ["-framework", str(s / "onnxruntime.framework")]
    args += ["-framework", str(mac), "-output", str(target)]
    run(*args)
    shutil.copy2(work / "LICENSE", OUT / "onnxruntime-LICENSE.txt")
    shutil.copy2(work / "ThirdPartyNotices.txt", OUT / "onnxruntime-ThirdPartyNotices.txt")
    shutil.rmtree(work, ignore_errors=True)
    print(f"wrote {target.relative_to(ROOT)}: " + ", ".join(sorted(p.name for p in target.iterdir() if p.is_dir())))

    # The zip for the published form of Package.swift (binaryTarget with url + checksum). ditto keeps the macOS
    # framework's symlinks. Every run makes a new zip with a new checksum: upload exactly this file.
    DIST.mkdir(exist_ok=True)
    zipped = DIST / "onnxruntime.xcframework.zip"
    zipped.unlink(missing_ok=True)
    run("ditto", "-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--keepParent", str(target), str(zipped))
    checksum = hashlib.sha256(zipped.read_bytes()).hexdigest()   # what `swift package compute-checksum` prints
    print(f"wrote {zipped.relative_to(ROOT)}: {zipped.stat().st_size / 1048576:.1f} MB, checksum {checksum}")
    print("for Package.swift, once the zip is uploaded:\n"
          f'    let onnxruntime: Target = .binaryTarget(name: "onnxruntime", url: "<URL of the zip>", checksum: "{checksum}")')


if __name__ == "__main__":
    main()
