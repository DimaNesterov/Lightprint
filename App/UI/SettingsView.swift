import SwiftUI
import LumenCore

struct SettingsView: View {
    @ObservedObject var controller: LumenController
    @Environment(\.dismiss) private var dismiss
    @State private var law = LightLaw()

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "d MMM, HH:mm"
        return f
    }()

    private var sortedCaptures: [CaptureInfo] {
        controller.manifest.captures.sorted { LumenController.timeOfDay($0.date) < LumenController.timeOfDay($1.date) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SliderRow(title: "Room brightness", value: $controller.render.cameraDim, range: 0...1) {
                        "\(Int(($0 * 100).rounded())) %"
                    }
                    SliderRow(title: "Splat size (σ)", value: $controller.render.sigma, range: 0.002...0.02) {
                        String(format: "%.1f mm", $0 * 1000)
                    }
                    SliderRow(title: "Splat opacity", value: $controller.render.opacity, range: 0.02...0.5) {
                        String(format: "%.2f", $0)
                    }
                    SliderRow(title: "Light exposure", value: $controller.render.exposure, range: 0.2...4) {
                        String(format: "%.1f", $0)
                    }
                    Toggle("Hide light behind objects (LiDAR)", isOn: $controller.render.occlusion)
                    Toggle("Show windows and lamps", isOn: $controller.render.showMarkers)
                } header: {
                    Text("Look")
                } footer: {
                    Text("All splats are identical: size and opacity are shared by every splat.")
                }

                Section {
                    SliderRow(title: "Splats for the whole room", value: budget, range: 20...200, onCommit: commitLaw) {
                        "\(Int($0.rounded()))k"
                    }
                    SliderRow(title: "Direct light threshold", value: $law.litThreshold, range: 1.1...4, onCommit: commitLaw) {
                        String(format: "×%.1f median", $0)
                    }
                    SliderRow(title: "Source threshold", value: $law.sourceThreshold, range: 1.5...20, onCommit: commitLaw) {
                        String(format: "×%.1f median", $0)
                    }
                    SliderRow(title: "Rays", value: $law.beamGain, range: 0...3, onCommit: commitLaw) {
                        String(format: "%.1f", $0)
                    }
                    SliderRow(title: "Ambient light", value: $law.ambientGain, range: 0...2, onCommit: commitLaw) {
                        String(format: "%.2f", $0)
                    }
                    SliderRow(title: "Angle between rays", value: $law.rayAngleDegrees, range: 2...15, onCommit: commitLaw) {
                        String(format: "%.0f°", $0)
                    }
                    SliderRow(title: "Ray width", value: $law.rayWidth, range: 0.05...1, onCommit: commitLaw) {
                        String(format: "%.2f", $0)
                    }
                    SliderRow(title: "Ray spacing in windows", value: $law.windowRaySpacing, range: 0.04...0.4, onCommit: commitLaw) {
                        "\(Int(($0 * 100).rounded())) cm"
                    }
                    SliderRow(title: "Colour range", value: $law.spanMired, range: 30...200, onCommit: commitLaw) {
                        "±\(Int($0.rounded())) mired"
                    }
                } header: {
                    Text("Light law")
                } footer: {
                    Text("One splat is one quantum of light. Rays come only from windows and lamps that are themselves brighter than the room by the source threshold at that moment. Rays widen like the light they carry: from a lamp they spread and dissolve, sunlight stays parallel.")
                }

                Section("Moments") {
                    if sortedCaptures.isEmpty {
                        Text("None yet").foregroundStyle(.secondary)
                    }
                    ForEach(sortedCaptures) { c in
                        HStack {
                            Text(Self.dateFormat.string(from: c.date))
                            Spacer()
                            Text("\(c.voxelCount) cells").foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { sortedCaptures[$0].id }
                        for id in ids { controller.deleteCapture(id) }
                    }
                }

                Section("Rooms") {
                    ForEach(controller.rooms, id: \.id) { room in
                        Button {
                            controller.open(room)
                            dismiss()
                        } label: {
                            HStack {
                                Text(room.name)
                                Spacer()
                                if room.id == controller.manifest.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { controller.rooms[$0].id }
                        for id in ids { controller.deleteRoom(id) }
                    }
                    Button("New room") {
                        controller.newRoom()
                        dismiss()
                    }
                }

                Section {
                    Button("Align manually") {
                        dismiss()
                        controller.beginAlignment()
                    }
                    .disabled(!controller.canAlign)
                    LabeledContent("Splats now", value: "\(controller.splatCount)")
                    LabeledContent("White balance",
                                   value: controller.whiteBalanceLocked ? "locked, 5000 K" : "not locked")
                } footer: {
                    Text("Data is in Files → On My iPhone → Lumen.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { law = controller.manifest.law }
        }
    }

    private var budget: Binding<Float> {
        Binding(get: { Float(law.splatBudget) / 1000 },
                set: { law.splatBudget = Int($0.rounded()) * 1000 })
    }

    private func commitLaw() {
        controller.setLaw(law)
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var onCommit: (() -> Void)?
    let label: (Float) -> String

    init(title: String, value: Binding<Float>, range: ClosedRange<Float>, onCommit: (() -> Void)? = nil,
         label: @escaping (Float) -> String) {
        self.title = title
        _value = value
        self.range = range
        self.onCommit = onCommit
        self.label = label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(label(value))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range, onEditingChanged: { editing in
                if !editing { onCommit?() }
            })
        }
    }
}
