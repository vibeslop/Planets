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
        // Pure window-management logic: the dwindle tree, workspaces, commands, config.
        // No AppKit and no Accessibility calls, so all of it runs under `swift test`.
        .target(name: "PlanetsCore"),
        // The few private macOS calls a window manager can't do without, kept in C so
        // their signatures are declared exactly once.
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
        // The app's parts that run without windows or permissions: the config file and the
        // lock that keeps Planets one process.
        .testTarget(name: "PlanetsTests", dependencies: ["Planets", "PlanetsCore"]),
    ],
    swiftLanguageModes: [.v6]
)
