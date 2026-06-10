#if RENDER_SHOTS
    import AppKit
    import CoreAudio
    import SwiftUI

    /// Off-screen screenshot renderer. Launched with `--render-shots`, the app
    /// seeds a HAL-free engine with demo data for each scene, renders the popover
    /// through ImageRenderer in light and dark, writes PNGs into the sandbox
    /// container's tmp, and exits — no menu bar, no Core Audio, no manual capture.
    /// The five scenes mirror the product's headline states: idle, drag-to-pair,
    /// paired multi-output, per-app routing, and the microphone tab.
    @MainActor
    enum RenderHarness {
        private static let flag = "--render-shots"

        static var isActive: Bool {
            CommandLine.arguments.contains(flag)
        }

        /// One shared updater across all passes — its only role here is to feed
        /// MixerView's environment; scheduled checks never fire in render mode.
        private static let updater = UpdateController()

        /// App Sandbox confines writes to the container; the wrapper script
        /// (scripts/render-shots.sh) copies the PNGs out into assets/screenshots/.
        private static var outputDirectory: URL {
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        }

        private static func note(_ s: String) {
            FileHandle.standardError.write(Data("[render] \(s)\n".utf8))
        }

        // MARK: - Scenes

        private struct Scene {
            let id: String
            let direction: AudioDirection
            let pairTargeted: Bool
            let make: @MainActor () -> MixerEngine
            var forcedHoverBT: String?
        }

        /// Id of a disconnected Bluetooth row to paint in its hover state
        /// (highlight + "Connect"), since ImageRenderer never fires onHover.
        static var forcedHoverBluetoothID: String?

        private static let scenes: [Scene] = [
            Scene(id: "01-idle", direction: .output, pairTargeted: false, make: idleEngine),
            Scene(id: "02-drag-to-pair", direction: .output, pairTargeted: true, make: dragEngine),
            Scene(id: "03-paired", direction: .output, pairTargeted: false, make: pairedEngine),
            Scene(id: "04-routing", direction: .output, pairTargeted: false, make: routingEngine),
            Scene(id: "05-microphone", direction: .input, pairTargeted: false, make: microphoneEngine),
            Scene(id: "06-bluetooth", direction: .output, pairTargeted: false, make: bluetoothEngine,
                  forcedHoverBT: "12-34-56-78-9A-BC"),
        ]

        static func runAndExit() {
            let dir = outputDirectory
            note("runAndExit start, dir=\(dir.path)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for scene in scenes {
                for (appearance, scheme, suffix) in [
                    (NSAppearance.Name.aqua, ColorScheme.light, "light"),
                    (NSAppearance.Name.darkAqua, ColorScheme.dark, "dark"),
                ] {
                    renderPass(scene, appearance: appearance, scheme: scheme,
                               to: dir.appendingPathComponent("\(scene.id)-\(suffix).png"))
                }
            }
            exit(0)
        }

        /// Both AppKit (NSApp.appearance, for `Color(nsColor:)` dynamic colors)
        /// and SwiftUI (colorScheme env, for semantic styles) must be pinned, or
        /// one of the two color systems renders the wrong appearance.
        private static func renderPass(_ scene: Scene, appearance: NSAppearance.Name,
                                       scheme: ColorScheme, to url: URL) {
            NSApp.appearance = NSAppearance(named: appearance)
            forcedHoverBluetoothID = scene.forcedHoverBT
            let corner = RoundedRectangle(cornerRadius: 10, style: .continuous)
            // The popover's translucent vibrancy is a system effect, not in the
            // view tree — keep the app's own code colors and back them with the
            // semantic window background rather than chasing sampled pixels.
            let popover = MixerView(initialDirection: scene.direction, pairTargeted: scene.pairTargeted)
                .environment(scene.make())
                .environment(updater)
            // A static frame can't capture a live drag, so the pair scene paints
            // the lifted device row hovering the highlighted zone — the gesture
            // the drop hint is responding to.
            let staged = scene.pairTargeted
                ? AnyView(popover.overlay(alignment: .top) { dragPreview })
                : AnyView(popover)
            let view = staged
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(corner)
                .overlay(corner.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                // No drop shadow and no margin: the PNG is exactly the card, with
                // its native antialiased corners. Depth/separation is composited
                // later (compose-readme-hero overlaps the cards with a hairline).
                // Outermost so the dark scheme reaches the background and chrome too.
                .environment(\.colorScheme, scheme)

            let renderer = ImageRenderer(content: view)
            // 4x so the README compositor can supersample: it overlaps these and
            // downscales the final hero with LANCZOS for the smoothest edges/text.
            renderer.scale = 4
            let image = renderer.nsImage
            write(image, to: url)
            note("wrote \(url.lastPathComponent) — \(image.map { "\($0.size)" } ?? "nil")")
        }

        // MARK: - Demo data

        private static func device(_ id: AudioDeviceID, _ uid: String, _ name: String,
                                   _ transport: UInt32) -> AudioDevice {
            AudioDevice(id: id, uid: uid, name: name, transport: transport,
                        outputDataSource: 0, inputDataSource: 0)
        }

        private static func app(_ id: pid_t, _ bundleID: String, _ name: String,
                                playing: Bool, recording: Bool = false) -> AudioApp {
            AudioApp(id: id, bundleID: bundleID, name: name, objectIDs: [],
                     isPlaying: playing, isRecording: recording)
        }

        private static let speakers = device(1, "BuiltInSpeakers", "MacBook Pro Speakers",
                                             kAudioDeviceTransportTypeBuiltIn)
        private static let airpodsPro = device(2, "AA-BB-CC-DD-EE-FF:output", "AirPods Pro",
                                               kAudioDeviceTransportTypeBluetooth)
        private static let airpods4 = device(3, "11-22-33-44-55-66:output", "AirPods 4",
                                             kAudioDeviceTransportTypeBluetooth)
        /// Eleven wired devices with no usage stamp — they fold into the
        /// "Rarely used (11)" disclosure, never shown individually.
        private static let rarelyUsedOutputs: [AudioDevice] = (0 ..< 11).map { i in
            device(AudioDeviceID(100 + i), "rare-out-\(i)", "USB Audio \(i)", kAudioDeviceTransportTypeUSB)
        }

        private static var allOutputs: [AudioDevice] {
            [speakers, airpodsPro, airpods4] + rarelyUsedOutputs
        }

        /// Paired-but-disconnected headphones — its address matches no HAL
        /// device, so it lands in the Bluetooth section across every tab.
        private static let headphones = BluetoothAudioDevice(
            id: "77-88-99-AA-BB-CC", name: "WH-1000XM5", isConnected: false, minorClass: 0
        )

        // MARK: - Scene engines

        /// Default device with the full picker below it — the resting state.
        private static func idleEngine() -> MixerEngine {
            let engine = MixerEngine()
            engine.deviceMonitor.seedForRender(devices: allOutputs, defaultDeviceID: airpodsPro.id,
                                               recentUIDs: [speakers.uid])
            engine.systemVolume.seedForRender(volume: 0.6, isMuted: false, deviceName: airpodsPro.name)
            engine.bluetooth.seedForRender(paired: [headphones])
            engine.processMonitor.seedForRender(apps: [
                app(701, "us.zoom.xos", "zoom.us", playing: true),
            ])
            engine.seedForRender(volumes: [:])
            return engine
        }

        /// The drag-to-pair scene: same as idle, but AirPods 4 is the row being
        /// dragged (painted as the lifted dragPreview overlay), so it's lifted
        /// out of the list below — a device can't be in two places at once.
        private static func dragEngine() -> MixerEngine {
            let engine = MixerEngine()
            engine.deviceMonitor.seedForRender(devices: [speakers, airpodsPro] + rarelyUsedOutputs,
                                               defaultDeviceID: airpodsPro.id, recentUIDs: [speakers.uid])
            engine.systemVolume.seedForRender(volume: 0.6, isMuted: false, deviceName: airpodsPro.name)
            engine.bluetooth.seedForRender(paired: [headphones])
            engine.processMonitor.seedForRender(apps: [
                app(701, "us.zoom.xos", "zoom.us", playing: true),
            ])
            engine.seedForRender(volumes: [:])
            return engine
        }

        /// Two devices playing together: the multi-output members fill the top
        /// zone, per-app volume is paused.
        private static func pairedEngine() -> MixerEngine {
            let engine = MixerEngine()
            // While multi-output is active the real default is the hidden
            // aggregate, not any listed device — so no row shows the checkmark.
            // A sentinel id absent from the list reproduces that.
            engine.deviceMonitor.seedForRender(devices: allOutputs, defaultDeviceID: AudioDeviceID(900),
                                               recentUIDs: [speakers.uid])
            engine.bluetooth.seedForRender(paired: [headphones])
            engine.multiOutput.seedForRender(members: [
                .init(device: airpodsPro, volume: DeviceVolumeController(renderVolume: 0.7)),
                .init(device: airpods4, volume: DeviceVolumeController(renderVolume: 0.45)),
            ])
            engine.processMonitor.seedForRender(apps: [])
            engine.seedForRender(volumes: [:])
            return engine
        }

        /// One app pinned to two non-default outputs, each with its own slider.
        private static func routingEngine() -> MixerEngine {
            let engine = MixerEngine()
            engine.deviceMonitor.seedForRender(devices: allOutputs, defaultDeviceID: airpodsPro.id,
                                               recentUIDs: [speakers.uid])
            engine.systemVolume.seedForRender(volume: 0.6, isMuted: false, deviceName: airpodsPro.name)
            engine.bluetooth.seedForRender(paired: [headphones])
            engine.processMonitor.seedForRender(apps: [
                app(702, "com.apple.Safari", "Safari", playing: true),
                app(703, "us.zoom.xos", "zoom.us", playing: false),
            ])
            engine.seedForRender(
                volumes: [
                    "com.apple.Safari": AppVolume(outputDeviceUIDs: [speakers.uid, airpods4.uid]),
                    "us.zoom.xos": AppVolume(volume: 0.68),
                ],
                routeVolumes: [
                    speakers.uid: DeviceVolumeController(renderVolume: 0.8),
                    airpods4.uid: DeviceVolumeController(renderVolume: 0.5),
                ]
            )
            return engine
        }

        /// The microphone tab: input device, gain slider, who's recording.
        private static func microphoneEngine() -> MixerEngine {
            let engine = MixerEngine()
            // The output monitor only feeds the shared Bluetooth presence check.
            engine.deviceMonitor.seedForRender(devices: allOutputs, defaultDeviceID: airpodsPro.id)
            engine.bluetooth.seedForRender(paired: [headphones])
            let shure = device(200, "ShureMV7", "Shure MV7", kAudioDeviceTransportTypeUSB)
            let rarelyUsedInputs: [AudioDevice] = (0 ..< 4).map { i in
                device(AudioDeviceID(210 + i), "rare-in-\(i)", "Input \(i)", kAudioDeviceTransportTypeUSB)
            }
            engine.inputDeviceMonitor.seedForRender(devices: [shure] + rarelyUsedInputs, defaultDeviceID: shure.id)
            engine.inputVolume.seedForRender(volume: 0.4, isMuted: false, deviceName: shure.name)
            engine.processMonitor.seedForRender(apps: [])
            engine.seedForRender(volumes: [:])
            return engine
        }

        /// Bluetooth management: a connected BT device as the current output,
        /// with several paired-but-disconnected devices in the Bluetooth section
        /// — each connectable with a click. No apps, to keep the focus on devices.
        private static func bluetoothEngine() -> MixerEngine {
            let engine = MixerEngine()
            engine.deviceMonitor.seedForRender(devices: [speakers, airpodsPro] + rarelyUsedOutputs,
                                               defaultDeviceID: airpodsPro.id, recentUIDs: [speakers.uid])
            engine.systemVolume.seedForRender(volume: 0.6, isMuted: false, deviceName: airpodsPro.name)
            engine.bluetooth.seedForRender(paired: [
                headphones,
                BluetoothAudioDevice(id: "12-34-56-78-9A-BC", name: "Beats Studio Pro",
                                     isConnected: false, minorClass: 0),
                BluetoothAudioDevice(id: "DE-F0-12-34-56-78", name: "JBL Flip 6",
                                     isConnected: false, minorClass: 0),
            ])
            engine.processMonitor.seedForRender(apps: [
                app(704, "us.zoom.xos", "zoom.us", playing: true),
            ])
            engine.seedForRender(volumes: [:])
            return engine
        }

        // MARK: - Drag preview

        /// The device row lifted from the list toward the pair zone — what a
        /// live drag looks like (a plain list row, elevated and following the
        /// pointer), which a static frame can't capture. Mirrors the real
        /// gesture: same row layout as DeviceRowView, just shadowed. The pixel
        /// offsets are tuned to the seeded idle layout (320-wide popover, Output
        /// card near the top); re-check them if that scene's contents change.
        private static var dragPreview: some View {
            HStack(spacing: 8) {
                Image(systemName: "airpods.gen3")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text("AirPods 4")
                    .font(.system(size: 12))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(width: 244, height: 28)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.35), radius: 9, y: 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .offset(x: 44, y: 112)
            .allowsHitTesting(false)
        }

        // MARK: - Output

        /// The real icon of an installed app, by bundle id — nil if not installed.
        static func demoIcon(forBundleID bundleID: String) -> NSImage? {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
            return NSWorkspace.shared.icon(forFile: url.path)
        }

        private static func write(_ image: NSImage?, to url: URL) {
            guard let image,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:])
            else { return }
            try? png.write(to: url)
        }
    }
#endif
