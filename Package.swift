// swift-tools-version:5.9
// Gapiring for iOS and macOS: the Swift runtime with the Edge model inside the package (Sources/Gapiring/Model).
import PackageDescription

// Microsoft's ONNX Runtime 1.30.0 from the signed NuGet package, made and checked by scripts/make_onnxruntime.py: apps
// download it from the 0.1.2 release. GAPIRING_LOCAL_ONNXRUNTIME=1 builds against the copy the script writes to
// Frameworks/ instead, for work on the package itself.
let onnxruntime: Target = Context.environment["GAPIRING_LOCAL_ONNXRUNTIME"] == "1"
    ? .binaryTarget(name: "onnxruntime", path: "Frameworks/onnxruntime.xcframework")
    : .binaryTarget(name: "onnxruntime",
                    url: "https://github.com/Islomov49/gapiring-ios/releases/download/0.1.2/onnxruntime.xcframework.zip",
                    checksum: "5c18a8ac31af0c01c24dcd9664753052c25bdcaa4c812d747e84f0f074958dc1")

let package = Package(
    name: "Gapiring",
    // iOS 15.1: the floor of ONNX Runtime 1.30's iOS build. macOS: Apple silicon (the macOS library is arm64).
    platforms: [.iOS("15.1"), .macOS(.v14)],
    products: [.library(name: "Gapiring", targets: ["Gapiring"])],
    targets: [
        onnxruntime,
        // ORTEnv, ORTSession, ORTValue: the Objective-C API over the C++ one (module OnnxRuntimeBindings).
        .target(
            name: "OnnxRuntimeBindings",
            dependencies: ["onnxruntime"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Foundation"),
                .linkedFramework("CoreML", .when(platforms: [.iOS, .macCatalyst])),
            ]
        ),
        .target(name: "Gapiring", dependencies: ["OnnxRuntimeBindings"], resources: [.copy("Model")]),
        .testTarget(name: "GapiringTests", dependencies: ["Gapiring"], resources: [.copy("Reference")]),
    ],
    cxxLanguageStandard: .cxx17
)
