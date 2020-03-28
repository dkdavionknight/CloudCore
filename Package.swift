// swift-tools-version:5.0
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription

let package = Package(
    name: "CloudCore",
    platforms: [
       .iOS(.v11)
    ],
    products: [
        .library(
            name: "CloudCore",
            targets: ["CloudCore"])
    ],
    targets: [
        .target(
            name: "CloudCore",
            dependencies: [],
            path: "Source")
    ]
)
