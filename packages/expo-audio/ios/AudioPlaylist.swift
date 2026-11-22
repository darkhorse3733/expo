import ExpoModulesCore
import AVFoundation
import Combine

@SharedObject
public final class AudioPlaylist: SharedRef<AVQueuePlayer>, Playable, LockScreenPlayable {
  @JS
  let id = UUID().uuidString
  private let interval: Double
  private(set) var currentRate: Float = 1.0
  var isActiveForLockScreen = false
  var metadata: Metadata?
  var lockScreenOptions: LockScreenOptions?

  var loopMode: LoopMode = .none
  var wasPlaying = false

  private(set) var sources: [AudioSource] = []

  private var playerItems: [AVPlayerItem?] = []
  private var previousTrackIndex = 0

  var currentTrackIndex: Int {
    guard let current = ref.currentItem,
          let index = playerItems.firstIndex(where: { $0 === current }) else {
      return min(max(previousTrackIndex, 0), max(sources.count - 1, 0))
    }
    return index
  }

  func getSourceInfo() -> [AudioSource] {
    return sources
  }

  private var timeToken: Any?
  private var cancellables = Set<AnyCancellable>()
  private var endObserver: NSObjectProtocol?

  weak var owningRegistry: AudioComponentRegistry?

  var duration: Double {
    let d = ref.currentItem?.duration.seconds ?? 0.0
    return d.isNaN ? 0.0 : d
  }

  var currentTime: Double {
    ref.currentItem?.currentTime().seconds ?? 0.0
  }

  var isLoaded: Bool {
    ref.currentItem?.status == .readyToPlay
  }

  var isPlaying: Bool {
    ref.timeControlStatus == .playing
  }

  var isLive: Bool {
    ref.currentItem?.duration.isIndefinite ?? false
  }

  var lockScreenPlayer: AVPlayer {
    ref
  }

  var supportsNextTrack: Bool {
    true
  }

  var supportsPreviousTrack: Bool {
    true
  }

  var isBuffering: Bool {
    ref.isBuffering(isPlaying: isPlaying)
  }

  var trackCount: Int {
    sources.count
  }

  init(_ ref: AVQueuePlayer, sources: [AudioSource], items: [AVPlayerItem?], interval: Double, loopMode: LoopMode) {
    self.interval = interval
    self.loopMode = loopMode
    self.sources = sources
    self.playerItems = items
    super.init(ref)

    ref.actionAtItemEnd = loopMode == .single ? .pause : .advance
    setupPublisher()
    addPlaybackEndNotification()
  }

  @Event("playlistStatusUpdate")
  var onPlaylistStatusUpdate: (AudioPlaylistStatus) -> Void

  @Event("trackChanged")
  var onTrackChanged: (TrackChangedEvent) -> Void

  @JS("currentIndex")
  var currentIndexFromJS: Int {
    currentTrackIndex
  }

  @JS("trackCount")
  var trackCountFromJS: Int {
    trackCount
  }

  @JS("sources")
  var sourcesFromJS: [AudioSource] {
    getSourceInfo()
  }

  @JS("playing")
  var playingFromJS: Bool {
    isPlaying
  }

  @JS("isLoaded")
  var isLoadedFromJS: Bool {
    isLoaded
  }

  @JS("isBuffering")
  var isBufferingFromJS: Bool {
    isBuffering
  }

  @JS("currentTime")
  var currentTimeFromJS: Double {
    currentTime
  }

  @JS("duration")
  var durationFromJS: Double {
    duration
  }

  @JS("muted")
  var mutedFromJS: Bool {
    get { ref.isMuted }
    set { ref.isMuted = newValue }
  }

  @JS("volume")
  var volumeFromJS: Float {
    get { ref.volume }
    set { ref.volume = newValue }
  }

  @JS("playbackRate")
  var playbackRateFromJS: Float {
    get { isPlaying ? ref.rate : currentRate }
    set { setPlaybackRate(newValue) }
  }

  @JS("loop")
  var loopFromJS: LoopMode {
    get { loopMode }
    set { setLoopMode(newValue) }
  }

  @JS("currentStatus")
  var currentStatusFromJS: AudioPlaylistStatus {
    currentStatus()
  }

  @JS("isActiveForLockScreen")
  var isActiveForLockScreenFromJS: Bool {
    isActiveForLockScreen
  }

  @JS("pause")
  func pauseFromJS() {
    pause()
  }

  @JS("next")
  func nextFromJS() {
    next()
  }

  @JS("previous")
  func previousFromJS() {
    previous()
  }

  @JS("skipTo")
  func skipToFromJS(_ index: Int) {
    skipTo(index: index)
  }

  @JS("seekTo", .concurrent)
  func seekToFromJS(_ seconds: Double) async {
    await seekTo(seconds: seconds)
  }

  @JS("add")
  func addFromJS(_ source: AudioSource) {
    add(source: source)
  }

  @JS("insert")
  func insertFromJS(_ source: AudioSource, _ index: Int) {
    insert(source: source, at: index)
  }

  @JS("remove")
  func removeFromJS(_ index: Int) {
    remove(at: index)
  }

  @JS("clear")
  func clearFromJS() {
    clear()
  }

  @JS("setActiveForLockScreen")
  func setActiveForLockScreenFromJS(_ active: Bool, _ metadata: Metadata?, _ options: LockScreenOptions?) {
    setActiveForLockScreen(active, metadata: metadata, options: options)
  }

  @JS("updateLockScreenMetadata")
  func updateLockScreenMetadataFromJS(_ metadata: Metadata?) {
    if isActiveForLockScreen {
      self.metadata = metadata
      MediaController.shared.refreshActivePlayable(self, options: lockScreenOptions)
    }
  }

  @JS("clearLockScreenControls")
  func clearLockScreenControlsFromJS() {
    if isActiveForLockScreen {
      metadata = nil
      lockScreenOptions = nil
      isActiveForLockScreen = false
      MediaController.shared.setActivePlayable(nil)
    }
  }

  func play(at rate: Float) {
    registerTimeObserver()
    ref.playImmediately(atRate: rate)

    if isActiveForLockScreen {
      MediaController.shared.updateNowPlayingInfo(for: self)
    }
  }

  func pause() {
    ref.pause()

    if isActiveForLockScreen {
      MediaController.shared.updateNowPlayingInfo(for: self)
    }
  }

  func next() {
    if currentTrackIndex < sources.count - 1 {
      ref.advanceToNextItem()
    } else if loopMode == .all && !sources.isEmpty {
      skipTo(index: 0)
    }
  }

  func previous() {
    if currentTrackIndex > 0 {
      let wasPlaying = isPlaying
      rebuildPlaylist(startingAt: currentTrackIndex - 1)
      if wasPlaying {
        play(at: currentRate)
      }
    } else if loopMode == .all && !sources.isEmpty {
      skipTo(index: sources.count - 1)
    }
  }

  func nextTrack() {
    next()
  }

  func previousTrack() {
    previous()
  }

  func skipTo(index: Int) {
    guard validIndex(index) else {
      return
    }

    let wasPlaying = isPlaying
    rebuildPlaylist(startingAt: index)

    if wasPlaying {
      play(at: currentRate)
    }
  }

  func seekTo(seconds: Double) async {
    let time = CMTime(seconds: seconds, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      ref.seek(to: time) { [weak self] _ in
        if let self {
          let currentTime = self.currentTime
          self.updateStatus { $0.currentTime = currentTime }
        }
        continuation.resume()
      }
    }
  }

  func add(source: AudioSource) {
    sources.append(source)
    let item = AudioUtils.createAVPlayerItem(from: source)
    if let item {
      ref.insert(item, after: nil)
    }
    playerItems.append(item)
    updateStatus()
  }

  func insert(source: AudioSource, at index: Int) {
    guard index >= 0 && index <= sources.count else {
      return
    }

    let wasPlaying = isPlaying
    let resumeIndex: Int
    if ref.currentItem != nil {
      resumeIndex = index <= currentTrackIndex ? currentTrackIndex + 1 : currentTrackIndex
    } else {
      resumeIndex = index
    }
    sources.insert(source, at: index)

    previousTrackIndex = resumeIndex
    rebuildPlaylist(startingAt: resumeIndex)
    if wasPlaying {
      play(at: currentRate)
    }
    updateStatus()
  }

  func remove(at index: Int) {
    guard validIndex(index) else {
      return
    }

    let wasPlaying = isPlaying
    let current = currentTrackIndex
    sources.remove(at: index)

    if index == current {
      let resumeIndex = min(current, max(0, sources.count - 1))
      previousTrackIndex = resumeIndex
      rebuildPlaylist(startingAt: resumeIndex)
      if wasPlaying && !sources.isEmpty {
        play(at: currentRate)
      }
    } else if index < current {
      let resumeIndex = current - 1
      previousTrackIndex = resumeIndex
      rebuildPlaylist(startingAt: resumeIndex)
      if wasPlaying {
        play(at: currentRate)
      }
    } else if index < playerItems.count {
      if let item = playerItems[index] {
        ref.remove(item)
      }
      playerItems.remove(at: index)
    }

    updateStatus()
  }

  func clear() {
    ref.pause()
    ref.removeAllItems()
    sources.removeAll()
    playerItems.removeAll()
    previousTrackIndex = 0

    updateStatus {
      $0.trackCount = 0
      $0.currentIndex = 0
      $0.playing = false
    }
  }

  func setLoopMode(_ mode: LoopMode) {
    loopMode = mode
    ref.actionAtItemEnd = mode == .single ? .pause : .advance
    updateStatus()
  }

  func setPlaybackRate(_ rate: Float) {
    let boundedRate = max(0.1, min(rate, 2.0))
    currentRate = boundedRate
    if isPlaying {
      ref.rate = boundedRate
    }
  }

  func setActiveForLockScreen(_ active: Bool = true, metadata: Metadata? = nil, options: LockScreenOptions?) {
    self.metadata = metadata
    self.isActiveForLockScreen = active
    self.lockScreenOptions = active ? options : nil
    if active {
      MediaController.shared.setActivePlayable(self, options: options)
    } else {
      MediaController.shared.setActivePlayable(nil)
    }
  }

  func currentStatus() -> AudioPlaylistStatus {
    return AudioPlaylistStatus(
      id: id,
      currentIndex: currentTrackIndex,
      trackCount: trackCount,
      currentTime: currentTime,
      duration: duration,
      playing: isPlaying,
      isBuffering: isBuffering,
      isLoaded: isLoaded,
      playbackRate: isPlaying ? ref.rate : currentRate,
      muted: ref.isMuted,
      volume: ref.volume,
      loop: loopMode,
      didJustFinish: false
    )
  }

  func updateStatus(_ modify: (inout AudioPlaylistStatus) -> Void = { _ in }) {
    var status = currentStatus()
    modify(&status)
    onPlaylistStatusUpdate(status)

    if isActiveForLockScreen {
      MediaController.shared.updateNowPlayingInfo(for: self)
    }
  }

  private func validIndex(_ index: Int) -> Bool {
    return index >= 0 && index < sources.count
  }

  private func emitTrackChanged(previousIndex: Int, currentIndex: Int) {
    onTrackChanged(TrackChangedEvent(previousIndex: previousIndex, currentIndex: currentIndex))
    updateStatus()
  }

  private func rebuildPlaylist(startingAt index: Int) {
    var items = [AVPlayerItem?](repeating: nil, count: sources.count)
    for i in index..<sources.count {
      items[i] = AudioUtils.createAVPlayerItem(from: sources[i])
    }
    playerItems = items

    ref.removeAllItems()
    for i in index..<sources.count {
      if let item = items[i] {
        ref.insert(item, after: nil)
      }
    }
  }

  private func setupPublisher() {
    ref.publisher(for: \.currentItem?.status)
      .sink { [weak self] status in
        guard let self, let status else {
          return
        }
        if status == .readyToPlay {
          self.updateStatus { $0.isLoaded = true }
        }
      }
      .store(in: &cancellables)

    ref.publisher(for: \.currentItem)
      .sink { [weak self] _ in
        guard let self else {
          return
        }
        let index = self.currentTrackIndex
        if index != self.previousTrackIndex {
          self.emitTrackChanged(previousIndex: self.previousTrackIndex, currentIndex: index)
          self.previousTrackIndex = index
        } else {
          self.updateStatus()
        }
      }
      .store(in: &cancellables)
  }

  private func addPlaybackEndNotification() {
    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: nil,
      queue: nil
    ) { [weak self] notification in
      guard let self,
            let item = notification.object as? AVPlayerItem,
            let finishedIndex = self.playerItems.firstIndex(where: { $0 === item }) else {
        return
      }

      let isLastTrack = finishedIndex >= self.sources.count - 1

      switch self.loopMode {
      case .single:
        self.ref.seek(to: .zero)
        self.play(at: self.currentRate)

      case .all:
        if isLastTrack {
          self.skipTo(index: 0)
          self.play(at: self.currentRate)
        }

      case .none:
        if isLastTrack {
          self.updateStatus {
            $0.playing = false
            $0.didJustFinish = true
          }
        }
      }
    }
  }

  private func registerTimeObserver() {
    if let timeToken {
      ref.removeTimeObserver(timeToken)
    }

    let updateInterval = interval / 1000
    let interval = CMTime(seconds: updateInterval, preferredTimescale: CMTimeScale(NSEC_PER_SEC))

    timeToken = ref.addPeriodicTimeObserver(forInterval: interval, queue: nil) { [weak self] time in
      guard let self else {
        return
      }
      self.updateStatus { $0.currentTime = time.seconds }
    }
  }

  var volume: Float {
    get { ref.volume }
    set { ref.volume = newValue }
  }

  func resumePlayback() {
    play(at: currentRate)
  }

  public override func sharedObjectWillRelease() {
    ref.currentItem?.cancelPendingSeeks()
    owningRegistry?.remove(self)
    cancellables.removeAll()

    if let timeToken {
      ref.removeTimeObserver(timeToken)
    }

    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
    }

    if isActiveForLockScreen {
      MediaController.shared.setActivePlayable(nil)
    }

    ref.pause()
    ref.removeAllItems()
  }
}
