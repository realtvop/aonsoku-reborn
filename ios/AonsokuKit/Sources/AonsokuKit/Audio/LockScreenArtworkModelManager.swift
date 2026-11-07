import CoreML
import Foundation
import Network

/// Native-only optional weights. Downloads stream to disk, are SHA256-checked
/// and compiled locally. The inference boundary serializes compile/load/delete.
final class LockScreenArtworkModelManager: NSObject, URLSessionDownloadDelegate {
  static let shared = LockScreenArtworkModelManager()
  static let ready = Notification.Name("AonsokuArtworkModelReady")
  private let directory: URL
  private let worker = DispatchQueue(label: "com.aonsoku.artwork-model-download", qos: .utility)
  private let lock = NSLock()
  private var states: [LockScreenArtworkTier: [String: Any]] = [:]
  private var pending: [LockScreenArtworkTier] = []
  private var deferred: [LockScreenArtworkTier: URL] = [:]
  private var blockedAutomatic: Set<LockScreenArtworkTier> = []
  private var unmetered = false
  private let network = NWPathMonitor()
  private lazy var session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 300
    config.waitsForConnectivity = false
    // A tier cannot circumvent a newly enabled Wi-Fi-only preference.
    config.allowsCellularAccess = !LockScreenArtworkSettings.shared.value.wifiOnly
    config.allowsExpensiveNetworkAccess = !LockScreenArtworkSettings.shared.value.wifiOnly
    config.allowsConstrainedNetworkAccess = !LockScreenArtworkSettings.shared.value.wifiOnly
    let delegates = OperationQueue()
    delegates.maxConcurrentOperationCount = 1
    return URLSession(configuration: config, delegate: self, delegateQueue: delegates)
  }()
  private final class Job {
    let tier: LockScreenArtworkTier
    let stage: URL
    var index = 0
    var completedBytes: Int64 = 0
    private let taskLock = NSLock()
    private var ownedTask: URLSessionDownloadTask?
    var task: URLSessionDownloadTask? {
      get {
        taskLock.lock()
        defer { taskLock.unlock() }
        return ownedTask
      }
      set {
        taskLock.lock()
        ownedTask = newValue
        taskLock.unlock()
      }
    }
    let cancellation = LockScreenArtworkGeneration()
    init(tier: LockScreenArtworkTier, stage: URL) {
      self.tier = tier
      self.stage = stage
      cancellation.update(1)
    }
    var active: Bool { cancellation.contains(1) }
  }
  private var job: Job?
  private var liveJobs: [LockScreenArtworkTier: Job] = [:]

  init(directory: URL? = nil) {
    self.directory =
      directory
      ?? FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask)[0].appendingPathComponent("AonsokuArtworkModels", isDirectory: true)
    super.init()
    worker.async {
      try? self.makeDirectory(self.directory)
      // No in-progress job exists at startup. Recover interrupted exports.
      if let files = try? FileManager.default.contentsOfDirectory(
        at: self.directory,
        includingPropertiesForKeys: nil)
      {
        for file in files where file.lastPathComponent.hasPrefix("partial-") {
          try? FileManager.default.removeItem(at: file)
        }
      }
    }
    network.pathUpdateHandler = { [weak self] path in
      guard let self else { return }
      self.lock.lock()
      self.unmetered = path.status == .satisfied && !path.isExpensive && !path.isConstrained
      self.lock.unlock()
      self.worker.async { self.startNext() }
    }
    network.start(queue: worker)
  }

  private func folder(_ tier: LockScreenArtworkTier) -> URL {
    directory.appendingPathComponent(
      "\(LockScreenArtworkModelCatalog.revision)-\(tier.rawValue)", isDirectory: true)
  }
  func modelURL(_ tier: LockScreenArtworkTier) -> URL? {
    let folder = folder(tier)
    guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("ready.json").path),
      FileManager.default.fileExists(atPath: folder.appendingPathComponent("model.mlmodelc").path)
    else { return nil }
    return folder.appendingPathComponent("model.mlmodelc")
  }
  func availableTier(upTo tier: LockScreenArtworkTier) -> LockScreenArtworkTier? {
    let choices: [LockScreenArtworkTier] =
      tier == .fp16 ? [.fp16, .p8, .p6] : tier == .p8 ? [.p8, .p6] : [.p6]
    return choices.first { modelURL($0) != nil }
  }
  private func state(
    _ tier: LockScreenArtworkTier, _ phase: String,
    progress: Double = 0, error: String? = nil
  ) {
    lock.lock()
    var value: [String: Any] = ["status": phase, "progress": progress]
    if let error { value["error"] = error }
    states[tier] = value
    lock.unlock()
  }
  func snapshot() -> [[String: Any]] {
    lock.lock()
    let current = states
    lock.unlock()
    return LockScreenArtworkTier.allCases.map { tier in
      var info =
        current[tier] ?? [
          "status": modelURL(tier) == nil ? "notDownloaded" : "ready", "progress": 0,
        ]
      info["tier"] = tier.rawValue
      info["downloadBytes"] = LockScreenArtworkModelCatalog.bytes(tier)
      if let url = modelURL(tier),
        let enumerator = FileManager.default.enumerator(
          at: url,
          includingPropertiesForKeys: [.fileSizeKey])
      {
        info["storedBytes"] = enumerator.compactMap {
          ($0 as? URL).flatMap {
            try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize
          }
        }.reduce(0, +)
      } else {
        info["storedBytes"] = 0
      }
      return info
    }
  }
  func request(_ tier: LockScreenArtworkTier, automatic: Bool = false) {
    worker.async {
      if automatic {
        let options = LockScreenArtworkSettings.shared.value
        guard (options.immersiveEnabled && options.dynamicEnabled) || LockScreenArtworkDemand.shared.dynamicRequested else { return }
      }
      guard self.modelURL(tier) == nil else { return }
      self.lock.lock()
      let existing = self.states[tier]?["status"] as? String
      self.lock.unlock()
      if automatic && (self.blockedAutomatic.contains(tier) || existing == "error") { return }
      if !automatic { self.blockedAutomatic.remove(tier) }
      guard !self.pending.contains(tier), self.job?.tier != tier, self.deferred[tier] == nil else {
        return
      }
      self.pending.append(tier)
      self.state(tier, "queued")
      self.startNext()
    }
  }
  func cancel(_ tier: LockScreenArtworkTier) {
    // Cancel flag is visible even while the worker is waiting for Core ML.
    lock.lock()
    let live = liveJobs[tier]
    lock.unlock()
    live?.cancellation.update(0)
    live?.task?.cancel()
    worker.async {
      self.blockedAutomatic.insert(tier)
      self.pending.removeAll { $0 == tier }
      if let stage = self.deferred.removeValue(forKey: tier) {
        try? FileManager.default.removeItem(at: stage)
      }
      if self.job?.tier == tier {
        self.finish(error: nil, canceled: true)
      } else {
        self.state(tier, self.modelURL(tier) == nil ? "notDownloaded" : "ready")
      }
    }
  }
  func remove(_ tier: LockScreenArtworkTier) {
    cancel(tier)
    worker.async {
      self.blockedAutomatic.insert(tier)
      LockScreenArtworkDepthModel.exclusive {
        try? FileManager.default.removeItem(at: self.folder(tier))
      }
      self.state(tier, "notDownloaded")
      DispatchQueue.main.async { NotificationCenter.default.post(name: Self.ready, object: nil) }
    }
  }
  func preferencesChanged() {
    // Rebuild the session so a cellular policy change takes effect, and
    // restart only after the user explicitly changes download preferences.
    lock.lock()
    let jobs = Array(liveJobs.values)
    lock.unlock()
    jobs.forEach {
      $0.cancellation.update(0)
      $0.task?.cancel()
    }
    worker.async {
      for tier in self.pending { self.state(tier, "notDownloaded") }
      self.pending.removeAll()
      if self.job != nil { self.finish(error: nil, canceled: true) }
      self.session.invalidateAndCancel()
      self.session = self.newSession()
      self.resumeDeferred()
    }
  }

  func stopAutomaticGeneration() {
    lock.lock()
    let jobs = Array(liveJobs.values)
    lock.unlock()
    jobs.forEach {
      $0.cancellation.update(0)
      $0.task?.cancel()
    }
    worker.async {
      for tier in self.pending { self.state(tier, "notDownloaded") }
      self.pending.removeAll()
      if self.job != nil { self.finish(error: nil, canceled: true) }
      for (tier, stage) in self.deferred {
        try? FileManager.default.removeItem(at: stage)
        self.state(tier, "notDownloaded")
      }
      self.deferred.removeAll()
    }
  }
  private func newSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 300
    config.allowsCellularAccess = !LockScreenArtworkSettings.shared.value.wifiOnly
    config.allowsExpensiveNetworkAccess = !LockScreenArtworkSettings.shared.value.wifiOnly
    config.allowsConstrainedNetworkAccess = !LockScreenArtworkSettings.shared.value.wifiOnly
    let delegates = OperationQueue()
    delegates.maxConcurrentOperationCount = 1
    return URLSession(configuration: config, delegate: self, delegateQueue: delegates)
  }
  func resumeDeferred() {
    worker.async {
      if LockScreenArtworkMotionPolicy.shared.allowsGeneration {
        for (tier, stage) in Array(self.deferred) {
          self.deferred.removeValue(forKey: tier)
          let live = Job(tier: tier, stage: stage)
          self.lock.lock()
          self.liveJobs[tier] = live
          self.lock.unlock()
          self.compile(stage: stage, tier: tier, live: live)
          self.lock.lock()
          self.liveJobs.removeValue(forKey: tier)
          self.lock.unlock()
        }
      }
      self.startNext()
    }
  }
  private func startNext() {
    guard job == nil, let tier = pending.first else { return }
    lock.lock()
    let allowed = unmetered || !LockScreenArtworkSettings.shared.value.wifiOnly
    lock.unlock()
    guard allowed else {
      state(tier, "waitingForWifi")
      return
    }
    pending.removeFirst()
    let stage = directory.appendingPathComponent("partial-\(UUID().uuidString)", isDirectory: true)
    do {
      try makeDirectory(stage)
      let available = try? directory.resourceValues(forKeys: [
        .volumeAvailableCapacityForImportantUsageKey
      ]).volumeAvailableCapacityForImportantUsage
      if let available, available < LockScreenArtworkModelCatalog.bytes(tier) * 2 + 16 * 1024 * 1024
      {
        throw NSError(domain: "ArtworkModelDiskSpace", code: 1)
      }
      let next = Job(tier: tier, stage: stage)
      job = next
      lock.lock()
      liveJobs[tier] = next
      lock.unlock()
      downloadNext(next)
    } catch {
      try? FileManager.default.removeItem(at: stage)
      state(tier, "error", error: "\((error as NSError).domain):\((error as NSError).code)")
      startNext()
    }
  }
  private func makeDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    var target = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try target.setResourceValues(values)
    #if os(iOS)
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: url.path)
    #endif
  }
  private func downloadNext(_ live: Job) {
    guard live.active else {
      finish(error: nil, canceled: true)
      return
    }
    let files = LockScreenArtworkModelCatalog.files(live.tier)
    guard live.index < files.count else {
      if LockScreenArtworkMotionPolicy.shared.allowsGeneration {
        compile(stage: live.stage, tier: live.tier, live: live)
      } else {
        deferred[live.tier] = live.stage
        state(live.tier, "waitingForResources", progress: 1)
      }
      finish(error: nil, preserveStage: true)
      return
    }
    let file = files[live.index]
    let task = session.downloadTask(with: LockScreenArtworkModelCatalog.url(live.tier, file: file))
    live.task = task
    state(
      live.tier, "downloading",
      progress: Double(live.completedBytes) / Double(LockScreenArtworkModelCatalog.bytes(live.tier))
    )
    task.resume()
  }
  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) {
    worker.async {
      guard let live = self.job, live.task === downloadTask, live.active else { return }
      self.state(
        live.tier, "downloading",
        progress: min(
          1,
          Double(live.completedBytes + totalBytesWritten)
            / Double(LockScreenArtworkModelCatalog.bytes(live.tier))))
    }
  }
  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    // URLSession removes its temporary file when this delegate returns.
    worker.sync {
      guard let live = job, live.task === downloadTask, live.active else { return }
      do {
        guard let response = downloadTask.response as? HTTPURLResponse,
          (200..<300).contains(response.statusCode)
        else {
          throw NSError(
            domain: "ArtworkModelHTTP",
            code: (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let file = LockScreenArtworkModelCatalog.files(live.tier)[live.index]
        try LockScreenArtworkModelCatalog.verify(location, file: file)
        guard live.active else {
          finish(error: nil, canceled: true)
          return
        }
        let destination = live.stage.appendingPathComponent(
          LockScreenArtworkModelCatalog.package(live.tier)
        ).appendingPathComponent(file.path)
        try FileManager.default.createDirectory(
          at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: location, to: destination)
        live.completedBytes += file.bytes
        live.index += 1
        downloadNext(live)
      } catch { finish(error: error) }
    }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let error else { return }
    worker.async {
      guard self.job?.task === task else { return }
      self.finish(error: error, canceled: (error as NSError).code == NSURLErrorCancelled)
    }
  }
  private func compile(stage: URL, tier: LockScreenArtworkTier, live: Job?) {
    state(tier, "compiling", progress: 1)
    let measurement = LockScreenArtworkMeasurement("model-compile backend=\(tier.backend)")
    defer { measurement.finish("ready=\(modelURL(tier) != nil)") }
    do {
      try LockScreenArtworkDepthModel.exclusive {
        guard live?.active != false else { throw NSError(domain: "ArtworkModelCanceled", code: 1) }
        guard LockScreenArtworkMotionPolicy.shared.allowsGeneration else {
          throw NSError(domain: "ArtworkModelResources", code: 1)
        }
        let package = stage.appendingPathComponent(LockScreenArtworkModelCatalog.package(tier))
        let compiled = try MLModel.compileModel(at: package)
        defer { try? FileManager.default.removeItem(at: compiled) }
        guard live?.active != false else { throw NSError(domain: "ArtworkModelCanceled", code: 1) }
        let final = folder(tier)
        try? FileManager.default.removeItem(at: final)
        try makeDirectory(final)
        try FileManager.default.moveItem(
          at: compiled, to: final.appendingPathComponent("model.mlmodelc"))
        guard let license = LockScreenArtworkModelCatalog.licenseURL else {
          throw NSError(domain: "ArtworkModelLicense", code: 1)
        }
        try FileManager.default.copyItem(
          at: license, to: final.appendingPathComponent("LICENSE.txt"))
        let marker = try JSONSerialization.data(withJSONObject: [
          "revision": LockScreenArtworkModelCatalog.revision, "tier": tier.rawValue,
        ])
        try
          "Depth Anything V2 Small (Apple Core ML), Apache-2.0\nhttps://huggingface.co/apple/coreml-depth-anything-v2-small\n"
          .write(to: final.appendingPathComponent("NOTICE.txt"), atomically: true, encoding: .utf8)
        try marker.write(to: final.appendingPathComponent("ready.json"), options: .atomic)
      }
      try? FileManager.default.removeItem(at: stage)
      state(tier, "ready", progress: 1)
      DispatchQueue.main.async { NotificationCenter.default.post(name: Self.ready, object: nil) }
    } catch {
      if (error as NSError).domain == "ArtworkModelResources" {
        deferred[tier] = stage
        state(tier, "waitingForResources", progress: 1)
        return
      }
      try? FileManager.default.removeItem(at: stage)
      state(tier, "error", error: "\((error as NSError).domain):\((error as NSError).code)")
    }
  }
  private func finish(error: Error?, canceled: Bool = false, preserveStage: Bool = false) {
    guard let live = job else { return }
    if !preserveStage { try? FileManager.default.removeItem(at: live.stage) }
    if canceled {
      state(live.tier, "notDownloaded")
    } else if let error {
      state(live.tier, "error", error: "\((error as NSError).domain):\((error as NSError).code)")
    }
    lock.lock()
    liveJobs.removeValue(forKey: live.tier)
    lock.unlock()
    job = nil
    startNext()
  }
}
