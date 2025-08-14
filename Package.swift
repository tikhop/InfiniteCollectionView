// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "InfiniteCollectionView",
    platforms: [
        .iOS("13.0"), .tvOS("13.0")
    ],
    products: [
        .library(
            name: "InfiniteCollectionView",
            targets: ["InfiniteCollectionView"]
        )
    ],
    targets: [
        .target(
            name: "InfiniteCollectionView",
            path: "Sources"
        ),
        .testTarget(
            name: "InfiniteCollectionViewTests",
            dependencies: ["InfiniteCollectionView"],
            path: "Tests"
        )
    ]
)
