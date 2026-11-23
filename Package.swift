// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Planets",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Planets", targets: ["Planets"]),
        .executable(name: "planet", targets: ["planet"]),
    ],
    targets: [
        .target(name: "PlanetsCore"),
        .target(name: "PlanetsPrivate"),
        .executableTarget(
            name: "Planets",
            dependencies: ["PlanetsCore", "PlanetsPrivate"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .executableTarget(name: "planet", dependencies: ["PlanetsCore"]),
        .testTarget(name: "PlanetsCoreTests", dependencies: ["PlanetsCore"]),
        .testTarget(name: "PlanetsTests", dependencies: ["Planets", "PlanetsCore"]),
    ],
    swiftLanguageModes: [.v6]
)
