//
//  FileDownloadManager.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 1/2/25.
//
import SwiftUI
import os.log

/// Errors specific to file downloading and caching
public enum FileDownloadError: Error, LocalizedError {
  case directoryCreationFailed(String)
  case fileMoveFailed(String)
  case fileNotFound(String)
  case invalidRemoteURL(String)
  case downloadFailed(String)
  case cachePruneFailed(String)
  case downloadCancelled
  case unknownError

  public var errorDescription: String? {
    switch self {
    case .directoryCreationFailed(let path):
      return "Failed to create directory at path: \(path)"
    case .fileMoveFailed(let message):
      return "Failed to move downloaded file: \(message)"
    case .fileNotFound(let path):
      return "File not found at path: \(path)"
    case .invalidRemoteURL(let url):
      return "Invalid remote URL: \(url)"
    case .downloadFailed(let message):
      return "Download failed: \(message)"
    case .cachePruneFailed(let message):
      return "Cache pruning failed: \(message)"
    case .downloadCancelled:
      return "Download was cancelled"
    case .unknownError:
      return "An unknown error occurred"
    }
  }
}

/// Protocol defining the interface for file download management
///
/// This protocol provides methods to download, manage, and cache audio files
/// with support for progress tracking, cancellation, and cache management.
public protocol FileDownloadManaging {
  /// Downloads a file from a remote URL with progress tracking
  ///
  /// - Parameters:
  ///   - remoteUrl: The URL of the file to download
  ///   - progressHandler: A closure that receives download progress updates (0.0 to 1.0)
  ///   - completion: A closure called when download completes with either the local URL or an error
  /// - Returns: A unique identifier that can be used to cancel this specific download
  @discardableResult
  func downloadFile(
    remoteUrl: URL,
    progressHandler: @escaping (Float) -> Void,
    completion: @escaping (Result<URL, FileDownloadError>) -> Void
  ) -> UUID

  /// Downloads a file asynchronously from a remote URL
  /// - Parameters:
  ///   - remoteUrl: The URL of the file to download
  ///   - progressHandler: A closure that receives download progress updates (0.0 to 1.0)
  /// - Returns: The local URL where the file was saved
  /// - Throws: FileDownloadError if the download fails
  func downloadFileAsync(
    remoteUrl: URL,
    progressHandler: ((Float) -> Void)?
  ) async throws -> URL

  /// Cancels a specific download using its identifier
  /// - Parameter downloadId: The identifier of the download to cancel
  /// - Returns: True if a download was found and cancelled, false otherwise
  @discardableResult
  func cancelDownload(id downloadId: UUID) -> Bool

  /// Cancels all downloads for a specific remote URL
  /// - Parameter remoteUrl: The remote URL of the downloads to cancel
  /// - Returns: The number of downloads cancelled
  @discardableResult
  func cancelDownload(for remoteUrl: URL) -> Int

  /// Cancels all active downloads
  func cancelAllDownloads()

  /// Checks if a file already exists in the cache
  /// - Parameter remoteUrl: The remote URL to check
  /// - Returns: True if the file exists in the cache
  func fileExists(for remoteUrl: URL) -> Bool

  /// Returns the local URL where a file would be stored
  /// - Parameter remoteUrl: The remote URL of the file
  /// - Returns: The local cache URL for this file
  func localURL(for remoteUrl: URL) -> URL

  /// Clears all cached files
  /// - Throws: FileDownloadError if the cache couldn't be cleared
  func clearCache() throws

  /// Prunes the cache to stay under the specified size limit
  /// - Parameters:
  ///   - maxSize: Maximum size in bytes for the cache (nil uses default)
  ///   - excludeFilepaths: Paths to exclude from pruning
  /// - Throws: FileDownloadError if pruning fails
  func pruneCache(maxSize: Int64?, excludeFilepaths: [String]) throws

  /// Returns the current size of the cache in bytes
  /// - Returns: The size in bytes
  func currentCacheSize() -> Int64

  /// Returns the available disk space on the volume containing the cache
  /// - Returns: Available space in bytes, or nil if it couldn't be determined
  func availableDiskSpace() -> Int64?
}

/// Manages downloading and caching of audio files for the Playola player
///
/// `FileDownloadManager` provides:
/// - Concurrent download management with progress tracking
/// - Intelligent caching with size limits and pruning
/// - Persistent storage of downloaded files
/// - Thread-safe operations for all download and cache management
///
/// ## Thread Safety
/// All methods in this class are thread-safe and can be called from any thread.
/// Internal state is synchronized using a dedicated dispatch queue.
///
/// ## Caching Strategy
/// Files are cached in the app's documents directory under a dedicated subfolder.
/// When the cache size exceeds the configured limit, the oldest files are removed first.
@Observable
@MainActor
public final class FileDownloadManager: FileDownloadManaging {
  /// Maximum default size of the audio file cache in bytes (50MB)
  /// This limit can be overridden in the pruneCache method
  public static let MAX_AUDIO_FOLDER_SIZE: Int64 = 52_428_800

  /// Name of the cache subfolder
  public static let subfolderName = "AudioFiles"

  /// Shared singleton instance
  public static let shared = FileDownloadManager()

  /// Active downloaders keyed by their unique identifiers
  private var downloaders: [UUID: FileDownloader] = [:]

  /// Error reporter for logging issues
  private let errorReporter = PlayolaErrorReporter.shared

  /// Queue for synchronizing access to shared resources
  private let downloadQueue = DispatchQueue(label: "fm.playola.fileDownloadManager", qos: .utility)

  /// Logger for debug information
  private static let logger = OSLog(
    subsystem: "fm.playola.playolaCore", category: "FileDownloadManager")

  /// Initializes a new file download manager and creates the cache directory
  public init() {
    createFolderIfNotExist()
  }

  deinit {
    Task {
      await cancelAllDownloads()
    }
  }

  /// The URL of the cache directory
  private var fileDirectoryURL: URL! {
    let paths = NSSearchPathForDirectoriesInDomains(
      FileManager.SearchPathDirectory.documentDirectory,
      FileManager.SearchPathDomainMask.userDomainMask,
      true)
    let documentsDirectoryURL = URL(fileURLWithPath: paths[0])
    return documentsDirectoryURL.appendingPathComponent(
      FileDownloadManager.subfolderName)
  }

  /// Returns the local URL where a remote file would be stored
  /// - Parameter remoteUrl: The remote URL of the file
  /// - Returns: The local cache URL for this file
  public func localURL(for remoteUrl: URL) -> URL {
    let filename = remoteUrl.lastPathComponent
    return fileDirectoryURL.appendingPathComponent(filename)
  }

  /// Creates the cache directory if it doesn't exist
  private func createFolderIfNotExist() {
    let fileManager = FileManager.default
    do {
      try fileManager.createDirectory(
        atPath: fileDirectoryURL.path, withIntermediateDirectories: true, attributes: nil)
    } catch let error as NSError {
      let availableSpace = availableDiskSpace() ?? 0
      let playolaError = FileDownloadError.directoryCreationFailed(fileDirectoryURL.path)
      errorReporter.reportError(
        error,
        context:
          "\(playolaError.errorDescription ?? "Unknown error") | Available space: \(availableSpace/1_048_576) MB | Error code: \(error.code)",
        level: .error)  // Elevated to error since this is critical functionality
    }
  }

  /// Checks if a file already exists in the cache
  /// - Parameter remoteUrl: The remote URL to check
  /// - Returns: True if the file exists in the cache
  public func fileExists(for remoteUrl: URL) -> Bool {
    let localUrl = localURL(for: remoteUrl)
    return FileManager.default.fileExists(atPath: localUrl.path)
  }

  /// Downloads a file from a remote URL
  /// - Parameters:
  ///   - remoteUrl: The URL of the file to download
  ///   - progressHandler: A closure that receives download progress updates (0.0 to 1.0)
  ///   - completion: A closure called when download completes with either the local URL or an error
  /// - Returns: A unique identifier that can be used to cancel this specific download
  @discardableResult
  public func downloadFile(
    remoteUrl: URL,
    progressHandler: @escaping (Float) -> Void = { _ in },
    completion: @escaping (Result<URL, FileDownloadError>) -> Void
  ) -> UUID {
    let localUrl = localURL(for: remoteUrl)
    let downloadId = UUID()

    // Check if file already exists
    if FileManager.default.fileExists(atPath: localUrl.path) {
      Task { @MainActor in
        completion(.success(localUrl))
      }
      return downloadId  // Return a dummy ID since no download was started
    }

    // Check if we have sufficient storage space
    if let availableSpace = availableDiskSpace(),
      availableSpace < 10_485_760
    {  // 10MB minimum
      let error = FileDownloadError.cachePruneFailed(
        "Insufficient storage space: \(availableSpace / 1_048_576) MB available")
      Task { @MainActor in
        completion(.failure(error))
        errorReporter.reportError(error, level: .warning)
      }
      return downloadId
    }

    let downloader = FileDownloader(
      id: downloadId,
      remoteUrl: remoteUrl,
      localUrl: localUrl,
      onProgress: progressHandler,
      onCompletion: { [weak self] downloader in
        guard let self = self else { return }
        self.safelyRemoveDownloader(downloadId)
        completion(.success(downloader.localUrl))
      },
      onError: { [weak self] error in
        guard let self = self else { return }
        self.safelyRemoveDownloader(downloadId)

        if let downloadError = error as? FileDownloadError {
          completion(.failure(downloadError))
        } else {
          completion(.failure(.downloadFailed(error.localizedDescription)))
        }
      }
    )

    safelyAddDownloader(downloadId, downloader)
    return downloadId
  }

  /// Downloads a file asynchronously from a remote URL
  /// - Parameters:
  ///   - remoteUrl: The URL of the file to download
  ///   - progressHandler: A closure that receives download progress updates (0.0 to 1.0)
  /// - Returns: The local URL where the file was saved
  /// - Throws: FileDownloadError if the download fails
  public func downloadFileAsync(
    remoteUrl: URL,
    progressHandler: ((Float) -> Void)? = nil
  ) async throws -> URL {
    return try await withCheckedThrowingContinuation { continuation in
      _ = downloadFile(
        remoteUrl: remoteUrl,
        progressHandler: progressHandler ?? { _ in },
        completion: { result in
          switch result {
          case .success(let url):
            continuation.resume(returning: url)
          case .failure(let error):
            continuation.resume(throwing: error)
          }
        }
      )
    }
  }

  /// Cancels a specific download using its identifier
  /// - Parameter downloadId: The identifier of the download to cancel
  /// - Returns: True if a download was found and cancelled, false otherwise
  @discardableResult
  public func cancelDownload(id downloadId: UUID) -> Bool {
    var cancelled = false
    downloadQueue.sync {
      if let downloader = downloaders[downloadId] {
        downloader.cancel()
        downloaders.removeValue(forKey: downloadId)
        cancelled = true
      }
    }
    return cancelled
  }

  /// Cancels all downloads for a specific remote URL
  /// - Parameter remoteUrl: The remote URL of the downloads to cancel
  /// - Returns: The number of downloads cancelled
  @discardableResult
  public func cancelDownload(for remoteUrl: URL) -> Int {
    var cancelCount = 0
    let localUrl = localURL(for: remoteUrl)

    downloadQueue.sync {
      let matchingDownloaders = downloaders.values.filter {
        $0.remoteUrl == remoteUrl || $0.localUrl == localUrl
      }

      for downloader in matchingDownloaders {
        downloader.cancel()
        downloaders.removeValue(forKey: downloader.id)
        cancelCount += 1
      }
    }
    return cancelCount
  }

  /// Cancels all active downloads
  public func cancelAllDownloads() {
    downloadQueue.sync {
      for downloader in downloaders.values {
        downloader.cancel()
      }
      downloaders.removeAll()
    }
  }

  // Thread-safe methods to modify downloaders collection
  private func safelyAddDownloader(_ id: UUID, _ downloader: FileDownloader) {
    downloadQueue.sync {
      downloaders[id] = downloader
    }
  }

  private func safelyRemoveDownloader(_ id: UUID) {
    downloadQueue.sync {
      downloaders.removeValue(forKey: id)
    }
  }

  /// Clears all cached files
  /// - Throws: FileDownloadError if the cache couldn't be cleared
  public func clearCache() throws {
    guard let directory = fileDirectoryURL else {
      throw FileDownloadError.directoryCreationFailed("No directory URL available")
    }

    let fileManager = FileManager.default

    do {
      let fileURLs = try fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: .skipsHiddenFiles
      )

      for fileURL in fileURLs {
        try fileManager.removeItem(at: fileURL)
      }
    } catch {
      throw FileDownloadError.cachePruneFailed(
        "Failed to clear cache: \(error.localizedDescription)")
    }
  }

  /// Returns the current size of the cache in bytes
  /// - Returns: The size in bytes
  public func currentCacheSize() -> Int64 {
    return calculateFolderCacheSize()
  }

  /// Returns the available disk space on the volume containing the cache
  /// - Returns: Available space in bytes, or nil if it couldn't be determined
  public func availableDiskSpace() -> Int64? {
    do {
      let fileURL = fileDirectoryURL
      let values = try fileURL?.resourceValues(forKeys: [.volumeAvailableCapacityKey])
      return values?.volumeAvailableCapacityForImportantUsage
    } catch {
      let path = fileDirectoryURL?.path ?? "unknown"
      errorReporter.reportError(
        error,
        context:
          "Failed to get available disk space for path: \(path) | Error: \(error.localizedDescription)",
        level: .warning)
      return nil
    }
  }

  /// Calculates the total size of files in the cache folder
  /// - Returns: Size in bytes
  private func calculateFolderCacheSize() -> Int64 {
    var bool: ObjCBool = false
    var folderFileSizeInBytes: Int64 = 0

    guard let cachePath = fileDirectoryURL?.path,
      FileManager.default.fileExists(atPath: cachePath, isDirectory: &bool),
      bool.boolValue
    else {
      return 0
    }

    let fileManager = FileManager.default
    do {
      let files = try fileManager.contentsOfDirectory(
        at: fileDirectoryURL,
        includingPropertiesForKeys: [.fileSizeKey],
        options: [.skipsHiddenFiles])

      for file in files {
        do {
          let attributes = try file.resourceValues(forKeys: [.fileSizeKey])
          folderFileSizeInBytes += Int64(attributes.fileSize ?? 0)
        } catch let error {
          let fileExists = FileManager.default.fileExists(atPath: file.path)
          errorReporter.reportError(
            error,
            context:
              "Failed to get file size for \(file.lastPathComponent) | Exists: \(fileExists) | Path: \(file.path)",
            level: .warning)
          continue
        }
      }
    } catch let error {
      errorReporter.reportError(
        error, context: "Failed to read contents of directory", level: .warning)
    }
    return folderFileSizeInBytes
  }

  /// Prunes the cache to stay under the specified size limit
  ///
  /// This method:
  /// 1. Calculates the current cache size
  /// 2. If the cache exceeds the limit, removes files in order from oldest to newest
  /// 3. Preserves files specified in the excludeFilepaths parameter
  /// 4. Continues removing until the cache size is under the limit
  ///
  /// - Parameters:
  ///   - maxSize: Maximum size in bytes for the cache (nil uses default 50MB limit)
  ///   - excludeFilepaths: Paths to exclude from pruning (e.g., currently playing files)
  /// - Throws: FileDownloadError if pruning fails
  public func pruneCache(maxSize: Int64? = nil, excludeFilepaths: [String] = []) throws {
    let maxCacheSize = maxSize ?? FileDownloadManager.MAX_AUDIO_FOLDER_SIZE

    guard let directory = fileDirectoryURL else {
      throw FileDownloadError.directoryCreationFailed("No directory URL available")
    }

    let fileUrls: [URL]
    do {
      fileUrls = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
        options: .skipsHiddenFiles)
    } catch let error {
      throw FileDownloadError.cachePruneFailed(
        "Failed to get directory contents: \(error.localizedDescription)")
    }

    // Get current cache size and check if pruning is needed
    let currentSize = currentCacheSize()
    if currentSize <= maxCacheSize {
      return  // No pruning needed
    }

    // Amount to remove to get under the limit (plus some buffer)
    let amountToDelete = currentSize - maxCacheSize + (1024 * 1024)  // 1MB buffer

    // Sort files by date (oldest first)
    let filesToPrune = fileUrls.compactMap { url -> (URL, Date, Int64)? in
      do {
        let resourceValues = try url.resourceValues(forKeys: [
          .contentModificationDateKey, .fileSizeKey,
        ])
        guard let date = resourceValues.contentModificationDate,
          let size = resourceValues.fileSize
        else {
          return nil
        }
        return (url, date, Int64(size))
      } catch {
        errorReporter.reportError(
          error, context: "Failed to get file attributes for \(url.lastPathComponent)",
          level: .warning)
        return nil
      }
    }
    .filter { !excludeFilepaths.contains($0.0.path) }
    .sorted { $0.1 < $1.1 }  // Sort by date (oldest first)

    // After sorting files for pruning, log which files might be pruned
    if filesToPrune.count > 0 {
      os_log(
        "Pruning candidates: %@",
        log: FileDownloadManager.logger,
        type: .debug,
        filesToPrune.map { $0.0.lastPathComponent }.joined(separator: ", "))
    }

    // Also log the excluded files
    if !excludeFilepaths.isEmpty {
      os_log(
        "Files excluded from pruning: %@",
        log: FileDownloadManager.logger,
        type: .debug,
        excludeFilepaths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))
    }

    var totalRemoved: Int64 = 0
    let fileManager = FileManager.default

    for (url, _, size) in filesToPrune {
      if totalRemoved >= amountToDelete {
        break
      }

      do {
        try fileManager.removeItem(at: url)
        totalRemoved += size
        os_log(
          "Pruned file: %@ (%d bytes)", log: FileDownloadManager.logger, type: .debug,
          url.lastPathComponent, size)
      } catch {
        // Continue with other files even if one fails
        errorReporter.reportError(
          error, context: "Error removing file during cache pruning: \(url.path)", level: .warning)
      }
    }

    if totalRemoved < amountToDelete {
      os_log(
        "Cache pruning incomplete: removed %d bytes of %d needed", log: FileDownloadManager.logger,
        type: .info, totalRemoved, amountToDelete)
    }
  }
}
