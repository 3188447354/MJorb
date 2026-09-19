// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SideSign",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8),
        .visionOS(.v1)
    ],

    products: [
        .library(
            name: "SideSign",
            type: .static,
            targets: ["SideSign"]
        ),
        .library(
            name: "SideSign-Dynamic",
            type: .dynamic,
            targets: ["SideSign"]
        ),
        .executable(
            name: "sidesign",
            targets: ["SideSignCLI"]
        ),
    ],

    dependencies: [
        // ⚠️ **本地 vendor 化**（2026-09-19，照抄上游注释掉的那套写法 ✓）
        //
        // 上游原本用 `branch: "main"` / `branch: "master"` 拉远程 ✗ ——
        // 但 Seal 的 `AnisetteKit` 用的是**固定 revision**、`swift-crypto` 用的是 **4.5.2**
        // ⇒ 两处都会与上游声明的版本**冲突**（SwiftPM 直接报解析失败 ✗）。
        //
        // 上游自己在注释里就给了答案 ✓：
        //     //  .package(name: "CodeSignKit",  path: "../../local/CodeSignKit"),
        //     //  .package(name: "GSACryptoKit", path: "../../local/GSACryptoKit"),
        //     //  .package(name: "libdeflate",   path: "../../local/libdeflate"),
        //     //  .package(name: "AnisetteKit",   path: "../../local/AnisetteKit")
        // ⇒ Seal 把四个依赖都放进 `Vendor/`，这里改成 **path 引用** ✓。
        // 路径是**相对本 Package.swift 所在目录**（`Vendor/SideSign/`）⇒ `../<名字>` ✓。
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2"),
        .package(name: "CodeSignKit",  path: "../CodeSignKit"),
        .package(name: "GSACryptoKit", path: "../GSACryptoKit"),
        .package(name: "libdeflate",   path: "../libdeflate"),
        .package(name: "AnisetteKit",  path: "../AnisetteKit"),
    ],

    targets: [
        .target(
            name: "SideSign",
            dependencies: [
                .product(name: "libdeflate", package: "libdeflate"),
                .product(name: "Crypto", package: "swift-crypto"),
                "AnisetteKit",
                "CodeSignKit",
                "GSACryptoKit"
            ],
            path: "Sources"
        ),
        .executableTarget(
            name: "SideSignCLI",
            dependencies: [
                "SideSign",
                "CodeSignKit",
                "GSACryptoKit",
                "AnisetteKit",
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "CLI"
        ),
        .testTarget(
            name: "SideSignTests",
            dependencies: [
                "SideSign",
                "CodeSignKit",
                "GSACryptoKit"
            ],
            path: "Tests/SideSignTests"
        )
    ],

    swiftLanguageModes: [.v6],
    cLanguageStandard: .gnu11
)
