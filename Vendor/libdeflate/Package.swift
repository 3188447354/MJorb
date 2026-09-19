// swift-tools-version:5.9
//  Package.swift
//  libdeflate
//
//  Created by Magesh K on 04/09/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import PackageDescription

let package = Package(
    name: "libdeflate",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
        .tvOS(.v14),
        .watchOS(.v7),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "libdeflate",
            targets: ["libdeflate"]
        )
    ],
    targets: [
        .target(
            name: "libdeflate",
            path: ".",
            exclude: [
                "CMakeLists.txt",
                "COPYING",
                "NEWS.md",
                "README.md",
                "libdeflate-config.cmake.in",
                "libdeflate.pc.in",
                "programs",
                "scripts"
            ],
            sources: [
                "lib"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("lib"),
                .headerSearchPath("include")
            ]
        )
    ],
    cLanguageStandard: .gnu11
)
