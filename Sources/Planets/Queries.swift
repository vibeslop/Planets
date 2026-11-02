import AppKit
import PlanetsCore

/// Answers `planet query …`: plain text for people, JSON for scripts.
@MainActor
enum Queries {
    static func run(_ query: Command.Query, json: Bool, controller: AppController) -> String {
        let wm = controller.wm
        let world = wm.world
        switch query {
        case .windows:
            let windows = world.windows.values.sorted { ($0.workspace, $0.id) < ($1.workspace, $1.id) }
            // Full-screen windows are on Spaces of their own, outside the layout, but each
            // still belongs to a workspace.
            let fullScreen = wm.fullScreenWindows.sorted { ($0.value.workspace, $0.key) < ($1.value.workspace, $1.key) }
            // So are minimised windows and the windows of hidden apps.
            let away = wm.awayWindows.sorted { ($0.value.workspace, $0.key) < ($1.value.workspace, $1.key) }
            if json {
                return encode(windows.map { window in
                    [
                        "id": window.id, "app": window.appName, "bundle-id": window.bundleID ?? "", "pid": window.pid,
                        "title": window.title, "workspace": window.workspace, "floating": window.isFloating,
                        "focused": window.id == world.focusedWindow, "hidden": wm.isParked(window.id),
                        "frame": frameDict(window.frame), "full-screen": false, "minimized": false, "app-hidden": false,
                    ] as [String: Any]
                } + fullScreen.map { id, window in
                    [
                        "id": id, "app": window.appName, "pid": window.pid, "title": window.title, "workspace": window.workspace,
                        "floating": false, "focused": false, "hidden": false, "frame": frameDict(.zero), "full-screen": true,
                        "minimized": false, "app-hidden": false,
                    ] as [String: Any]
                } + away.map { id, window in
                    [
                        "id": id, "app": window.appName, "pid": window.pid, "title": window.title, "workspace": window.workspace,
                        "floating": false, "focused": false, "hidden": false, "frame": frameDict(.zero), "full-screen": false,
                        "minimized": window.reason == .minimized, "app-hidden": window.reason == .hidden,
                    ] as [String: Any]
                })
            }
            return table(["ID", "WS", "APP", "TITLE"], windows.map { window in
                let mark = window.id == world.focusedWindow ? "*" : ""
                return ["\(window.id)\(mark)", window.workspace + (window.isFloating ? " (float)" : ""), window.appName, String(window.title.prefix(48))]
            } + fullScreen.map { id, window in
                ["\(id)", window.workspace + " (full screen)", window.appName, String(window.title.prefix(48))]
            } + away.map { id, window in
                ["\(id)", window.workspace + (window.reason == .minimized ? " (minimised)" : " (hidden)"), window.appName, String(window.title.prefix(48))]
            })
        case .workspaces:
            let rows = world.workspaceOrder.map { name -> [String: Any] in
                let workspace = world.workspaces[name]
                return [
                    "name": name, "windows": workspace?.windows.count ?? 0,
                    "visible": world.isVisible(name), "focused": name == world.focusedWorkspaceName,
                    "monitor": world.monitorShowing(name).flatMap { world.monitor($0)?.name } ?? "",
                ]
            }
            if json { return encode(rows) }
            return table(["NAME", "WINDOWS", "MONITOR"], rows.map { row in
                let mark = (row["focused"] as? Bool) == true ? "*" : ""
                return ["\(row["name"]!)\(mark)", "\(row["windows"]!)", "\(row["monitor"]!)"]
            })
        case .monitors:
            let rows = world.monitors.map { monitor -> [String: Any] in
                ["id": monitor.id, "name": monitor.name, "workspace": world.visible[monitor.id] ?? "", "main": monitor.isMain,
                 "focused": monitor.id == world.focusedMonitor, "frame": frameDict(monitor.frame), "visible-frame": frameDict(monitor.visibleFrame)]
            }
            if json { return encode(rows) }
            return table(["ID", "NAME", "WORKSPACE", "FRAME"], world.monitors.map { monitor in
                ["\(monitor.id)\(monitor.id == world.focusedMonitor ? "*" : "")", monitor.name, world.visible[monitor.id] ?? "", describe(monitor.frame)]
            })
        case .focused:
            guard let id = world.focusedWindow, let window = world.windows[id] else {
                return json ? "{}" : "workspace \(world.focusedWorkspaceName ?? "-"), no window"
            }
            if json {
                return encode(["id": id, "app": window.appName, "title": window.title, "workspace": window.workspace, "floating": window.isFloating, "frame": frameDict(window.frame)] as [String: Any])
            }
            return "\(window.appName) — \(window.title) [\(id)] on workspace \(window.workspace)"
        case .apps:
            let counts = Dictionary(grouping: world.windows.values, by: \.pid).mapValues(\.count)
            let rows = counts.keys.sorted().map { pid in [wm.appName(for: pid) ?? "\(pid)", "\(pid)", "\(counts[pid]!)"] }
            if json { return encode(rows.map { ["app": $0[0], "pid": Int($0[1]) ?? 0, "windows": Int($0[2]) ?? 0] as [String: Any] }) }
            return table(["APP", "PID", "WINDOWS"], rows) + "\n\(wm.observedAppCount) apps observed"
        case .performance:
            let log = wm.performance
            let labels = Array(Set(log.entries.map(\.label))).sorted()
            let memory = footprintMB()
            if json {
                return encode(["memory-mb": memory, "passes": labels.map { label in
                    ["label": label, "count": log.entries.filter { $0.label == label }.count,
                     "p50-ms": log.percentile(0.5, label: label) ?? 0, "p95-ms": log.percentile(0.95, label: label) ?? 0] as [String: Any]
                }] as [String: Any])
            }
            let footer = String(format: "\nMemory: %.1f MB", memory)
            guard !labels.isEmpty else { return "No layout passes recorded yet." + footer }
            let rows = labels.map { label -> [String] in
                let count = log.entries.filter { $0.label == label }.count
                return [label, "\(count)", String(format: "%.2f", log.percentile(0.5, label: label) ?? 0), String(format: "%.2f", log.percentile(0.95, label: label) ?? 0)]
            }
            return table(["PASS", "COUNT", "P50 MS", "P95 MS"], rows) + "\nTimed from the decision until the slowest app finished moving its windows." + footer
        }
    }

    static func frameDict(_ rect: CGRect) -> [String: Double] {
        ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
    }

    static func describe(_ rect: CGRect) -> String {
        "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height))"
    }

    static func encode(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    static func table(_ header: [String], _ rows: [[String]]) -> String {
        let all = [header] + rows
        let widths = header.indices.map { column in all.map { $0[column].count }.max() ?? 0 }
        return all.map { row in
            row.enumerated().map { index, cell in
                index == row.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }

    /// The process's own memory, as Activity Monitor counts it.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}
