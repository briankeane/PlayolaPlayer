//
//  AudioPlayer.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 1/6/25.
//

import AVFoundation
import Foundation
import os.log

/// Handles audioPlay for a single spin at a time.
@MainActor
public class SpinPlayer {
  public var duration: Double = 0

  // dependencies
  @objc var playolaMainMixer: PlayolaMainMixer = .shared
  private var fileDownloadManager: FileDownloadManager!

  public weak var delegate: SpinPlayerDelegate?

  /// Namespaced logger
  private static let logger = OSLog(subsystem: "fm.playola.playolaCore", category: "Player")
  
  /// An internal instance of AVAudioEngine
  private let engine: AVAudioEngine! = PlayolaMainMixer.shared.engine!
  
  /// The node responsible for playing the audio file
  private let playerNode = AVAudioPlayerNode()
  
  /// The currently playing audio file
  private var currentFile: AVAudioFile? {
    didSet {
      if let file = currentFile {
        loadFile(file)
      }
    }
  }

  /// A Bool indicating whether the engine is playing or not
  public var isPlaying: Bool {
    return playerNode.isPlaying
  }
  
  public var volume: Float {
    get {
      return playerNode.volume
    }
    set {
      playerNode.volume = newValue
    }
  }
  
  /// Singleton instance of the player
  static let shared = SpinPlayer()
  
  // MARK: Lifecycle
  
  init(delegate: SpinPlayerDelegate? = nil, fileDownloadManager: FileDownloadManager? = nil) {
    self.fileDownloadManager = fileDownloadManager ?? .shared
    self.delegate = delegate

    do {
      let session = AVAudioSession()
      try
      session.setCategory(AVAudioSession.Category(rawValue: convertFromAVAudioSessionCategory(AVAudioSession.Category.playAndRecord)), mode: AVAudioSession.Mode.default, options: [
        .allowBluetoothA2DP,
        .defaultToSpeaker
      ])
    } catch {
      os_log("Error setting up session: %@", log: SpinPlayer.logger, type: .default, #function, #line, error.localizedDescription)
    }
  
    /// Make connections
    engine.attach(playerNode)
    engine.connect(playerNode, to: playolaMainMixer.mixerNode, format: TapProperties.default.format)
    engine.prepare()
    
    /// Install tap
    //        playerNode.installTap(onBus: 0, bufferSize: TapProperties.default.bufferSize, format: TapProperties.default.format, block: onTap(_:_:))
  }
  
  // MARK: Playback
  
  /// Begins playback (starts engine and player node)
  func play() {
    os_log("%@ - %d", log: SpinPlayer.logger, type: .default, #function, #line)
    
    guard !isPlaying, let _ = currentFile else {
      return
    }
    
    do {
      try engine.start()
      playerNode.play()
      delegate?.player(self, didChangePlaybackState: true)
    } catch {
      os_log("Error starting engine: %@", log: SpinPlayer.logger, type: .default, #function, #line, error.localizedDescription)
    }
  }
  
  public func stop() {
    if !engine.isRunning {
      do {
        try engine.start()
      } catch {
        os_log("Error starting engine while stopping: %@", log: SpinPlayer.logger, type: .default, #function, #line, error.localizedDescription)
        return
      }
    }
    playerNode.stop()
    playerNode.reset()
    //        self.currentFile = nil
  }
  
  /// play a segment of the song immediately
  private func play(from: Double, to: Double? = nil) {
    do {
      try engine.start()
      
      // calculate segment info
      let sampleRate = playerNode.outputFormat(forBus: 0).sampleRate
      let newSampleTime = AVAudioFramePosition(sampleRate * from)
      let framesToPlay = AVAudioFrameCount(Float(sampleRate) * Float(duration))
      
      // stop the player, schedule the segxment, restart the player
      playerNode.volume = 1.0
      playerNode.stop()
      playerNode.scheduleSegment(currentFile!, startingFrame: newSampleTime, frameCount: framesToPlay, at: nil, completionHandler: nil)
      playerNode.play()
      
      delegate?.player(self, didChangePlaybackState: true)
    } catch {
      os_log("Error starting engine: %@", log: SpinPlayer.logger, type: .default, #function, #line, error.localizedDescription)
    }
  }
  
  public func scheduleFade(at: Date, startingVolume: Float, endingVolume: Float) {
  }

  public func loadAndSchedule(_ spin: Spin, onDownloadProgress: ((Float) -> Void)? = nil, onDownloadCompletion: ((URL) -> Void)? = nil) {
    guard let audioFileUrlStr = spin.audioBlock?.downloadUrl, let audioFileUrl = URL(string: audioFileUrlStr) else { return }

    fileDownloadManager.downloadFile(remoteUrl: audioFileUrl) { progress in
      onDownloadProgress?(progress)
    } onCompletion: { localUrl in
      onDownloadCompletion?(localUrl)
      self.loadFile(with: localUrl)
      if spin.isPlaying {
        let currentTimeInSeconds = Date().timeIntervalSince(spin.airtime)
        self.play(from: currentTimeInSeconds, to: nil)
      } else {
        self.schedulePlay(at: spin.airtime)
      }
    }
  }

  private func avAudioTimeFromDate(date: Date) -> AVAudioTime {
    let outputFormat = playerNode.outputFormat(forBus: 0)
    let now = playerNode.lastRenderTime!.sampleTime
    let secsUntilDate = date.timeIntervalSinceNow
    return AVAudioTime(sampleTime: now + Int64(secsUntilDate * outputFormat.sampleRate), atRate: outputFormat.sampleRate)
  }
  
  /// schedule a future play from the beginning of the file
  public func schedulePlay(at: Date) {
    do {
      try engine.start()
      let avAudiotime = avAudioTimeFromDate(date: at)
      print("Scheduling play at datetime: \(at), avAudioTime:\(avAudiotime)")
      playerNode.play(at: avAudiotime)
      delegate?.player(self, didChangePlaybackState: true)
    } catch {
      os_log("Error starting engine: %@", log: SpinPlayer.logger, type: .default, #function, #line, error.localizedDescription)
    }
  }
  
  /// Pauses playback (pauses the engine and player node)
  func pause() {
    os_log("%@ - %d", log: SpinPlayer.logger, type: .default, #function, #line)
    
    guard isPlaying, let _ = currentFile else {
      return
    }
    
    playerNode.pause()
    engine.pause()
    delegate?.player(self, didChangePlaybackState: false)
  }
  
  // MARK: File Loading
  
  /// Loads an AVAudioFile into the current player node
  private func loadFile(_ file: AVAudioFile) {
    os_log("%@ - %d", log: SpinPlayer.logger, type: .default, #function, #line)
    
    duration = getDuration(file: file)
    
    playerNode.scheduleFile(file, at: nil)
  }
  
  public func setVolume(_ level: Float) {
    playerNode.volume = level
  }
  
  /// Loads an audio file at the provided URL into the player node
  public func loadFile(with url: URL) {
    os_log("%@ - %d", log: SpinPlayer.logger, type: .default, #function, #line)
    
    do {
      currentFile = try AVAudioFile(forReading: url)
    } catch {
      os_log("Error loading (%@): %@", log: SpinPlayer.logger, type: .error, #function, #line, url.absoluteString, error.localizedDescription)
    }
  }
  
  fileprivate func getDuration(file: AVAudioFile) -> Double {
    let audioNodeFileLength = AVAudioFrameCount(file.length)
    return Double(Double(audioNodeFileLength) / 44100)
  }
  
  // MARK: Tap
  
  /// Handles the audio tap
  private func onTap(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
    guard let file = currentFile,
          let nodeTime = playerNode.lastRenderTime,
          let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
    else {
      return
    }
    
    let currentTime = TimeInterval(playerTime.sampleTime) / playerTime.sampleRate
    delegate?.player(self, didPlayFile: file, atTime: currentTime, withBuffer: buffer)
  }
}

// Helper function inserted by Swift 4.2 migrator.
private func convertFromAVAudioSessionCategory(_ input: AVAudioSession.Category) -> String {
  return input.rawValue
}
