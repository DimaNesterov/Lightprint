import SwiftUI
import LumenCore

struct ContentView: View {
    @StateObject private var controller = LumenController()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false

    var body: some View {
        ZStack {
            ARMetalView(controller: controller)
                .ignoresSafeArea()

            if controller.lidarAvailable {
                switch controller.interface {
                case .hidden:
                    // A tap anywhere brings the interface back.
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.25)) { controller.interface = .visible }
                        }
                case .playOnly:
                    PlayOnlyLayer(controller: controller)
                        .transition(.opacity)
                case .visible:
                    VStack(spacing: 12) {
                        TopBar(controller: controller, showSettings: $showSettings)
                        Spacer()
                        BottomPanel(controller: controller)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                    .transition(.opacity)
                }
            } else {
                Text("Lumen needs an iPhone or iPad with LiDAR")
                    .font(.headline)
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { controller.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { controller.appWillResignActive() }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(controller: controller)
                .presentationDetents([.medium, .large])
        }
        .statusBarHidden()
    }
}

/// First step of hiding the interface: only the button that draws the light in. Tapping it hides that too and
/// starts the animation; tapping anywhere else just hides everything.
private struct PlayOnlyLayer: View {
    @ObservedObject var controller: LumenController

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.25)) { controller.interface = .hidden }
                }
            VStack {
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { controller.playRevealHidden() }
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .frame(width: 64, height: 64)
                            .background(.ultraThinMaterial, in: Circle())
                        Text("Draw the light")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .padding(.bottom, 24)
            }
        }
    }
}

// MARK: - Top

private struct TopBar: View {
    @ObservedObject var controller: LumenController
    @Binding var showSettings: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                RoomMenu(controller: controller)
                Spacer()
                if controller.mode == .main {
                    if !controller.isCapturing && !controller.isSaving {
                        RoundIcon(system: "eye.slash") {
                            withAnimation(.easeInOut(duration: 0.25)) { controller.interface = .playOnly }
                        }
                    }
                    if !controller.manifest.captures.isEmpty {
                        RoundIcon(system: controller.showLight ? "sparkles" : "sparkles.slash") {
                            controller.showLight.toggle()
                        }
                    }
                    RoundIcon(system: "slider.horizontal.3") { showSettings = true }
                }
            }
            let line = controller.instruction
            if !line.isEmpty {
                Text(line)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity)
            }
            if !controller.whiteBalanceLocked && controller.trackingNormal {
                Text("White balance not locked")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.top, 8)
        .animation(.easeInOut(duration: 0.2), value: controller.instruction)
    }
}

/// Room name with a menu: new room, reset, switch rooms.
private struct RoomMenu: View {
    @ObservedObject var controller: LumenController
    @State private var confirmClearMoments = false
    @State private var confirmResetRoom = false

    var body: some View {
        Menu {
            Button {
                controller.newRoom()
            } label: {
                Label("New room", systemImage: "plus")
            }
            Button(role: .destructive) {
                confirmClearMoments = true
            } label: {
                Label("Delete all moments", systemImage: "clock.arrow.circlepath")
            }
            .disabled(controller.manifest.captures.isEmpty)
            Button(role: .destructive) {
                confirmResetRoom = true
            } label: {
                Label("Reset the whole room", systemImage: "trash")
            }
            if controller.rooms.count > 1 {
                Divider()
                ForEach(controller.rooms, id: \.id) { room in
                    Button {
                        controller.open(room)
                    } label: {
                        if room.id == controller.manifest.id {
                            Label(room.name, systemImage: "checkmark")
                        } else {
                            Text(room.name)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(controller.manifest.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(controller.isCapturing || controller.isSaving)
        .confirmationDialog("Delete all moments of this room?", isPresented: $confirmClearMoments,
                            titleVisibility: .visible) {
            Button("Delete moments", role: .destructive) { controller.clearMoments() }
        } message: {
            Text("Windows and lamps stay marked.")
        }
        .confirmationDialog("Reset the whole room?", isPresented: $confirmResetRoom,
                            titleVisibility: .visible) {
            Button("Reset", role: .destructive) { controller.resetRoom() }
        } message: {
            Text("Moments, windows and lamps will be deleted.")
        }
    }
}

// MARK: - Bottom

private struct BottomPanel: View {
    @ObservedObject var controller: LumenController

    var body: some View {
        switch controller.mode {
        case .main: MainControls(controller: controller)
        case .mark: MarkControls(controller: controller)
        case .align: AlignControls(controller: controller)
        }
    }
}

private struct MainControls: View {
    @ObservedObject var controller: LumenController

    var body: some View {
        VStack(spacing: 14) {
            if controller.isAligned && controller.showLight && !controller.isCapturing && controller.splatCount > 0 {
                TimelineBar(controller: controller)
            }
            if controller.needsAlignment || controller.relocalizing {
                Button {
                    controller.beginAlignment()
                } label: {
                    Label("Align", systemImage: "scope")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .disabled(!controller.canAlign)
            }
            if controller.isCapturing {
                Text(scanLine)
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .monospacedDigit()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            HStack {
                SideButton(title: "Mark", system: "lightbulb") { controller.beginMarking() }
                    .disabled(controller.isCapturing || controller.isSaving)
                Spacer()
                CaptureButton(controller: controller)
                Spacer()
                SideButton(title: "\(controller.manifest.captures.count)", system: "clock") {}
                    .allowsHitTesting(false)
            }
        }
    }

    private var scanLine: String {
        let t = Int(controller.captureElapsed)
        return String(format: "%d:%02d · %d m²", t / 60, t % 60, Int(controller.scannedArea.rounded()))
    }
}

private struct CaptureButton: View {
    @ObservedObject var controller: LumenController

    var body: some View {
        Button {
            controller.toggleCapture()
        } label: {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.35), lineWidth: 4)
                    .frame(width: 78, height: 78)
                Circle()
                    .trim(from: 0, to: controller.isCapturing
                          ? min(controller.captureElapsed / LumenController.maxCaptureDuration, 1) : 0)
                    .stroke(Color(red: 1, green: 0.75, blue: 0.4), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 78, height: 78)
                if controller.isCapturing {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.white)
                        .frame(width: 26, height: 26)
                } else if controller.isSaving {
                    ProgressView()
                } else {
                    Circle()
                        .fill(.white)
                        .frame(width: 62, height: 62)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(controller.isSaving)
    }
}

private struct MarkControls: View {
    @ObservedObject var controller: LumenController

    var body: some View {
        VStack(spacing: 12) {
            Picker("Source", selection: $controller.tool) {
                ForEach(MarkTool.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
            Text("Windows: \(controller.windowCount) · Lamps: \(controller.lampCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if controller.sourceShining.values.contains(false) {
                Text("Grey ones are not shining in the latest moment, so they cast no rays")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack {
                SideButton(title: "Undo", system: "arrow.uturn.backward") { controller.undoMark() }
                Spacer()
                SideButton(title: "Done", system: "checkmark") { controller.endMarking() }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct AlignControls: View {
    @ObservedObject var controller: LumenController

    var body: some View {
        HStack {
            Text("Marked: \(controller.alignTaps.count) of 2")
                .font(.footnote)
            Spacer()
            SideButton(title: "Cancel", system: "xmark") { controller.cancelAlignment() }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

// MARK: - Timeline

private struct TimelineBar: View {
    @ObservedObject var controller: LumenController

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    controller.togglePlay()
                } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 28, height: 28)
                }
                .disabled(controller.captureTicks.count < 2)
                Text(controller.timelineLabel)
                    .font(.system(.title3, design: .rounded).weight(.medium))
                    .monospacedDigit()
                Spacer()
                Picker("Mode", selection: $controller.timelineMode) {
                    Text("Accumulate").tag(LumenCore.Timeline.Mode.accumulate)
                    Text("Moment").tag(LumenCore.Timeline.Mode.moment)
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
            }
            Slider(value: $controller.timelinePosition, in: 0...1, onEditingChanged: { editing in
                if editing { controller.stopPlaying() }
            })
            .tint(Color(red: 1, green: 0.8, blue: 0.55))
            GeometryReader { geo in
                ForEach(Array(controller.captureTicks.enumerated()), id: \.offset) { _, t in
                    Capsule()
                        .fill(.white.opacity(0.6))
                        .frame(width: 2, height: 7)
                        .position(x: 14 + (geo.size.width - 28) * t, y: 3.5)
                }
            }
            .frame(height: 7)
            .padding(.top, -6)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

// MARK: - Small pieces

private struct RoundIcon: View {
    let system: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct SideButton: View {
    let title: String
    let system: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: system)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .background(.ultraThinMaterial, in: Circle())
                Text(title)
                    .font(.caption2)
            }
            .frame(width: 76)
        }
        .buttonStyle(.plain)
    }
}
