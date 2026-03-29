//
//  NormalPlayer.swift
//  Sora · Media Hub
//
//  Created by Francesco on 27/11/24.
//

import AVKit
#if os(iOS)
import MediaPlayer
#endif

#if os(iOS)
struct SoftSubtitleTrack {
    let title: String
    let url: String
    let proxyURL: URL
}
#endif

class NormalPlayer: AVPlayerViewController, AVPlayerViewControllerDelegate, UIAdaptivePresentationControllerDelegate, UIGestureRecognizerDelegate {
    private var originalRate: Float = 1.0
    private var timeObserverToken: Any?
    private var statusObservation: NSKeyValueObservation?
    private var stalledObserver: NSObjectProtocol?
    private var timeControlObservation: NSKeyValueObservation?
    private var bufferEmptyObservation: NSKeyValueObservation?
    private var likelyToKeepUpObservation: NSKeyValueObservation?
    private var bufferFullObservation: NSKeyValueObservation?
    private var readyObservation: NSKeyValueObservation?
    private var didLogReady = false
    private var pendingSeekSeconds: Double?
    private var miruroStallFallbackWorkItem: DispatchWorkItem?
    private var miruroStallAnchorSeconds: Double?
    private var miruroFallbackTriggered = false
    var mediaInfo: MediaInfo?
#if os(iOS)
    // Soft-subtitle overlay for cases where iOS system subtitles UI collapses tracks
    // and/or we need explicit timing offset control.
    var softSubtitleTracks: [SoftSubtitleTrack] = [] {
        didSet {
            subtitleEntriesCache.removeAll()
            if softSubtitleTracks.isEmpty {
                selectedSoftSubtitleIndex = nil
                softSubtitlesEnabled = false
            } else {
                // Default to the first track so subtitles visibly "work" immediately.
                selectedSoftSubtitleIndex = 0
                softSubtitlesEnabled = true
            }
            lastCueIndex = nil
            subtitleHiddenUpdate()
            subtitleSettingsButton?.isHidden = softSubtitleTracks.isEmpty
            if !softSubtitleTracks.isEmpty {
                Task { await loadSubtitlesIfNeeded(trackIndex: 0) }
            }
        }
    }
    private var subtitleEntriesCache: [Int: [SubtitleEntry]] = [:]
    private var softSubtitlesEnabled: Bool = false
    private var selectedSoftSubtitleIndex: Int?
    private var softSubtitleOffsetSeconds: Double = UserDefaults.standard.double(forKey: "softSubtitleOffsetSeconds")
    private var lastCueIndex: Int?
    private var subtitleTimeObserverToken: Any?

    private var softSubtitleContainerView: UIView?
    private var softSubtitleLabel: UILabel?
    private var subtitleSettingsButton: UIButton?
#endif
    /// When true and the first load fails, dismiss and notify so Miruro can try the next server.
    var miruroTryNextServerOnFailure = false
    /// True when this is the last Miruro server in the fallback chain (show “all failed” on error).
    var miruroLastServerAttempt = false
    
#if os(iOS)
    private var holdGesture: UILongPressGestureRecognizer?
    private var volumeBrightnessTouchOverlay: UIView?
    private var volumeBrightnessPanGesture: UIPanGestureRecognizer?
    private var didSetupOverlay = false
    private var volumeSlider: UISlider?
    private var brightnessOverlayView: UIView?
    private var volumeOverlayView: UIView?
    private var volumeBrightnessHideWorkItem: DispatchWorkItem?
    private var volumeBrightnessInitialBrightness: CGFloat = 0
    private var volumeBrightnessInitialVolume: Float = 0
    private var volumeBrightnessAccumulatedDelta: CGFloat = 0
    private var skipForwardDoubleTap: UITapGestureRecognizer?
    private var skipBackwardDoubleTap: UITapGestureRecognizer?
    private var controlsPassThroughWorkItem: DispatchWorkItem?
#endif

    override var player: AVPlayer? {
        didSet {
            statusObservation?.invalidate()
            statusObservation = nil
            timeControlObservation?.invalidate()
            timeControlObservation = nil
            bufferEmptyObservation?.invalidate()
            bufferEmptyObservation = nil
            likelyToKeepUpObservation?.invalidate()
            likelyToKeepUpObservation = nil
            bufferFullObservation?.invalidate()
            bufferFullObservation = nil
            readyObservation?.invalidate()
            readyObservation = nil
            didLogReady = false
            observePlaybackFailure()
            observePlaybackDebug()
#if os(iOS)
            startSoftSubtitleTimeObserverIfNeeded()
            subtitleHiddenUpdate()
#endif
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
#if os(iOS)
        isModalInPresentation = true
        showsPlaybackControls = true
        view.clipsToBounds = true
        contentOverlayView?.clipsToBounds = true
        setupPictureInPictureHandling()
        // Overlay added in viewDidAppear so it sits above system controls and avoids doubled/ghosted UI.
#endif
        if let info = mediaInfo {
            setupProgressTracking(for: info)
        }
        setupAudioSession()

        stalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            let err = self.player?.currentItem?.error
            Logger.shared.log("Playback stalled. Item error: \(err?.localizedDescription ?? "none")", type: "Error")
            if let e = err as NSError? {
                Logger.shared.log("Stall error domain: \(e.domain) code: \(e.code)", type: "Error")
            }
            self.scheduleMiruroFallbackIfStillStalled(reason: "stalled notification")
        }
    }
    
#if os(iOS)
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        presentationController?.delegate = self
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !didSetupOverlay {
            didSetupOverlay = true
            setupTouchOverlayAndGestures()
        }
#if os(iOS)
        setupSoftSubtitleOverlayIfNeeded()
        subtitleHiddenUpdate()
#endif
    }
    
    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        false
    }
#endif
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        player?.pause()
        
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        bufferEmptyObservation?.invalidate()
        bufferEmptyObservation = nil
        likelyToKeepUpObservation?.invalidate()
        likelyToKeepUpObservation = nil
        bufferFullObservation?.invalidate()
        bufferFullObservation = nil
        readyObservation?.invalidate()
        readyObservation = nil
        miruroStallFallbackWorkItem?.cancel()
        miruroStallFallbackWorkItem = nil
        StreamProxyServer.shared.stop()

#if os(iOS)
        if let token = subtitleTimeObserverToken {
            player?.removeTimeObserver(token)
            subtitleTimeObserverToken = nil
        }
#endif
    }
    
    deinit {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
        }
        statusObservation?.invalidate()
        timeControlObservation?.invalidate()
        bufferEmptyObservation?.invalidate()
        likelyToKeepUpObservation?.invalidate()
        bufferFullObservation?.invalidate()
        readyObservation?.invalidate()
        miruroStallFallbackWorkItem?.cancel()
        if let stalledObserver { NotificationCenter.default.removeObserver(stalledObserver) }
    }
    
    private func observePlaybackFailure() {
        statusObservation?.invalidate()
        statusObservation = nil
        guard let item = player?.currentItem else { return }
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] playerItem, _ in
            guard playerItem.status == .failed else { return }
            let err = playerItem.error
            Logger.shared.log("Playback failed: \(err?.localizedDescription ?? "unknown")", type: "Error")
            if let e = err as NSError? {
                Logger.shared.log("Domain: \(e.domain) code: \(e.code)", type: "Error")
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.miruroStallFallbackWorkItem?.cancel()
                self.miruroStallFallbackWorkItem = nil
                if self.miruroTryNextServerOnFailure {
                    self.miruroTryNextServerOnFailure = false
                    self.miruroFallbackTriggered = true
                    Logger.shared.log("Miruro: playback failed, will try next server", type: "Stream")
                    self.dismiss(animated: true) {
                        NotificationCenter.default.post(name: .noirMiruroTryNextServer, object: nil)
                    }
                } else if self.miruroLastServerAttempt {
                    self.miruroLastServerAttempt = false
                    Logger.shared.log("Miruro: last server failed", type: "Stream")
                    let alert = UIAlertController(
                        title: "Playback Error",
                        message: "All video servers failed for this source.",
                        preferredStyle: .alert
                    )
                    alert.addAction(UIAlertAction(title: "Close", style: .default) { [weak self] _ in
                        self?.dismiss(animated: true)
                    })
                    self.present(alert, animated: true)
                } else {
                    self.showPlaybackErrorAlert(error: err)
                }
            }
        }
    }

    private func observePlaybackDebug() {
        guard let player = player, let item = player.currentItem else { return }

        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            guard let self else { return }
            let s: String
            switch p.timeControlStatus {
            case .paused: s = "paused"
            case .waitingToPlayAtSpecifiedRate: s = "waiting"
            case .playing: s = "playing"
            @unknown default: s = "unknown"
            }
            Logger.shared.log("NormalPlayer timeControlStatus=\(s) rate=\(p.rate)", type: "Stream")

            switch p.timeControlStatus {
            case .waitingToPlayAtSpecifiedRate:
                // Guardrail: if startup remains stuck in waiting for a long time with no progress,
                // trigger fallback. Keep delay generous to avoid premature server cycling.
                self.scheduleMiruroFallbackIfStillStalled(reason: "prolonged startup waiting", delaySeconds: 30.0)
            case .playing:
                self.miruroStallFallbackWorkItem?.cancel()
                self.miruroStallFallbackWorkItem = nil
                self.miruroStallAnchorSeconds = nil
            case .paused:
                // Keep any pending check alive; if it is user pause, the check self-cancels by progress movement/state.
                break
            @unknown default:
                break
            }
        }

        bufferEmptyObservation = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { _, _ in
            Logger.shared.log("AVPlayerItem bufferEmpty=YES", type: "Stream")
        }
        likelyToKeepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { playerItem, _ in
            Logger.shared.log("AVPlayerItem likelyToKeepUp=\(playerItem.isPlaybackLikelyToKeepUp ? "YES" : "NO")", type: "Stream")
        }
        bufferFullObservation = item.observe(\.isPlaybackBufferFull, options: [.new]) { playerItem, _ in
            Logger.shared.log("AVPlayerItem bufferFull=\(playerItem.isPlaybackBufferFull ? "YES" : "NO")", type: "Stream")
        }

        // Log all status transitions + perform any pending seek safely.
        readyObservation = item.observe(\.status, options: [.new]) { [weak self] playerItem, _ in
            guard let self = self else { return }
            let statusString: String
            switch playerItem.status {
            case .unknown: statusString = "unknown"
            case .readyToPlay: statusString = "readyToPlay"
            case .failed: statusString = "failed"
            @unknown default: statusString = "unknown"
            }
            Logger.shared.log("AVPlayerItem status=\(statusString)", type: "Stream")
            guard playerItem.status == .readyToPlay, !self.didLogReady else { return }
            self.didLogReady = true
            let durationSeconds = CMTimeGetSeconds(playerItem.duration)
            Logger.shared.log("AVPlayerItem readyToPlay. duration=\(durationSeconds)s", type: "Stream")
            if let seconds = self.pendingSeekSeconds, seconds > 0 {
                self.pendingSeekSeconds = nil
                let seekSeconds: Double
                if durationSeconds.isFinite, durationSeconds > 1 {
                    // Avoid invalid end-of-media seeks from stale progress snapshots.
                    let maxSafeSeek = max(0, durationSeconds - 1.0)
                    seekSeconds = min(seconds, maxSafeSeek)
                } else {
                    seekSeconds = max(0, seconds)
                }
                if seekSeconds <= 0 {
                    Logger.shared.log("Skipped deferred seek (requested=\(Int(seconds))s, duration=\(Int(durationSeconds))s)", type: "Progress")
                    return
                }
                let t = CMTime(seconds: seekSeconds, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
                player.seek(to: t) { finished in
                    Logger.shared.log("Deferred seek to \(Int(seekSeconds))s (requested \(Int(seconds))s) finished=\(finished ? "YES" : "NO")", type: "Progress")
                }
            }
        }
    }
    
    private func scheduleMiruroFallbackIfStillStalled(reason: String, delaySeconds: Double = 6.0) {
        guard miruroTryNextServerOnFailure || miruroLastServerAttempt else { return }
        guard miruroFallbackTriggered == false else { return }
        guard let player, player.currentItem != nil else { return }

        if player.timeControlStatus == .playing {
            miruroStallFallbackWorkItem?.cancel()
            miruroStallFallbackWorkItem = nil
            miruroStallAnchorSeconds = nil
            return
        }

        let anchor = CMTimeGetSeconds(player.currentTime())
        if anchor.isFinite {
            miruroStallAnchorSeconds = anchor
        }

        miruroStallFallbackWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let player = self.player, let item = player.currentItem else { return }
            guard player.timeControlStatus != .playing else { return }

            let now = CMTimeGetSeconds(player.currentTime())
            let old = self.miruroStallAnchorSeconds ?? now
            let progressed = (now.isFinite && old.isFinite) ? abs(now - old) : 0

            let stillStalled = progressed < 0.5 && (item.isPlaybackBufferEmpty || item.isPlaybackLikelyToKeepUp == false)
            guard stillStalled else { return }

            if self.miruroTryNextServerOnFailure {
                self.miruroTryNextServerOnFailure = false
                self.miruroFallbackTriggered = true
                Logger.shared.log("Miruro: \(reason), trying next server", type: "Stream")
                self.dismiss(animated: true) {
                    NotificationCenter.default.post(name: .noirMiruroTryNextServer, object: nil)
                }
            } else if self.miruroLastServerAttempt {
                self.miruroLastServerAttempt = false
                Logger.shared.log("Miruro: \(reason) on last server", type: "Stream")
                let alert = UIAlertController(
                    title: "Playback Error",
                    message: "All video servers failed for this source.",
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "Close", style: .default) { [weak self] _ in
                    self?.dismiss(animated: true)
                })
                self.present(alert, animated: true)
            }
        }
        miruroStallFallbackWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds, execute: work)
    }

    private func showPlaybackErrorAlert(error: Error?) {
        let message = error?.localizedDescription ?? "Playback failed."
        let alert = UIAlertController(title: "Playback Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Close", style: .default) { [weak self] _ in
            self?.dismiss(animated: true)
        })
        present(alert, animated: true)
    }
    
#if os(iOS)
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        if UserDefaults.standard.bool(forKey: "alwaysLandscape") {
            return .landscape
        } else {
            return .all
        }
    }
    
    private func setupTouchOverlayAndGestures() {
        guard let container = contentOverlayView else { return }
        let overlay = UIView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.backgroundColor = .clear
        overlay.isUserInteractionEnabled = true
        container.addSubview(overlay)
        // Leave bottom ~100pt clear so system menu (Playback Speed, Subtitles) is not covered — avoids doubled menu UI.
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -100)
        ])
        volumeBrightnessTouchOverlay = overlay
        
        setupVolumeBrightnessOverlays()
        setupVolumeSlider()
        
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleVolumeBrightnessPan(_:)))
        pan.delegate = self
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        overlay.addGestureRecognizer(pan)
        volumeBrightnessPanGesture = pan
        
        holdGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleHoldGesture(_:)))
        holdGesture?.minimumPressDuration = 0.5
        holdGesture?.delaysTouchesBegan = false
        holdGesture?.delegate = self
        if let holdGesture = holdGesture {
            overlay.addGestureRecognizer(holdGesture)
        }

        let forwardDoubleTap = UITapGestureRecognizer(target: self, action: #selector(handleSkipForwardDoubleTap(_:)))
        forwardDoubleTap.numberOfTapsRequired = 2
        forwardDoubleTap.delegate = self
        overlay.addGestureRecognizer(forwardDoubleTap)
        skipForwardDoubleTap = forwardDoubleTap

        let backwardDoubleTap = UITapGestureRecognizer(target: self, action: #selector(handleSkipBackwardDoubleTap(_:)))
        backwardDoubleTap.numberOfTapsRequired = 2
        backwardDoubleTap.delegate = self
        overlay.addGestureRecognizer(backwardDoubleTap)
        skipBackwardDoubleTap = backwardDoubleTap

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleOverlaySingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.delegate = self
        singleTap.require(toFail: forwardDoubleTap)
        singleTap.require(toFail: backwardDoubleTap)
        overlay.addGestureRecognizer(singleTap)
    }
    
    private func setupVolumeSlider() {
        let volumeView = MPVolumeView(frame: .zero)
        if #unavailable(iOS 13.0) {
            volumeView.showsRouteButton = false
        }
        volumeView.alpha = 0.01
        volumeView.isUserInteractionEnabled = false
        view.addSubview(volumeView)
        volumeView.frame = CGRect(x: -2000, y: -2000, width: 1, height: 1)
        for subview in volumeView.subviews {
            if let slider = subview as? UISlider {
                volumeSlider = slider
                break
            }
        }
    }
    
    private func setupVolumeBrightnessOverlays() {
        let overlayHeight: CGFloat = 120
        let overlayWidth: CGFloat = 44
        let cornerRadius: CGFloat = 12
        
        let makeTrackView: () -> (container: UIView, fill: UIView) = {
            let container = UIView()
            container.translatesAutoresizingMaskIntoConstraints = false
            container.backgroundColor = UIColor.white.withAlphaComponent(0.25)
            container.layer.cornerRadius = 4
            container.clipsToBounds = true
            let fill = UIView()
            fill.translatesAutoresizingMaskIntoConstraints = false
            fill.backgroundColor = .white
            fill.layer.cornerRadius = 4
            container.addSubview(fill)
            NSLayoutConstraint.activate([
                fill.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                fill.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                fill.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                fill.heightAnchor.constraint(equalTo: container.heightAnchor, multiplier: 0.5)
            ])
            return (container, fill)
        }
        
        let brightnessTrack = makeTrackView()
        let brightnessContainer = UIView()
        brightnessContainer.translatesAutoresizingMaskIntoConstraints = false
        brightnessContainer.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        brightnessContainer.layer.cornerRadius = cornerRadius
        brightnessContainer.alpha = 0
        brightnessContainer.isUserInteractionEnabled = false
        let brightnessIcon = UIImageView(image: UIImage(systemName: "sun.max.fill"))
        brightnessIcon.translatesAutoresizingMaskIntoConstraints = false
        brightnessIcon.tintColor = .white
        brightnessIcon.contentMode = .scaleAspectFit
        brightnessContainer.addSubview(brightnessIcon)
        brightnessContainer.addSubview(brightnessTrack.container)
        brightnessTrack.fill.tag = 1001
        NSLayoutConstraint.activate([
            brightnessIcon.topAnchor.constraint(equalTo: brightnessContainer.topAnchor, constant: 10),
            brightnessIcon.centerXAnchor.constraint(equalTo: brightnessContainer.centerXAnchor),
            brightnessIcon.widthAnchor.constraint(equalToConstant: 22),
            brightnessIcon.heightAnchor.constraint(equalToConstant: 22),
            brightnessTrack.container.centerXAnchor.constraint(equalTo: brightnessContainer.centerXAnchor),
            brightnessTrack.container.topAnchor.constraint(equalTo: brightnessIcon.bottomAnchor, constant: 8),
            brightnessTrack.container.bottomAnchor.constraint(equalTo: brightnessContainer.bottomAnchor, constant: -10),
            brightnessTrack.container.widthAnchor.constraint(equalToConstant: 6)
        ])
        (contentOverlayView ?? view).addSubview(brightnessContainer)
        brightnessOverlayView = brightnessContainer
        
        let volumeTrack = makeTrackView()
        let volumeContainer = UIView()
        volumeContainer.translatesAutoresizingMaskIntoConstraints = false
        volumeContainer.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        volumeContainer.layer.cornerRadius = cornerRadius
        volumeContainer.alpha = 0
        volumeContainer.isUserInteractionEnabled = false
        let volumeIcon = UIImageView(image: UIImage(systemName: "speaker.wave.2.fill"))
        volumeIcon.translatesAutoresizingMaskIntoConstraints = false
        volumeIcon.tintColor = .white
        volumeIcon.contentMode = .scaleAspectFit
        volumeContainer.addSubview(volumeIcon)
        volumeContainer.addSubview(volumeTrack.container)
        volumeTrack.fill.tag = 1002
        NSLayoutConstraint.activate([
            volumeIcon.topAnchor.constraint(equalTo: volumeContainer.topAnchor, constant: 10),
            volumeIcon.centerXAnchor.constraint(equalTo: volumeContainer.centerXAnchor),
            volumeIcon.widthAnchor.constraint(equalToConstant: 22),
            volumeIcon.heightAnchor.constraint(equalToConstant: 22),
            volumeTrack.container.centerXAnchor.constraint(equalTo: volumeContainer.centerXAnchor),
            volumeTrack.container.topAnchor.constraint(equalTo: volumeIcon.bottomAnchor, constant: 8),
            volumeTrack.container.bottomAnchor.constraint(equalTo: volumeContainer.bottomAnchor, constant: -10),
            volumeTrack.container.widthAnchor.constraint(equalToConstant: 6)
        ])
        (contentOverlayView ?? view).addSubview(volumeContainer)
        volumeOverlayView = volumeContainer
        
        let anchorView: UIView = contentOverlayView ?? view
        NSLayoutConstraint.activate([
            brightnessContainer.leadingAnchor.constraint(equalTo: anchorView.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            brightnessContainer.centerYAnchor.constraint(equalTo: anchorView.centerYAnchor),
            brightnessContainer.widthAnchor.constraint(equalToConstant: overlayWidth),
            brightnessContainer.heightAnchor.constraint(equalToConstant: overlayHeight),
            volumeContainer.trailingAnchor.constraint(equalTo: anchorView.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            volumeContainer.centerYAnchor.constraint(equalTo: anchorView.centerYAnchor),
            volumeContainer.widthAnchor.constraint(equalToConstant: overlayWidth),
            volumeContainer.heightAnchor.constraint(equalToConstant: overlayHeight)
        ])
    }
    
    private var gestureContainerView: UIView? { contentOverlayView ?? view }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let container = gestureContainerView else { return true }
        let loc = gestureRecognizer.location(in: container)
        let midX = container.bounds.midX
        let isInLeftHalf = loc.x < midX
        let isInRightHalf = loc.x >= midX

        if gestureRecognizer === volumeBrightnessPanGesture {
            return isInLeftHalf || isInRightHalf
        }
        if gestureRecognizer === skipForwardDoubleTap {
            return isInRightHalf
        }
        if gestureRecognizer === skipBackwardDoubleTap {
            return isInLeftHalf
        }
        return true
    }
    
    @objc private func handleVolumeBrightnessPan(_ gesture: UIPanGestureRecognizer) {
        guard let container = gestureContainerView else { return }
        let location = gesture.location(in: container)
        let isLeftSide = location.x < container.bounds.midX
        let translation = gesture.translation(in: container)
        switch gesture.state {
        case .began:
            volumeBrightnessAccumulatedDelta = 0
            volumeBrightnessInitialBrightness = UIScreen.main.brightness
            if let slider = volumeSlider {
                volumeBrightnessInitialVolume = slider.value
            }
            volumeBrightnessHideWorkItem?.cancel()
            if isLeftSide {
                showBrightnessOverlay(value: volumeBrightnessInitialBrightness)
            } else {
                showVolumeOverlay(value: volumeBrightnessInitialVolume)
            }
        case .changed:
            let sensitivity: CGFloat = 0.008
            volumeBrightnessAccumulatedDelta += translation.y
            gesture.setTranslation(.zero, in: container)
            if isLeftSide {
                var newBrightness = volumeBrightnessInitialBrightness - volumeBrightnessAccumulatedDelta * sensitivity
                newBrightness = max(0, min(1, newBrightness))
                UIScreen.main.brightness = newBrightness
                showBrightnessOverlay(value: newBrightness)
            } else {
                guard let slider = volumeSlider else { return }
                let delta = Float(-volumeBrightnessAccumulatedDelta * sensitivity)
                var newVolume = volumeBrightnessInitialVolume + delta
                newVolume = max(0, min(1, newVolume))
                slider.value = newVolume
                showVolumeOverlay(value: newVolume)
            }
        case .ended, .cancelled:
            scheduleHideVolumeBrightnessOverlays()
        default:
            break
        }
    }

    @objc private func handleSkipForwardDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let player = player else { return }
        let currentTime = player.currentTime()
        let delta = CMTime(seconds: 10, preferredTimescale: currentTime.timescale)
        var target = CMTimeAdd(currentTime, delta)
        if let duration = player.currentItem?.duration, duration.isNumeric {
            if target > duration {
                target = duration
            }
        }
        player.seek(to: target)
    }

    @objc private func handleSkipBackwardDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let player = player else { return }
        let currentTime = player.currentTime()
        let delta = CMTime(seconds: 10, preferredTimescale: currentTime.timescale)
        var target = CMTimeSubtract(currentTime, delta)
        let zero = CMTime(seconds: 0, preferredTimescale: currentTime.timescale)
        if target < zero {
            target = zero
        }
        player.seek(to: target)
    }
    
    private func showBrightnessOverlay(value: CGFloat) {
        brightnessOverlayView?.alpha = 1
        volumeOverlayView?.alpha = 0
        guard let fill = brightnessOverlayView?.viewWithTag(1001), let container = fill.superview else { return }
        let multiplier = max(0.05, min(1, value))
        fill.constraints.first(where: { $0.firstAttribute == .height })?.isActive = false
        NSLayoutConstraint.activate([
            fill.heightAnchor.constraint(equalTo: container.heightAnchor, multiplier: multiplier)
        ])
        container.setNeedsLayout()
        container.layoutIfNeeded()
    }
    
    private func showVolumeOverlay(value: Float) {
        volumeOverlayView?.alpha = 1
        brightnessOverlayView?.alpha = 0
        guard let fill = volumeOverlayView?.viewWithTag(1002), let container = fill.superview else { return }
        let multiplier = max(0.05, min(1, CGFloat(value)))
        fill.constraints.first(where: { $0.firstAttribute == .height })?.isActive = false
        NSLayoutConstraint.activate([
            fill.heightAnchor.constraint(equalTo: container.heightAnchor, multiplier: multiplier)
        ])
        container.setNeedsLayout()
        container.layoutIfNeeded()
    }
    
    private func scheduleHideVolumeBrightnessOverlays() {
        volumeBrightnessHideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.25) {
                self?.brightnessOverlayView?.alpha = 0
                self?.volumeOverlayView?.alpha = 0
            }
        }
        volumeBrightnessHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    @objc private func handleOverlaySingleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        controlsPassThroughWorkItem?.cancel()
        showsPlaybackControls = true
        volumeBrightnessTouchOverlay?.isUserInteractionEnabled = false
        let work = DispatchWorkItem { [weak self] in
            self?.volumeBrightnessTouchOverlay?.isUserInteractionEnabled = true
        }
        controlsPassThroughWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }
    
    private func setupPictureInPictureHandling() {
        delegate = self
        
        if AVPictureInPictureController.isPictureInPictureSupported() {
            self.allowsPictureInPicturePlayback = true
        }
    }
    
    func playerViewController(_ playerViewController: AVPlayerViewController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        let windowScene = UIApplication.shared.connectedScenes
            .filter { $0.activationState == .foregroundActive }
            .compactMap { $0 as? UIWindowScene }
            .first
        
        let window = windowScene?.windows.first(where: { $0.isKeyWindow })
        
        if let topVC = window?.rootViewController?.topmostViewController() {
            if topVC != self {
                topVC.present(self, animated: true) {
                    completionHandler(true)
                }
            } else {
                completionHandler(true)
            }
        } else {
            completionHandler(false)
        }
    }
    
    @objc private func handleHoldGesture(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            beginHoldSpeed()
        case .ended, .cancelled:
            endHoldSpeed()
        default:
            break
        }
    }
#endif
    
    private func beginHoldSpeed() {
        guard let player = player else { return }
        originalRate = player.rate
        let holdSpeed = UserDefaults.standard.float(forKey: "holdSpeedPlayer")
        player.rate = holdSpeed > 0 ? holdSpeed : 2.0
    }
    
    private func endHoldSpeed() {
        player?.rate = originalRate
    }
    
    func setupAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
#if os(iOS)
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [])
            try audioSession.setActive(true)
            // Optional: prefer speaker for playback; skip if it fails (e.g. Code -50)
            try? audioSession.overrideOutputAudioPort(.speaker)
#elseif os(tvOS)
            try audioSession.setCategory(.playback, mode: .moviePlayback)
            try audioSession.setActive(true)
#endif
        } catch {
            Logger.shared.log("Failed to set up AVAudioSession: \(error)")
        }
    }
    
    // MARK: - Progress Tracking
    
    func setupProgressTracking(for mediaInfo: MediaInfo) {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
        }
        guard let player = player else {
            Logger.shared.log("No player available for progress tracking", type: "Warning")
            return
        }
        
        timeObserverToken = ProgressManager.shared.addPeriodicTimeObserver(to: player, for: mediaInfo)
        seekToLastPosition(for: mediaInfo)
    }
    
    private func seekToLastPosition(for mediaInfo: MediaInfo) {
        let lastPlayedTime: Double
        
        switch mediaInfo {
        case .movie(let id, let title):
            lastPlayedTime = ProgressManager.shared.getMovieCurrentTime(movieId: id, title: title)
            
        case .episode(let showId, _, let seasonNumber, let episodeNumber):
            lastPlayedTime = ProgressManager.shared.getEpisodeCurrentTime(showId: showId, seasonNumber: seasonNumber, episodeNumber: episodeNumber)
        }
        
        if lastPlayedTime != 0 {
            let progress = getProgressPercentage(for: mediaInfo)
            if progress < 0.95 {
                // Defer seek until the item is ready, otherwise AVPlayer may stall on some HLS streams.
                pendingSeekSeconds = lastPlayedTime
                Logger.shared.log("Will resume playback from \(Int(lastPlayedTime))s (deferred until ready)", type: "Progress")
            }
        }
    }
    
    private func getProgressPercentage(for mediaInfo: MediaInfo) -> Double {
        switch mediaInfo {
        case .movie(let id, let title):
            return ProgressManager.shared.getMovieProgress(movieId: id, title: title)
            
        case .episode(let showId, _, let seasonNumber, let episodeNumber):
            return ProgressManager.shared.getEpisodeProgress(showId: showId, seasonNumber: seasonNumber, episodeNumber: episodeNumber)
        }
    }

#if os(iOS)
    // MARK: - Soft Subtitle Overlay (custom renderer)

    private func setupSoftSubtitleOverlayIfNeeded() {
        guard softSubtitleContainerView == nil else { return }
        guard let container = contentOverlayView else { return }

        let bg = UIView()
        bg.translatesAutoresizingMaskIntoConstraints = false
        bg.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        bg.layer.cornerRadius = 14
        bg.clipsToBounds = true
        bg.isHidden = true

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center
        label.textColor = .white
        label.numberOfLines = 0
        label.font = UIFont.systemFont(ofSize: 20, weight: .semibold)
        label.isUserInteractionEnabled = false

        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        let cfg = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        button.setImage(UIImage(systemName: "captions.bubble", withConfiguration: cfg), for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        button.layer.cornerRadius = 20
        button.clipsToBounds = true
        button.addTarget(self, action: #selector(subtitleSettingsTapped), for: .touchUpInside)
        button.isHidden = softSubtitleTracks.isEmpty

        container.addSubview(bg)
        container.addSubview(label)
        container.addSubview(button)

        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 12),
            button.trailingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            button.widthAnchor.constraint(equalToConstant: 40),
            button.heightAnchor.constraint(equalToConstant: 40),

            bg.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            bg.bottomAnchor.constraint(equalTo: container.safeAreaLayoutGuide.bottomAnchor, constant: -92),
            bg.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, multiplier: 0.9),

            label.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: bg.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -10)
        ])

        softSubtitleContainerView = bg
        softSubtitleLabel = label
        subtitleSettingsButton = button
    }

    private func subtitleHiddenUpdate() {
        guard let bg = softSubtitleContainerView, let label = softSubtitleLabel else { return }
        if softSubtitlesEnabled == false || selectedSoftSubtitleIndex == nil || softSubtitleTracks.isEmpty {
            bg.isHidden = true
            label.isHidden = true
            return
        }
        bg.isHidden = false
        label.isHidden = false
    }

    private func startSoftSubtitleTimeObserverIfNeeded() {
        guard subtitleTimeObserverToken == nil, softSubtitleTracks.isEmpty == false else { return }
        guard let player else { return }
        subtitleTimeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.15, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            self?.updateSoftSubtitle(for: time)
        }
    }

    private func updateSoftSubtitle(for time: CMTime) {
        guard softSubtitlesEnabled, let selectedSoftSubtitleIndex else {
            subtitleHiddenUpdate()
            return
        }
        guard let entries = subtitleEntriesCache[selectedSoftSubtitleIndex] else {
            subtitleHiddenUpdate()
            return
        }
        let seconds = CMTimeGetSeconds(time) + softSubtitleOffsetSeconds
        guard seconds.isFinite else { return }

        if let cue = cueFor(seconds: seconds, entries: entries) {
            softSubtitleContainerView?.isHidden = false
            softSubtitleLabel?.isHidden = false
            softSubtitleLabel?.attributedText = cue.attributedText
        } else {
            softSubtitleContainerView?.isHidden = true
            softSubtitleLabel?.isHidden = true
        }
    }

    private func cueFor(seconds: Double, entries: [SubtitleEntry]) -> SubtitleEntry? {
        if let idx = lastCueIndex, idx >= 0, idx < entries.count {
            let e = entries[idx]
            if seconds >= e.startTime && seconds <= e.endTime { return e }
        }
        for (i, e) in entries.enumerated() {
            if seconds >= e.startTime && seconds <= e.endTime {
                lastCueIndex = i
                return e
            }
        }
        return nil
    }

    private func loadSubtitlesIfNeeded(trackIndex: Int) async {
        if subtitleEntriesCache[trackIndex] != nil { return }
        guard trackIndex >= 0, trackIndex < softSubtitleTracks.count else { return }
        let track = softSubtitleTracks[trackIndex]
        do {
            let (data, _) = try await URLSession.shared.data(from: track.proxyURL)
            let content = String(data: data, encoding: .utf8) ?? ""
            let entries = SubtitleLoader.parseSubtitles(from: content, fontSize: 20.0, foregroundColor: .white)
            await MainActor.run {
                subtitleEntriesCache[trackIndex] = entries
                lastCueIndex = nil
                subtitleHiddenUpdate()
                updateSoftSubtitle(for: player?.currentTime() ?? .zero)
            }
        } catch {
            Logger.shared.log("SoftSub overlay load failed: \(error)", type: "Error")
        }
    }

    private func selectSoftSubtitle(trackIndex: Int?, enable: Bool) {
        selectedSoftSubtitleIndex = trackIndex
        softSubtitlesEnabled = enable && trackIndex != nil
        lastCueIndex = nil
        subtitleHiddenUpdate()
        if let idx = trackIndex {
            Task { await loadSubtitlesIfNeeded(trackIndex: idx) }
        }
    }

    private func presentTimingOffsetAlert() {
        let alert = UIAlertController(
            title: "Timing Offset",
            message: "Negative = subtitles earlier. Positive = subtitles later.",
            preferredStyle: .alert
        )
        alert.addTextField { tf in
            tf.keyboardType = .decimalPad
            tf.placeholder = "e.g. 0.5"
            tf.text = String(format: "%.2f", self.softSubtitleOffsetSeconds)
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            guard let self else { return }
            let raw = alert.textFields?.first?.text ?? ""
            let v = Double(raw.replacingOccurrences(of: ",", with: ".")) ?? self.softSubtitleOffsetSeconds
            self.softSubtitleOffsetSeconds = v
            UserDefaults.standard.set(v, forKey: "softSubtitleOffsetSeconds")
            self.updateSoftSubtitle(for: self.player?.currentTime() ?? .zero)
        })
        present(alert, animated: true)
    }

    @objc private func subtitleSettingsTapped() {
        guard !softSubtitleTracks.isEmpty else { return }
        let alert = UIAlertController(
            title: "Subtitles",
            message: "Offset: \(String(format: "%.2f", softSubtitleOffsetSeconds))s",
            preferredStyle: .actionSheet
        )

        alert.addAction(UIAlertAction(title: "Off", style: .destructive) { [weak self] _ in
            self?.selectSoftSubtitle(trackIndex: nil, enable: false)
        })
        alert.addAction(UIAlertAction(title: "Timing offset…", style: .default) { [weak self] _ in
            self?.presentTimingOffsetAlert()
        })

        for i in 0..<softSubtitleTracks.count {
            let display = softSubtitleTracks[i].title
            alert.addAction(UIAlertAction(title: display, style: .default) { [weak self] _ in
                self?.selectSoftSubtitle(trackIndex: i, enable: true)
            })
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }
#endif
}

extension UIViewController {
    func topmostViewController() -> UIViewController {
        if let presented = self.presentedViewController {
            return presented.topmostViewController()
        }
        
        if let navigation = self as? UINavigationController {
            return navigation.visibleViewController?.topmostViewController() ?? navigation
        }
        
        if let tabBar = self as? UITabBarController {
            return tabBar.selectedViewController?.topmostViewController() ?? tabBar
        }
        
        return self
    }
    
    /// Presents the player so it is not a child of a sheet. If the topmost VC is a presented sheet, dismisses it first then presents the player from the sheet's presenter. This prevents swipe-down from dismissing the sheet (and taking the player with it).
    func presentPlayerAvoidingSheet(_ playerVC: UIViewController, animated: Bool = true, completion: (() -> Void)? = nil) {
        let topmost = topmostViewController()
        if let presenter = topmost.presentingViewController, topmost !== self {
            topmost.dismiss(animated: animated) {
                presenter.present(playerVC, animated: true, completion: completion)
            }
        } else {
            topmost.present(playerVC, animated: animated, completion: completion)
        }
    }
}
