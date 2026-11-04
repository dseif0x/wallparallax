import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var state: AppState
    let tracker: HeadTracker

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("WallParallax").font(.headline)
                Spacer()
                Toggle("", isOn: $state.enabled).toggleStyle(.switch).labelsHidden()
            }
            TrackingStatusView(tracker: tracker)

            Divider()

            Picker("Scene", selection: $state.scene) {
                ForEach(SceneKind.allCases) { Text($0.title).tag($0) }
            }

            if state.scene == .photo {
                HStack {
                    Text(state.photoURL?.lastPathComponent ?? "No photo chosen")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose Photo…", action: choosePhoto)
                }
                Text("The subject is cut out automatically and floats in front of the background.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if state.scene == .layers {
                HStack {
                    Text(state.layerURLs.isEmpty ? "No layers chosen" : "\(state.layerURLs.count) layers")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose Layers…", action: chooseLayers)
                }
                Text("Pick several images (PNGs with transparency). They are sorted by file name: first = farthest back.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            LabeledSlider(title: "Intensity", value: $state.intensity, range: 0...2)
            LabeledSlider(title: "Smoothing", value: $state.smoothing, range: 0...1)

            Toggle("Lean in to zoom", isOn: $state.depthZoom)
            Toggle("Auto-recenter over time", isOn: $state.autoRecenter)
            Toggle("Mirror horizontal tracking", isOn: $state.invertHorizontal)
            Toggle("Reverse parallax direction", isOn: $state.reverseParallax)
            LaunchAtLoginToggle()

            Divider()

            HeadPad(tracker: tracker)

            HStack {
                Button("Recenter") { tracker.recenter() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { state.photoURL = url }
    }

    private func chooseLayers() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            state.layerURLs = panel.urls.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
        }
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack {
            Text(title).frame(width: 72, alignment: .leading)
            Slider(value: $value, in: range)
        }
    }
}

private struct TrackingStatusView: View {
    @ObservedObject var tracker: HeadTracker

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption).foregroundStyle(.secondary)
            if tracker.status == .denied {
                Spacer()
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                }
                .controlSize(.small)
            }
        }
    }

    private var text: String {
        switch tracker.status {
        case .idle: "Tracking off"
        case .starting: "Starting camera…"
        case .running: tracker.faceVisible ? "Tracking your head" : "Looking for a face…"
        case .denied: "Camera access denied"
        case .noCamera: "No camera found"
        case .failed(let message): "Camera error: \(message)"
        }
    }

    private var color: Color {
        switch tracker.status {
        case .running: tracker.faceVisible ? .green : .yellow
        case .starting: .yellow
        case .idle: .gray
        default: .red
        }
    }
}

/// Live view of the tracked head position.
private struct HeadPad: View {
    @ObservedObject var tracker: HeadTracker

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                Path { p in
                    p.move(to: CGPoint(x: w / 2, y: 6)); p.addLine(to: CGPoint(x: w / 2, y: h - 6))
                    p.move(to: CGPoint(x: 6, y: h / 2)); p.addLine(to: CGPoint(x: w - 6, y: h / 2))
                }
                .stroke(.tertiary, lineWidth: 1)
                Circle()
                    .fill(tracker.faceVisible ? Color.accentColor : Color.secondary)
                    .frame(width: dot, height: dot)
                    .offset(x: tracker.pose.x * w / 3.2, y: -tracker.pose.y * h / 3.2)
            }
        }
        .frame(height: 80)
    }

    private var dot: CGFloat { max(6, min(30, 14 + tracker.pose.z * 8)) }
}

private struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle("Launch at login", isOn: Binding(
            get: { enabled },
            set: { newValue in
                do {
                    if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    NSLog("WallParallax: launch at login failed: \(error)")
                }
                enabled = SMAppService.mainApp.status == .enabled
            }
        ))
    }
}
