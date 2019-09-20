//
//  RxMusicPlayer.swift
//  RxMusicPlayer
//
//  Created by YOSHIMUTA YOHEI on 2019/09/12.
//  Copyright © 2019 YOSHIMUTA YOHEI. All rights reserved.
//
// swiftlint:disable file_length

import AVFoundation
import MediaPlayer
import RxAudioVisual
import RxCocoa
import RxSwift

/// RxMusicPlayer is a wrapper of avplayer to make it easy for audio playbacks.
///
/// RxMusicPlayer is thread safe.
open class RxMusicPlayer: NSObject {
    /**
     Player Status.
     */
    public enum Status: Equatable {
        public static func == (lhs: Status, rhs: Status) -> Bool {
            switch (lhs, rhs) {
            case (.ready, .ready),
                 (.playing, .playing),
                 (.paused, .paused),
                 (.loading, .loading):
                return true
            default:
                return false
            }
        }

        case ready
        case playing
        case paused
        case loading
        case failed(err: Error)
        case critical(err: Error)
    }

    /**
     Player Command.
     */
    public enum Command: Equatable {
        case play
        case playAt(index: Int)
        case next
        case previous
        case pause
        case stop
        case seek(seconds: Int)

        public static func == (lhs: Command, rhs: Command) -> Bool {
            switch (lhs, rhs) {
            case (.play, .play),
                 (.next, .next),
                 (.previous, .previous),
                 (.pause, .pause),
                 (.stop, .stop):
                return true
            case let (.playAt(lindex), .playAt(index: rindex)):
                return lindex == rindex
            case let (.seek(lseconds), .seek(rseconds)):
                return lseconds == rseconds
            default:
                return false
            }
        }
    }

    /**
     Player ExternalConfig.
     */
    public struct ExternalConfig {
        var automaticallyWaitsToMinimizeStalling = false

        /// default is a default configuration.
        public static let `default` = ExternalConfig()
    }

    public private(set) var playIndex: Int {
        set {
            playIndexRelay.accept(newValue)
        }
        get {
            return playIndexRelay.value
        }
    }

    public private(set) var queuedItems: [RxMusicPlayerItem] {
        set {
            queuedItemsRelay.accept(newValue)
        }
        get {
            return queuedItemsRelay.value
        }
    }

    public private(set) var status: Status {
        set {
            statusRelay.accept(newValue)
        }
        get {
            return statusRelay.value
        }
    }

    let playIndexRelay = BehaviorRelay<Int>(value: 0)
    let queuedItemsRelay = BehaviorRelay<[RxMusicPlayerItem]>(value: [])
    let statusRelay = BehaviorRelay<Status>(value: .ready)
    let playerRelay = BehaviorRelay<AVPlayer?>(value: nil)

    private let scheduler = ConcurrentDispatchQueueScheduler(
        queue: DispatchQueue.global(qos: .background)
    )
    public private(set) var player: AVPlayer? {
        set {
            playerRelay.accept(newValue)
        }
        get {
            return playerRelay.value
        }
    }

    private let autoCmdRelay = PublishRelay<Command>()
    private let remoteCmdRelay = PublishRelay<Command>()
    private let config: ExternalConfig

    /**
     Create an instance with a list of items without loading their assets.

     - parameter items: array of items to be added to the play queue

     - returns: RxMusicPlayer instance
     */
    public required init?(items: [RxMusicPlayerItem] = [RxMusicPlayerItem](),
                          config: ExternalConfig = ExternalConfig.default) {
        queuedItemsRelay.accept(items)
        self.config = config

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(AVAudioSession.Category.playback)
            try audioSession.setMode(AVAudioSession.Mode.default)
            try audioSession.setActive(true)
        } catch {
            print("[RxMusicPlayer - init?() Error] \(error)")
            return nil
        }

        super.init()
    }

    /**
     Run loop.
     */
    public func loop(cmd: Driver<Command>) -> Driver<Status> {
        let status = statusRelay
            .asObservable()

        let playerStatus = playerRelay
            .flatMapLatest(watchPlayerStatus)
            .subscribe()

        let playerItemStatus = playerRelay
            .flatMapLatest(watchPlayerItemStatus)
            .subscribe()

        let newErrorLogEntry = watchNewErrorLogEntry()
            .subscribe()

        let failedToPlayToEndTime = watchFailedToPlayToEndTime()
            .subscribe()

        let endTime = watchEndTime()
            .subscribe()

        let stall = watchPlaybackStall()
            .subscribe()

        let nowPlaying = updateNowPlayingInfo()
            .subscribe()

        let remoteControl = registerRemoteControl()
            .subscribe()

        let cmdRunner = Observable.merge(
            cmd.asObservable(),
            autoCmdRelay.asObservable(),
            remoteCmdRelay.asObservable()
        )
        .flatMapLatest(runCommand)
        .subscribe()

        return Observable.create { observer in
            let statusDisposable = status
                .distinctUntilChanged()
                .subscribe(observer)

            return Disposables.create {
                statusDisposable.dispose()
                playerStatus.dispose()
                playerItemStatus.dispose()
                newErrorLogEntry.dispose()
                failedToPlayToEndTime.dispose()
                endTime.dispose()
                stall.dispose()
                nowPlaying.dispose()
                remoteControl.dispose()
                cmdRunner.dispose()
            }
        }
        .asDriver(onErrorJustReturn: statusRelay.value)
    }

    private func registerRemoteControl() -> Observable<()> {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.remoteCmdRelay.accept(.play)
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.remoteCmdRelay.accept(.pause)
            return .success
        }
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.remoteCmdRelay.accept(.next)
            return .success
        }
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.remoteCmdRelay.accept(.previous)
            return .success
        }
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            if self?.status == .some(.playing) {
                self?.remoteCmdRelay.accept(.pause)
            } else {
                self?.remoteCmdRelay.accept(.play)
            }
            return .success
        }
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] ev in
            guard let event = ev as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self?.remoteCmdRelay.accept(.seek(seconds: Int(event.positionTime)))
            return .success
        }

        return Observable.create { [weak self] _ in
            guard let weakSelf = self else { return Disposables.create() }
            let disablePlay = weakSelf.rx.canSendCommand(cmd: .play)
                .do(onNext: {
                    commandCenter.playCommand.isEnabled = $0
                })
                .drive()
            let disablePause = weakSelf.rx.canSendCommand(cmd: .pause)
                .do(onNext: {
                    commandCenter.pauseCommand.isEnabled = $0
                })
                .drive()
            let disableNext = weakSelf.rx.canSendCommand(cmd: .next)
                .do(onNext: {
                    commandCenter.nextTrackCommand.isEnabled = $0
                })
                .drive()
            let disablePrevious = weakSelf.rx.canSendCommand(cmd: .previous)
                .do(onNext: {
                    commandCenter.previousTrackCommand.isEnabled = $0
                })
                .drive()
            let disableSeek = weakSelf.rx.canSendCommand(cmd: .seek(seconds: 0))
                .do(onNext: {
                    commandCenter.changePlaybackPositionCommand.isEnabled = $0
                })
                .drive()

            return Disposables.create {
                disablePlay.dispose()
                disablePause.dispose()
                disableNext.dispose()
                disablePrevious.dispose()
                disableSeek.dispose()
            }
        }
    }

    private func runCommand(cmd: Command) -> Observable<()> {
        return rx.canSendCommand(cmd: cmd).asObservable().take(1)
            .observeOn(scheduler)
            .flatMapLatest { [weak self] isEnabled -> Observable<()> in
                guard let weakSelf = self else {
                    return .error(RxMusicPlayerError.notFoundWeakReference)
                }
                if !isEnabled {
                    return .error(RxMusicPlayerError.invalidCommand(cmd: cmd))
                }
                switch cmd {
                case .play:
                    return weakSelf.play()
                case let .playAt(index: index):
                    return weakSelf.play(atIndex: index)
                case .next:
                    return weakSelf.playNext()
                case .previous:
                    return weakSelf.playPrevious()
                case .pause:
                    return weakSelf.pause()
                case .stop:
                    return weakSelf.stop()
                case let .seek(seconds: sec):
                    return weakSelf.seek(toSecond: sec)
                }
            }
            .catchError { [weak self] err in
                self?.status = .failed(err: err)
                return .just(())
            }
    }

    private func play() -> Observable<()> {
        return play(atIndex: playIndex)
    }

    private func play(atIndex index: Int) -> Observable<()> {
        if playIndex == index && status == .paused {
            return resume()
        }

        player?.pause()

        playIndex = index
        status = .loading

        return queuedItems[playIndex].loadPlayerItem()
            .asObservable()
            .flatMapLatest { [weak self] item -> Observable<()> in
                guard let weakSelf = self, let weakItem = item else {
                    return .error(RxMusicPlayerError.notFoundWeakReference)
                }
                weakSelf.player = nil

                let player = AVPlayer(playerItem: weakItem.playerItem)
                weakSelf.player = player
                weakSelf.player!.automaticallyWaitsToMinimizeStalling =
                    weakSelf.config.automaticallyWaitsToMinimizeStalling
                weakSelf.player!.play()
                return weakSelf.preload(index: index)
            }
    }

    private func playNext() -> Observable<()> {
        return play(atIndex: playIndex + 1)
    }

    private func playPrevious() -> Observable<()> {
        if 1 < (player?.currentTime().seconds ?? 0) {
            return seek(toSecond: 0)
        }
        return play(atIndex: playIndex - 1)
    }

    private func replayCurrentItem() -> Observable<()> {
        return seek(toSecond: 0, shouldPlay: true)
    }

    private func seek(toSecond second: Int,
                      shouldPlay: Bool = false) -> Observable<()> {
        guard let player = player else { return .just(()) }

        player.seek(to: CMTimeMake(value: Int64(second), timescale: 1))

        if shouldPlay && status != .playing {
            player.play()
            status = .playing
        }
        return .just(())
    }

    private func pause() -> Observable<()> {
        player?.pause()
        status = .paused
        return .just(())
    }

    private func resume() -> Observable<()> {
        player?.play()
        status = .playing
        return .just(())
    }

    private func stop() -> Observable<()> {
        player?.pause()
        player = nil

        status = .ready
        return .just(())
    }

    private func preload(index: Int) -> Observable<()> {
        var items: [RxMusicPlayerItem] = []
        if index - 1 >= 0 {
            items.append(queuedItems[index - 1])
        }
        if index + 1 < queuedItems.count {
            items.append(queuedItems[index + 1])
        }

        return Observable.combineLatest(
            items.map { $0.loadPlayerItem().asObservable() }
        ).map { _ in }
    }

    private func watchPlayerStatus(player: AVPlayer?) -> Observable<()> {
        guard let weakPlayer = player else {
            return .just(())
        }
        return weakPlayer.rx.status
            .map { [weak self] st in
                switch st {
                case .failed:
                    self?.status = .critical(err: weakPlayer.error!)
                    self?.autoCmdRelay.accept(.stop)
                default:
                    break
                }
            }
    }

    private func watchPlayerItemStatus(player: AVPlayer?) -> Observable<()> {
        guard let weakItem = player?.currentItem else {
            return .just(())
        }
        return weakItem.rx.status
            .map { [weak self] st in
                switch st {
                case .readyToPlay: self?.status = .playing
                case .failed: self?.status = .failed(err: weakItem.error!)
                default: self?.status = .loading
                }
            }
    }

    private func watchNewErrorLogEntry() -> Observable<()> {
        return NotificationCenter.default.rx
            .notification(.AVPlayerItemNewErrorLogEntry)
            .map { [weak self] notification in
                guard let object = notification.object,
                    let playerItem = object as? AVPlayerItem else {
                    return
                }
                guard let errorLog: AVPlayerItemErrorLog = playerItem.errorLog() else {
                    return
                }
                self?.status = .failed(err: RxMusicPlayerError.playerItemError(log: errorLog))
            }
    }

    private func watchFailedToPlayToEndTime() -> Observable<()> {
        return NotificationCenter.default.rx
            .notification(.AVPlayerItemFailedToPlayToEndTime)
            .map { [weak self] notification in
                guard let val = notification.userInfo?["AVPlayerItemFailedToPlayToEndTimeErrorKey"] as? String
                else {
                    let info = String(describing: notification.userInfo)
                    self?.status = .failed(err: RxMusicPlayerError.internalError(
                        "not found AVPlayerItemFailedToPlayToEndTimeErrorKey in \(info)"))
                    return
                }
                self?.status = .failed(err: RxMusicPlayerError.failedToPlayToEndTime(val))
            }
    }

    private func watchEndTime() -> Observable<()> {
        return NotificationCenter.default.rx
            .notification(.AVPlayerItemDidPlayToEndTime)
            .withLatestFrom(rx.canSendCommand(cmd: .next))
            .map { [weak self] isEnabled in
                if isEnabled {
                    self?.autoCmdRelay.accept(.next)
                } else {
                    self?.autoCmdRelay.accept(.stop)
                }
            }
    }

    private func watchPlaybackStall() -> Observable<()> {
        return NotificationCenter.default.rx
            .notification(.AVPlayerItemPlaybackStalled)
            .map { [weak self] _ in
                if self?.status == .some(.playing) {
                    self?.player?.pause()
                    if #available(iOS 10.0, *) {
                        self?.player?.playImmediately(atRate: 1.0)
                    } else {
                        self?.player?.play()
                    }
                }
            }
    }

    private func updateNowPlayingInfo() -> Observable<()> {
        return Driver.combineLatest(
            rx.currentItemMeta(),
            rx.currentItemDuration(),
            rx.currentItemTime()
        ) { [weak self] meta, duration, currentTime in
            let title = meta.title ?? ""
            let duration = duration?.seconds ?? 0
            let elapsed = currentTime?.seconds ?? 0
            let queueCount = self?.queuedItems.count ?? 0
            let queueIndex = self?.playIndex ?? 0

            var nowPlayingInfo: [String: Any] = [
                MPMediaItemPropertyTitle: title,
                MPMediaItemPropertyPlaybackDuration: duration,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
                MPNowPlayingInfoPropertyPlaybackQueueCount: queueCount,
                MPNowPlayingInfoPropertyPlaybackQueueIndex: queueIndex
            ]

            if let artist = meta.artist {
                nowPlayingInfo[MPMediaItemPropertyArtist] = artist
            }

            if let album = meta.album {
                nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = album
            }

            if let img = meta.artwork {
                nowPlayingInfo[MPMediaItemPropertyArtwork] =
                    MPMediaItemArtwork(boundsSize: img.size,
                                       requestHandler: { _ in img })
            }
            return nowPlayingInfo
        }
        .map {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = $0
        }
        .asObservable()
    }
}
