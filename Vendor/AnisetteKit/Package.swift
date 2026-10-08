// swift-tools-version: 5.9
//
//  Package.swift
//  AnisetteKit
//
//  Created by Magesh K on 20/07/26.
//  Copyright © 2026 Magesh K. All rights reserved.
//

import PackageDescription

#if canImport(Darwin)
// ⚠️ 这里**故意**不用上游 `mahee96/unicorn` 的远程二进制包
//   （原来是 releases/download/2.1.4-multiarch/Unicorn.xcframework.zip）。
//   原因：上游预编译件按 iOS 26 部署目标编译，clang 因此选 `apple-a12` 目标 CPU
//   （带 FEAT_LSE），产物里有 93 条 ARMv8.1 LSE 原子指令（CAS* / LDADD* / SWP*）。
//   而 A10/A10X（iPad 第 6/7 代、iPad Pro 2017）是 Apple **唯一**对外标示 ARMv8.1-A、
//   却未实现 LSE 的芯片 ⇒ 一旦执行到 `_cpu_exec_aarch64` 里的 `casal` 就是 SIGILL 秒退。
//   实测：`2.1.4-multiarch` 与更新的 `2.1.4-xcf-a53ddc9` **两个官方包都含 LSE**，
//   换版本解决不了 ⇒ 改为使用仓库内 vendored、由 `Scripts/ensure-unicorn.sh`
//   从 pinned 源码以 `-mcpu=apple-a10` 重编的零 LSE 产物。
//   校验：`python3 Scripts/verify-no-lse.py Vendor/AnisetteKit/Unicorn.xcframework`（须 0 条）。
let unicornBinaryTargets: [Target] = [
    .binaryTarget(
        name: "Unicorn",
        path: "Unicorn.xcframework"
    )
]
let unicornCoreDependencies: [Target.Dependency] = [
    "Unicorn"
]
let unicornLinkerSettings: [LinkerSetting] = []
#else
let unicornBinaryTargets: [Target] = []
let unicornCoreDependencies: [Target.Dependency] = []
let unicornLinkerSettings: [LinkerSetting] = [
    .linkedLibrary("unicorn")
]
#endif

let package = Package(
    name: "AnisetteKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "AnisetteKit",
            targets: ["AnisetteKit"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.0"),
    ],
    targets: [
        .target(
            name: "anisette_core",
            dependencies: unicornCoreDependencies,
            path: "Native",
            cSettings: [
                .headerSearchPath(".")
            ],
            linkerSettings: unicornLinkerSettings
        ),
        .target(
            name: "AnisetteKit",
            dependencies: [
                "anisette_core",
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: ".",
            exclude: [
                "Package.swift",
                "Native", 
                "Tests",
                "README.md",
                "LICENSE",
                // 由上面的 .binaryTarget(path:) 独占，不能再被本 target 当源码/资源收集
                "Unicorn.xcframework"
            ],
            sources: ["Sources"]
        ),
        .testTarget(
            name: "AnisetteKitTests",
            dependencies: [
                "AnisetteKit"
            ],
            path: "Tests"
        )
    ] + unicornBinaryTargets,
    cxxLanguageStandard: .cxx17
)
