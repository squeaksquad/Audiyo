import SwiftUI
import AVFoundation
import CoreAudio
import AudioToolbox
import Combine

// MARK: - 1. Data Models

struct LibraryItem: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let url: URL
    let isPlayable: Bool
    var children: [LibraryItem]?
}

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
}

class Track: ObservableObject, Identifiable {
    let id: Int
    let url: URL
    let file: AVAudioFile
    let sampleRate: Double
    let originalBuffer: AVAudioPCMBuffer
    let scratchBuffer: AVAudioPCMBuffer
    let scratchLoopBuffer: AVAudioPCMBuffer
    
    var name: String { url.deletingPathExtension().lastPathComponent }
    
    @Published var volume: Float = 1.0
    @Published var meterLevel: Float = -100.0
    
    // Performance: track last update to throttle UI
    var lastUpdate: TimeInterval = 0
    
    init(id: Int, url: URL, file: AVAudioFile, sampleRate: Double, originalBuffer: AVAudioPCMBuffer, scratchBuffer: AVAudioPCMBuffer, scratchLoopBuffer: AVAudioPCMBuffer) {
        self.id = id
        self.url = url
        self.file = file
        self.sampleRate = sampleRate
        self.originalBuffer = originalBuffer
        self.scratchBuffer = scratchBuffer
        self.scratchLoopBuffer = scratchLoopBuffer
    }
    
    var sampleRateString: String {
        return String(format: "%.0f Hz", sampleRate)
    }
}

// MARK: - 2. Audio Engine

class AudioPlayer: ObservableObject {
    @Published var libraryRoot: [LibraryItem] = []
    @Published var currentSongId: UUID?
    
    @Published var tracks: [Track] = []
    @Published var devices: [AudioDevice] = []
    @Published var selectedDeviceID: AudioDeviceID = 0
    @Published var deviceSampleRate: Double = 44100.0
    
    @Published var isPlaying = false
    @Published var isLooping = false
    @Published var playbackProgress: Double = 0.0
    
    @Published var markers: [Int: Double] = [:]
    @Published var loopStart: Double = 0.0
    @Published var loopEnd: Double = 1.0
    
    @Published var currentDisplayTime: String = "0:00"
    @Published var totalDuration: Double = 0.0
    var totalDurationString: String { formatTime(totalDuration) }
    
    @Published var showError = false
    @Published var errorMessage = ""
    
    private let engine = AVAudioEngine()
    private let mainMixer = AVAudioMixerNode()
    private var players: [AVAudioPlayerNode] = []
    
    private var timer: Timer?
    private var audioSampleRate: Double = 44100.0
    private var audioLengthSamples: AVAudioFramePosition = 0
    
    private var currentStartFrame: AVAudioFramePosition = 0
    private var currentEndFrame: AVAudioFramePosition = 0
    
    private var hardwareFormat: AVAudioFormat?
    private var currentURLs: [URL] = []
    
    private let kSavedDeviceName = "SavedAudioDeviceName"
    private let kSavedLibraryBookmark = "SavedLibraryBookmark"
    
    init() {
        setupEngine()
        fetchDevices()
        restoreSavedDevice()
        // 1. Saved Bookmark
        if restoreLastLibrary() { return }
        // 2. Default Path
        if loadHomeDirectoryLibrary() { return }
        // 3. Internal Fallback
        loadInternalLibrary()
    }
    
    // MARK: - Core Audio Setup
    private func getDeviceOutputChannelCount(deviceID: AudioDeviceID) -> Int {
        var propertyAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)
        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
        defer { bufferListPointer.deallocate() }
        AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, bufferListPointer)
        var bufferList = bufferListPointer.pointee
        var totalChannels = 0
        let buffers = UnsafeBufferPointer<AudioBuffer>(start: &bufferList.mBuffers, count: Int(bufferList.mNumberBuffers))
        for buffer in buffers { totalChannels += Int(buffer.mNumberChannels) }
        return totalChannels > 0 ? totalChannels : 2
    }
    
    private func setupEngine() {
        engine.stop()
        engine.detach(mainMixer)
        engine.attach(mainMixer)
        let outputNode = engine.outputNode
        var outputFormat = outputNode.outputFormat(forBus: 0)
        var currentDeviceID = AudioDeviceID(0)
        if let audioUnit = outputNode.audioUnit {
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            AudioUnitGetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &currentDeviceID, &size)
        }
        var channels = 2
        if currentDeviceID != 0 {
            channels = getDeviceOutputChannelCount(deviceID: currentDeviceID)
        }
        if let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)) {
            outputFormat = AVAudioFormat(standardFormatWithSampleRate: outputFormat.sampleRate, channelLayout: layout)
        }
        DispatchQueue.main.async { self.deviceSampleRate = outputFormat.sampleRate }
        self.hardwareFormat = outputFormat
        engine.connect(mainMixer, to: outputNode, format: outputFormat)
        do { try engine.start() } catch { print("Engine Error: \(error)") }
    }
    
    // MARK: - Track Setup
    private func setupTracks() {
        stop()
        engine.stop()
        players.forEach { engine.detach($0) }
        
        let savedVolumes = tracks.reduce(into: [Int: Float]()) { dict, track in
            dict[track.id] = track.volume
        }
        
        players.removeAll()
        tracks.removeAll()
        setupEngine()
        
        guard let hwFormat = self.hardwareFormat else { return }
        if currentURLs.isEmpty { return }
        
        // Reset Error State
        DispatchQueue.main.async {
            self.showError = false
            self.errorMessage = ""
        }
        
        let hardwareLimit = Int(hwFormat.channelCount)
        let filesToLoad = self.currentURLs.prefix(hardwareLimit)
        
        for (index, url) in filesToLoad.enumerated() {
            do {
                let file = try AVAudioFile(forReading: url)
                let sr = file.processingFormat.sampleRate
                
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { continue }
                try file.read(into: buffer)
                guard let scratch = AVAudioPCMBuffer(pcmFormat: hwFormat, frameCapacity: AVAudioFrameCount(file.length)) else { continue }
                guard let scratchLoop = AVAudioPCMBuffer(pcmFormat: hwFormat, frameCapacity: AVAudioFrameCount(file.length)) else { continue }
                
                if index == 0 {
                    self.audioLengthSamples = file.length
                    self.audioSampleRate = sr
                    self.totalDuration = Double(audioLengthSamples) / audioSampleRate
                    
                    // Sample Rate Mismatch Check
                    if abs(hwFormat.sampleRate - sr) > 1.0 {
                        DispatchQueue.main.async {
                            self.errorMessage = "⚠️ Mismatch: Device is \(Int(hwFormat.sampleRate))Hz, File is \(Int(sr))Hz"
                            self.showError = true
                        }
                    }
                }
                
                let player = AVAudioPlayerNode()
                let vol = savedVolumes[index] ?? 1.0
                player.volume = vol
                
                engine.attach(player)
                engine.connect(player, to: mainMixer, format: hwFormat)
                players.append(player)
                
                let trackObj = Track(id: index, url: url, file: file, sampleRate: sr, originalBuffer: buffer, scratchBuffer: scratch, scratchLoopBuffer: scratchLoop)
                trackObj.volume = vol
                tracks.append(trackObj)
                
                player.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] (buffer, time) in
                    self?.processMeter(buffer: buffer, trackIndex: index, channelIndex: index)
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Error: \(error.localizedDescription)"
                    self.showError = true
                }
            }
        }
        try? engine.start()
        playbackProgress = 0.0
        updateTimeLabel(progress: 0.0)
    }
    
    // MARK: - Playback Logic
    func play(from startProgress: Double? = nil) {
        if !engine.isRunning { try? engine.start() }
        
        let effectiveStartProgress = startProgress ?? (isLooping ? loopStart : playbackProgress)
        let startFrame = AVAudioFramePosition(Double(audioLengthSamples) * effectiveStartProgress)
        let loopEndFrame = AVAudioFramePosition(Double(audioLengthSamples) * loopEnd)
        
        self.currentStartFrame = startFrame
        
        let shouldLoop = isLooping && startFrame < loopEndFrame
        self.currentEndFrame = shouldLoop ? loopEndFrame : audioLengthSamples
        
        let delaySeconds = 0.02
        let hostTime = mach_absolute_time() + UInt64(delaySeconds * 1_000_000_000)
        let startTime = AVAudioTime(hostTime: hostTime)
        
        players.forEach { $0.stop() }
        
        for (i, player) in players.enumerated() {
            let source = tracks[i].originalBuffer
            let scratch = tracks[i].scratchBuffer
            let scratchLoop = tracks[i].scratchLoopBuffer
            
            if shouldLoop {
                let loopStartFrame = AVAudioFramePosition(Double(audioLengthSamples) * loopStart)
                
                let introLen = loopEndFrame - startFrame
                if introLen > 0 {
                    copySlice(from: source, to: scratch, startFrame: startFrame, frameCount: AVAudioFrameCount(introLen), targetChannel: i)
                    player.scheduleBuffer(scratch, at: nil, options: [], completionHandler: nil)
                }
                
                let loopLen = loopEndFrame - loopStartFrame
                if loopLen > 0 {
                    copySlice(from: source, to: scratchLoop, startFrame: loopStartFrame, frameCount: AVAudioFrameCount(loopLen), targetChannel: i)
                    player.scheduleBuffer(scratchLoop, at: nil, options: .loops, completionHandler: nil)
                }
                
            } else {
                let length = audioLengthSamples - startFrame
                if length > 0 {
                    copySlice(from: source, to: scratch, startFrame: startFrame, frameCount: AVAudioFrameCount(length), targetChannel: i)
                    player.scheduleBuffer(scratch, at: nil, options: [], completionHandler: nil)
                }
            }
            player.play(at: startTime)
        }
        
        self.playbackProgress = effectiveStartProgress
        isPlaying = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds) { self.startTimer() }
    }
    
    private func copySlice(from source: AVAudioPCMBuffer, to destination: AVAudioPCMBuffer, startFrame: AVAudioFramePosition, frameCount: AVAudioFrameCount, targetChannel: Int) {
        destination.frameLength = frameCount
        let destChannels = Int(destination.format.channelCount)
        if targetChannel >= destChannels { return }
        for ch in 0..<destChannels {
            if let ptr = destination.floatChannelData?[ch] { memset(ptr, 0, Int(frameCount) * MemoryLayout<Float>.size) }
        }
        if let srcBasePtr = source.floatChannelData?[0],
           let dstPtr = destination.floatChannelData?[targetChannel] {
            let srcOffsetPtr = srcBasePtr.advanced(by: Int(startFrame))
            memcpy(dstPtr, srcOffsetPtr, Int(frameCount) * MemoryLayout<Float>.size)
        }
    }
    
    // MARK: - Visual Timer
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in self?.updateProgress() }
    }
    
    private func updateProgress() {
        guard let node = players.first, let nodeTime = node.lastRenderTime, let playerTime = node.playerTime(forNodeTime: nodeTime) else { return }
        
        let framesPlayed = playerTime.sampleTime
        var absoluteFrame: AVAudioFramePosition = 0
        let loopEndFrame = AVAudioFramePosition(Double(audioLengthSamples) * loopEnd)
        
        if isLooping && currentStartFrame < loopEndFrame {
            let loopStartFrame = AVAudioFramePosition(Double(audioLengthSamples) * loopStart)
            let loopLength = loopEndFrame - loopStartFrame
            let introLength = loopEndFrame - currentStartFrame
            
            if framesPlayed < introLength {
                absoluteFrame = currentStartFrame + framesPlayed
            } else {
                let framesInLoop = framesPlayed - introLength
                let offset = framesInLoop % max(1, loopLength)
                absoluteFrame = loopStartFrame + offset
            }
        } else {
            absoluteFrame = currentStartFrame + framesPlayed
        }
        
        let progress = Double(absoluteFrame) / Double(audioLengthSamples)
        self.playbackProgress = min(max(progress, 0.0), 1.0)
        updateTimeLabel(progress: self.playbackProgress)
        
        if !isLooping && self.playbackProgress >= 1.0 { stop(); self.playbackProgress = 0.0 }
    }
    
    // MARK: - Controls
    func togglePlay() { if isPlaying { stop() } else { play(from: playbackProgress) } }
    func toggleLoop() { isLooping.toggle(); restartIfPlaying() }
    func stop() { players.forEach { $0.stop() }; isPlaying = false; timer?.invalidate(); timer = nil }
    
    func setVolume(_ vol: Float, index: Int) {
        if index < players.count {
            players[index].volume = vol
            if index < tracks.count { tracks[index].volume = vol }
        }
    }
    
    func restartIfPlaying() { if isPlaying { play(from: playbackProgress) } }
    
    func resetLoop() { loopStart = 0.0; loopEnd = 1.0; if isPlaying && isLooping { restartIfPlaying() } }
    func setLoopIn() { loopStart = playbackProgress; if loopStart >= loopEnd { loopEnd = 1.0 }; if isPlaying && isLooping { restartIfPlaying() } }
    func setLoopOut() { loopEnd = playbackProgress; if loopEnd <= loopStart { loopStart = 0.0 }; if isPlaying && isLooping { restartIfPlaying() } }
    func setMarker(at index: Int) { guard index >= 1 && index <= 9 else { return }; markers[index] = playbackProgress }
    func jumpToMarker(at index: Int) { guard let progress = markers[index] else { return }; seek(to: progress) }
    func jumpToStart() { seek(to: isLooping ? loopStart : 0.0) }
    
    func seek(to progress: Double) {
        let wasPlaying = isPlaying
        stop()
        self.playbackProgress = progress
        self.updateTimeLabel(progress: progress)
        if wasPlaying { play(from: progress) }
    }
    
    private func updateTimeLabel(progress: Double) {
        let currentSeconds = totalDuration * progress
        self.currentDisplayTime = formatTime(currentSeconds)
    }
    func formatTime(_ seconds: Double) -> String {
        if seconds.isNaN || seconds.isInfinite { return "0:00" }
        let m = Int(seconds) / 60; let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
    
    private func processMeter(buffer: AVAudioPCMBuffer, trackIndex: Int, channelIndex: Int) {
        guard trackIndex < self.tracks.count else { return }
        
        // Throttling: Ensure we don't update UI more than ~30 times a second
        let now = CACurrentMediaTime()
        let track = self.tracks[trackIndex]
        if now - track.lastUpdate < 0.03 { return }
        track.lastUpdate = now
        
        guard let floatData = buffer.floatChannelData else { return }
        if channelIndex >= Int(buffer.format.channelCount) { return }
        
        let channelData = floatData[channelIndex]
        let frames = Int(buffer.frameLength)
        var sum: Float = 0
        let strideVal = 10
        for i in stride(from: 0, to: frames, by: strideVal) {
            let sample = channelData[i]
            sum += sample * sample
        }
        
        let rms = sqrt(sum / Float(frames / strideVal))
        let avgPower = 20 * log10(rms)
        
        DispatchQueue.main.async {
            track.meterLevel = avgPower
        }
    }
    
    // MARK: - Library & Hardware
    private func loadHomeDirectoryLibrary() -> Bool {
        // Looks for: /Users/currentUser/.Audiyo Library
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent(".Audiyo Library")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            scanAndSetLibrary(at: url)
            return true
        }
        return false
    }
    
    private func loadInternalLibrary() {
        guard let rootURL = Bundle.main.url(forResource: "Library", withExtension: nil) else { return }
        scanAndSetLibrary(at: rootURL)
    }
    
    func loadLibraryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "Select Master Library Folder"
        panel.begin { response in
            if response == .OK, let rootURL = panel.url {
                self.saveBookmark(for: rootURL)
                self.scanAndSetLibrary(at: rootURL)
            }
        }
    }
    
    private func saveBookmark(for url: URL) {
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: kSavedLibraryBookmark)
        } catch { print("Failed to save bookmark: \(error)") }
    }
    
    private func restoreLastLibrary() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: kSavedLibraryBookmark) else { return false }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            if isStale { saveBookmark(for: url) }
            if url.startAccessingSecurityScopedResource() {
                scanAndSetLibrary(at: url)
                return true
            }
        } catch { print("Failed to restore bookmark: \(error)") }
        return false
    }
    
    private func scanAndSetLibrary(at url: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            let items = self.scanDirectory(at: url)
            DispatchQueue.main.async { self.libraryRoot = items }
        }
    }
    
    private func scanDirectory(at url: URL) -> [LibraryItem] {
        let fileManager = FileManager.default
        var items: [LibraryItem] = []
        do {
            let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            let subdirs = contents.filter {
                var isDir: ObjCBool = false
                return fileManager.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for dir in subdirs {
                let dirChildren = self.scanDirectory(at: dir)
                let dirContents = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                let dirHasAudio = dirContents?.contains { ["wav", "aif", "aiff", "mp3"].contains($0.pathExtension.lowercased()) } ?? false
                if !dirChildren.isEmpty || dirHasAudio {
                    let item = LibraryItem(name: dir.lastPathComponent, url: dir, isPlayable: dirHasAudio, children: dirChildren.isEmpty ? nil : dirChildren)
                    items.append(item)
                }
            }
            return items
        } catch { return [] }
    }
    
    func loadItem(_ item: LibraryItem) {
        guard item.isPlayable else { return }
        stop()
        self.markers = [:]; self.loopStart = 0.0; self.loopEnd = 1.0
        self.currentSongId = item.id
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: item.url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            let audioURLs = contents.filter { ["wav", "aif", "aiff", "mp3"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            self.currentURLs = audioURLs
            setupTracks()
        } catch { self.errorMessage = "Failed: \(error.localizedDescription)"; self.showError = true }
    }
    
    private func restoreSavedDevice() {
        if let savedName = UserDefaults.standard.string(forKey: kSavedDeviceName) {
            if let matchingDevice = devices.first(where: { $0.name == savedName }) {
                self.selectedDeviceID = matchingDevice.id
                setOutputDevice(id: matchingDevice.id)
            }
        }
    }
    
    func refreshHardwareState() {
        let currentID = selectedDeviceID
        fetchDevices()
        if devices.contains(where: { $0.id == currentID }) { self.selectedDeviceID = currentID }
        else if let first = devices.first { self.selectedDeviceID = first.id; setOutputDevice(id: first.id) }
        if !tracks.isEmpty { setupTracks() }
    }
    
    func setOutputDevice(id: AudioDeviceID) {
        if let device = devices.first(where: { $0.id == id }) { UserDefaults.standard.set(device.name, forKey: kSavedDeviceName) }
        engine.pause()
        if let outputUnit = engine.outputNode.audioUnit {
            var deviceID = id
            AudioUnitSetProperty(outputUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        if !currentURLs.isEmpty { setupTracks() } else { setupEngine() }
    }
    
    func fetchDevices() {
        var propertySize: UInt32 = 0
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize)
        let count = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize, &ids)
        self.devices = ids.compactMap { id -> AudioDevice? in
            var size = UInt32(0)
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: 0)
            AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size)
            guard size > 0 else { return nil }
            var name: CFString? = nil
            var propsize = UInt32(MemoryLayout<CFString?>.size)
            var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
            let result = AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &propsize, &name)
            if result == noErr, let validName = name { return AudioDevice(id: id, name: String(validName)) }
            return nil
        }
        if selectedDeviceID == 0, let first = devices.first { selectedDeviceID = first.id }
    }
}

// MARK: - 3. UI Components

func meterColor(level: Float) -> Color {
    if level > -5 { return .red }
    if level > -15 { return .yellow }
    return .green
}

struct TrackRow: View {
    @ObservedObject var track: Track
    var onVolumeChange: (Float) -> Void
    
    var body: some View {
        HStack(spacing: 15) {
            // Track Info
            VStack(alignment: .leading, spacing: 2) {
                Text("CH \(track.id + 1)")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
                Text(track.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
            
            Text(track.sampleRateString)
                .font(.caption)
                .foregroundColor(.gray)
                .frame(width: 60, alignment: .trailing)
            
            // Volume Slider (No Text)
            Slider(value: $track.volume, in: 0...1) { editing in
                if !editing { onVolumeChange(track.volume) }
            }
            .onChange(of: track.volume) { newVal in onVolumeChange(newVal) }
            .frame(width: 100)
            
            // Horizontal Meter
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.gray.opacity(0.3)).cornerRadius(3)
                Rectangle()
                    .fill(meterColor(level: track.meterLevel))
                    .frame(width: 300 * CGFloat(max(0, min(1, (track.meterLevel + 60) / 60))))
                    .cornerRadius(3)
                    .animation(.easeOut(duration: 0.1), value: track.meterLevel)
            }
            .frame(width: 300, height: 24)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

struct ShortcutsView: View {
    let shortcuts = [
        ("CMD+(1-9)", "Add marker"),
        ("(1-9)", "Go to marker"),
        ("0", "Play from start (or loop)"),
        ("Space bar", "Play/Pause"),
        ("I", "Set Loop In"),
        ("O", "Set Loop Out"),
        ("L", "Toggle loop on/off"),
        ("CMD+Shift+L", "Reset loop region")
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keyboard Shortcuts").font(.headline).padding(.bottom, 5)
            ForEach(shortcuts, id: \.0) { key, desc in
                HStack {
                    Text(key).font(.system(.body, design: .monospaced)).fontWeight(.bold).frame(width: 140, alignment: .leading)
                    Text(desc).foregroundColor(.secondary)
                }
            }
        }.padding().frame(width: 350)
    }
}

struct PasswordPromptView: View {
    @Binding var isPresented: Bool
    var onSuccess: () -> Void
    @State private var password = ""
    @State private var shake = 0
    private let adminPassword = "the Cake is a Lie"
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Admin Access").font(.headline)
            Text("Enter password to change library location.").font(.caption).foregroundColor(.secondary)
            SecureField("Password", text: $password)
                .frame(width: 200).textFieldStyle(RoundedBorderTextFieldStyle()).onSubmit { checkPassword() }
            HStack {
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Unlock") { checkPassword() }.keyboardShortcut(.defaultAction)
            }
        }.padding().frame(width: 300, height: 180).modifier(ShakeEffect(animatableData: CGFloat(shake)))
    }
    func checkPassword() { if password == adminPassword { isPresented = false; onSuccess() } else { withAnimation(.default) { shake += 1 }; password = "" } }
}

struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(animatableData * .pi * 2), y: 0))
    }
}

struct TimelineView: View {
    @ObservedObject var player: AudioPlayer
    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                // Larger Time Display
                Text(player.currentDisplayTime)
                    .font(.system(size: 38, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                
                Text(" / " + player.totalDurationString)
                    .font(.system(size: 16, weight: .regular, design: .monospaced))
                    .foregroundColor(.gray)
                Spacer()
            }.padding(.horizontal, 5)
            
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.gray.opacity(0.3)).frame(height: 30).cornerRadius(4)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            let ratio = value.location.x / geo.size.width
                            player.seek(to: max(0.0, min(1.0, ratio)))
                        })
                    
                    Rectangle().fill(Color.blue.opacity(0.2))
                        .frame(width: max(0, geo.size.width * CGFloat(player.loopEnd - player.loopStart)), height: 30)
                        .offset(x: geo.size.width * CGFloat(player.loopStart))
                        .allowsHitTesting(false)
                    
                    ForEach(player.markers.keys.sorted(), id: \.self) { key in
                        if let pos = player.markers[key] {
                            ZStack {
                                Rectangle().fill(Color.orange).frame(width: 2, height: 30)
                                Text("\(key)").font(.system(size: 10, weight: .bold)).foregroundColor(.black)
                                    .background(Color.orange).cornerRadius(2).offset(y: -20)
                            }.offset(x: geo.size.width * CGFloat(pos)).allowsHitTesting(false)
                        }
                    }
                    Rectangle().fill(Color.white).frame(width: 2, height: 30)
                        .offset(x: geo.size.width * CGFloat(player.playbackProgress)).allowsHitTesting(false)
                    
                    Circle().fill(Color.green).frame(width: 16, height: 16)
                        .offset(x: (geo.size.width * CGFloat(player.loopStart)) - 8)
                        .gesture(DragGesture().onChanged { value in
                            player.loopStart = max(0, min(player.loopEnd - 0.001, value.location.x / geo.size.width))
                        }.onEnded { _ in player.restartIfPlaying() })
                    
                    Circle().fill(Color.red).frame(width: 16, height: 16)
                        .offset(x: (geo.size.width * CGFloat(player.loopEnd)) - 8)
                        .gesture(DragGesture().onChanged { value in
                            player.loopEnd = min(1.0, max(player.loopStart + 0.001, value.location.x / geo.size.width))
                        }.onEnded { _ in player.restartIfPlaying() })
                }
            }.frame(height: 30)
        }
    }
}

// MARK: - 4. Main View

struct ContentView: View {
    @StateObject var player = AudioPlayer()
    @State private var showShortcuts = false
    @State private var showPasswordPrompt = false
    
    var body: some View {
        HSplitView {
            // SIDEBAR
            VStack(spacing: 0) {
                Text("Library").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding()
                Divider()
                List(player.libraryRoot, children: \.children) { item in
                    HStack {
                        Image(systemName: item.isPlayable ? "music.note" : "folder")
                        Text(item.name)
                        Spacer()
                        if player.currentSongId == item.id { Image(systemName: "speaker.wave.2.fill").foregroundColor(.accentColor) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { if item.isPlayable { player.loadItem(item) } }
                    .foregroundColor(item.isPlayable ? .primary : .secondary)
                }
                Divider()
                Button(action: { showPasswordPrompt = true }) {
                    HStack { Image(systemName: "lock.fill"); Text("Load Library Folder") }.frame(maxWidth: .infinity).padding(10)
                }.buttonStyle(.borderless).background(Color(nsColor: .controlBackgroundColor))
            }.frame(minWidth: 250, maxWidth: 350)
            
            // MAIN CONTENT
            VStack(spacing: 0) {
                // Invisible Shortcuts for Keyboard Support
                Group {
                    Button(action: { player.jumpToStart() }) {}.keyboardShortcut("0", modifiers: [])
                    Button(action: { player.jumpToMarker(at: 1) }) {}.keyboardShortcut("1", modifiers: [])
                    Button(action: { player.setMarker(at: 1) }) {}.keyboardShortcut("1", modifiers: [.command])
                    Button(action: { player.jumpToMarker(at: 2) }) {}.keyboardShortcut("2", modifiers: [])
                    Button(action: { player.setMarker(at: 2) }) {}.keyboardShortcut("2", modifiers: [.command])
                    Button(action: { player.jumpToMarker(at: 3) }) {}.keyboardShortcut("3", modifiers: [])
                    Button(action: { player.setMarker(at: 3) }) {}.keyboardShortcut("3", modifiers: [.command])
                    Button(action: { player.jumpToMarker(at: 4) }) {}.keyboardShortcut("4", modifiers: [])
                    Button(action: { player.setMarker(at: 4) }) {}.keyboardShortcut("4", modifiers: [.command])
                    Button(action: { player.jumpToMarker(at: 5) }) {}.keyboardShortcut("5", modifiers: [])
                    Button(action: { player.setMarker(at: 5) }) {}.keyboardShortcut("5", modifiers: [.command])
                    Button(action: { player.jumpToMarker(at: 6) }) {}.keyboardShortcut("6", modifiers: [])
                    Button(action: { player.setMarker(at: 6) }) {}.keyboardShortcut("6", modifiers: [.command])
                    Button(action: { player.jumpToMarker(at: 7) }) {}.keyboardShortcut("7", modifiers: [])
                    Button(action: { player.setMarker(at: 7) }) {}.keyboardShortcut("7", modifiers: [.command])
                    Button(action: { player.jumpToMarker(at: 8) }) {}.keyboardShortcut("8", modifiers: [])
                    Button(action: { player.setMarker(at: 8) }) {}.keyboardShortcut("8", modifiers: [.command])
                    Button(action: { player.jumpToMarker(at: 9) }) {}.keyboardShortcut("9", modifiers: [])
                    Button(action: { player.setMarker(at: 9) }) {}.keyboardShortcut("9", modifiers: [.command])
                    Button(action: { player.toggleLoop() }) {}.keyboardShortcut("l", modifiers: [])
                    Button(action: { player.resetLoop() }) {}.keyboardShortcut("l", modifiers: [.command, .shift])
                    Button(action: { player.setLoopIn() }) {}.keyboardShortcut("i", modifiers: [])
                    Button(action: { player.setLoopOut() }) {}.keyboardShortcut("o", modifiers: [])
                }.frame(width: 0, height: 0).opacity(0)
                
                // TOP HEADER
                HStack(alignment: .center) { // All controls vertically centered
                    
                    // LEFT: Transport (Play/Loop)
                    HStack(spacing: 15) {
                        Button(action: player.togglePlay) {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 30))
                                .foregroundColor(player.isPlaying ? .yellow : .green)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.space, modifiers: [])
                        
                        Toggle("Loop", isOn: $player.isLooping)
                            .toggleStyle(.switch)
                            .onChange(of: player.isLooping) { _ in player.restartIfPlaying() }
                    }
                    
                    Spacer()
                    
                    // RIGHT GROUP: Shortcuts + Device
                    HStack(alignment: .center, spacing: 20) {
                        
                        // Shortcuts Button
                        Button(action: { showShortcuts.toggle() }) {
                            HStack {
                                Image(systemName: "keyboard")
                                Text("SHORTCUTS").font(.caption).fontWeight(.bold)
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).stroke(Color.gray, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showShortcuts) {
                            ShortcutsView()
                        }
                        
                        // Audio Output Selector
                        HStack(spacing: 8) {
                            Text("Audio Device")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Picker("", selection: $player.selectedDeviceID) {
                                ForEach(player.devices) { device in
                                    Text(device.name).tag(device.id)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 200)
                            .onChange(of: player.selectedDeviceID) { _ in player.setOutputDevice(id: player.selectedDeviceID) }
                            
                            Button(action: { player.refreshHardwareState() }) {
                                Image(systemName: "arrow.clockwise")
                            }
                            .help("Reset CoreAudio")
                        }
                    }
                }
                .padding()
                
                // Visual Isolation from Play Bar
                Divider()
                
                // TIMELINE ROW (Full Width)
                VStack(spacing: 0) {
                    TimelineView(player: player)
                        .padding(.horizontal)
                        .padding(.top, 15) // Added top padding for isolation
                        .padding(.bottom, 15)
                }
                .background(Color(nsColor: .controlBackgroundColor))
                
                Divider()
                
                // MAIN CONTENT (Tracks)
                if player.tracks.isEmpty {
                    Spacer()
                    VStack(spacing: 10) {
                        Image(systemName: "music.note.list").font(.system(size: 40)).foregroundColor(.secondary)
                        Text("No Audio Loaded").font(.title).foregroundColor(.secondary)
                        Text("Select a folder in the library to begin playback.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(player.tracks) { track in
                                TrackRow(track: track) { newVol in
                                    player.setVolume(newVol, index: track.id)
                                }
                                Divider()
                            }
                        }
                        .padding(.top, 10)
                    }
                }
                
                // Footer (Errors only)
                if player.showError {
                    HStack {
                        Spacer()
                        Text(player.errorMessage).foregroundColor(.red).fontWeight(.bold).font(.caption)
                        Spacer()
                    }
                    .padding(8)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .transition(.move(edge: .bottom))
                }
            }
        }
        .sheet(isPresented: $showPasswordPrompt) {
            PasswordPromptView(isPresented: $showPasswordPrompt, onSuccess: {
                player.loadLibraryFolder()
            })
        }
        .onAppear { player.refreshHardwareState() }
    }
}
