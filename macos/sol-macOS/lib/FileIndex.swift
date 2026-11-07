import Foundation
import CoreServices
import ImageIO
import SQLite3

struct IndexedFile {
  let path: String
  let name: String
  let isFolder: Bool
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1 as Int, to: sqlite3_destructor_type?.self)

// What macOS reported during one replay. The stream callback fills it on
// replayQueue, and the walk queue reads it only after the stream has stopped.
private final class ReplayLog {
  var flagsByPath: [String: FSEventStreamEventFlags] = [:]
  var rescans = Set<String>()
  var latestEvent: FSEventStreamEventId?
  var idsWrapped = false
  let historyDone = DispatchSemaphore(value: 0)
}

// A search folder as stored, and as FSEvents names it after resolving links.
private struct FolderRoot {
  let stored: String
  let real: String
}

// How long macOS gets to read back its log before update rebuilds instead.
private let replayTimeout: DispatchTimeInterval = .seconds(60)
private let replaySettle: TimeInterval = 1

final class FileIndex {
  private let walkQueue = DispatchQueue(label: "com.ospfranco.sol.fileindex.walk")
  private let replayQueue = DispatchQueue(label: "com.ospfranco.sol.fileindex.replay")
  private let databasePath: String
  private let readLock = NSLock()
  private var writeDB: OpaquePointer?
  // Walks write on writeDB. Search uses readDB so a query can return while a
  // walk transaction is open. WAL is what makes that legal.
  private var readDB: OpaquePointer?
  private var searchFolders: [String] = []

  init(databaseURL: URL) {
    let directory = databaseURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    databasePath = databaseURL.path
    openDatabases()
    searchFolders = Array(recordedFolders())
  }

  static func applicationDatabaseURL() -> URL {
    let paths = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true)
    let appSupportDir = paths[0]
    let solDir = (appSupportDir as NSString).appendingPathComponent("Sol")
    try? FileManager.default.createDirectory(atPath: solDir, withIntermediateDirectories: true)
    let dbPath = (solDir as NSString).appendingPathComponent("filesearch.db")
    return URL(fileURLWithPath: dbPath)
  }

  // Launch calls this. It must stay free of walks and watchers: Sol does no
  // indexing unless Adrian asks for it, and an idle launcher costs nothing.
  func setSearchFolders(_ paths: [String]) {
    let folders = normalizeAll(paths)
    readLock.lock()
    searchFolders = folders
    readLock.unlock()
  }

  // Sol does not watch files. macOS keeps its own log of changes, so update
  // reads back only what happened since the last update. It rebuilds when
  // there is no checkpoint or the log cannot be replayed.
  func update(completion: @escaping () -> Void) {
    walkQueue.async { [weak self] in
      guard let self else {
        completion()
        return
      }
      let folders = self.currentFolders()
      if folders.isEmpty {
        completion()
        return
      }
      // Folders dropped by editing the settings file never reach
      // removeSearchFolder, and a folder that is gone sends no reliable event.
      for folder in self.recordedFolders() where !folders.contains(folder) {
        self.dropFolder(folder, remaining: folders)
      }
      for folder in folders where !FileManager.default.fileExists(atPath: folder) {
        self.deleteTree(folder)
      }
      if let since = self.checkpoint(),
        self.savedLogID() == self.eventLogID(folders),
        !self.hasUnfilledClocks(),
        self.replay(since: since, folders: folders)
      {
        let recorded = self.recordedFolders()
        for folder in folders where !recorded.contains(folder) {
          self.walk(folder)
          self.recordFolder(folder)
        }
      } else {
        self.rebuild(folders)
      }
      completion()
    }
  }

  // Reachable from tests because macOS cannot be made to drop events on cue.
  func rescan(eventPath: String, completion: @escaping () -> Void) {
    walkQueue.async { [weak self] in
      guard let self else {
        completion()
        return
      }
      let folders = self.currentFolders()
      self.rescanAll(eventPath: eventPath, folders: folders, roots: self.folderRoots(folders))
      completion()
    }
  }

  func addSearchFolder(_ path: String, completion: @escaping () -> Void) {
    let folder = normalize(path)
    walkQueue.async { [weak self] in
      guard let self else {
        completion()
        return
      }
      self.readLock.lock()
      if !self.searchFolders.contains(folder) {
        self.searchFolders.append(folder)
      }
      self.readLock.unlock()
      // An index with no rows has nothing older to catch up on, so this walk
      // can start its log. A populated index without a checkpoint keeps
      // having none, and the next update rebuilds it.
      if self.checkpoint() == nil && !self.hasRows() {
        self.saveCheckpoint(FSEventsGetCurrentEventId())
        self.saveLogID(self.eventLogID(self.currentFolders()))
      }
      self.walk(folder)
      self.recordFolder(folder)
      completion()
    }
  }

  // The off switch. Removes the files rather than emptying the tables, so
  // turning File search off gives the disk space back at once.
  func clear(completion: @escaping () -> Void) {
    walkQueue.async { [weak self] in
      guard let self else {
        completion()
        return
      }
      self.readLock.lock()
      defer { self.readLock.unlock() }
      sqlite3_close(self.readDB)
      sqlite3_close(self.writeDB)
      self.readDB = nil
      self.writeDB = nil
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: self.databasePath + suffix)
      }
      self.openDatabases()
      completion()
    }
  }

  func search(query: String) -> [IndexedFile] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return []
    }

    readLock.lock()
    defer { readLock.unlock() }
    guard let db = readDB else { return [] }

    var results: [(file: IndexedFile, score: CGFloat)] = []
    // Name matches fill the cap first. A later tier must not take a slot
    // from an earlier one, even when its fuzzy score is higher. A file that
    // matches more than one tier stays in the best tier once.
    results.append(contentsOf: ranked(nameMatches(db: db, query: trimmed)).prefix(100))
    if results.count >= 100 {
      return results.map(\.file)
    }

    let namePaths = Set(results.map(\.file.path))
    let byPath = ranked(pathMatches(
      db: db,
      query: trimmed,
      roots: searchFolders,
      excluding: namePaths
    ))
    results.append(contentsOf: byPath.prefix(100 - results.count))
    if results.count >= 100 {
      return results.map(\.file)
    }

    let taken = Set(results.map(\.file.path))
    let byClock = ranked(clockMatches(db: db, query: trimmed, excluding: taken))
    results.append(contentsOf: byClock.prefix(100 - results.count))
    return results.map(\.file)
  }

  func removeSearchFolder(_ path: String, completion: @escaping () -> Void) {
    let folder = normalize(path)
    walkQueue.async { [weak self] in
      guard let self else {
        completion()
        return
      }
      self.readLock.lock()
      self.searchFolders.removeAll { $0 == folder }
      let remaining = self.searchFolders
      self.readLock.unlock()
      self.dropFolder(folder, remaining: remaining)
      completion()
    }
  }

  deinit {
    if let writeDB {
      sqlite3_close(writeDB)
    }
    if let readDB {
      sqlite3_close(readDB)
    }
  }

  private func openDatabases() {
    writeDB = openDatabase(path: databasePath)
    createSchema()
    readDB = openDatabase(path: databasePath)
    if let readDB {
      sqlite3_exec(readDB, "PRAGMA query_only=ON;", nil, nil, nil)
    }
  }

  private func currentFolders() -> [String] {
    readLock.lock()
    defer { readLock.unlock() }
    return searchFolders
  }

  private func openDatabase(path: String) -> OpaquePointer? {
    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
      sqlite3_close(db)
      return nil
    }
    sqlite3_busy_timeout(db, 1000)
    sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
    sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
    return db
  }

  private func createSchema() {
    let sql = """
      CREATE TABLE IF NOT EXISTS files (
        path TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        is_folder INTEGER NOT NULL,
        parent_path TEXT,
        indexed_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        created_at REAL,
        modified_at REAL,
        clock_text TEXT,
        place_name TEXT
      );
      CREATE INDEX IF NOT EXISTS idx_name ON files(name);
      CREATE TABLE IF NOT EXISTS search_folders (
        path TEXT PRIMARY KEY
      );
      CREATE TABLE IF NOT EXISTS index_state (
        key TEXT PRIMARY KEY,
        value INTEGER NOT NULL
      );
    """
    exec(writeDB, sql)
    // An index created before clocks existed keeps its rows. New columns
    // stay null until a later walk fills them.
    exec(writeDB, "ALTER TABLE files ADD COLUMN created_at REAL;")
    exec(writeDB, "ALTER TABLE files ADD COLUMN modified_at REAL;")
    exec(writeDB, "ALTER TABLE files ADD COLUMN clock_text TEXT;")
    exec(writeDB, "ALTER TABLE files ADD COLUMN place_name TEXT;")
  }

  private func exec(_ db: OpaquePointer?, _ sql: String) {
    sqlite3_exec(db, sql, nil, nil, nil)
  }

  private func checkpoint() -> FSEventStreamEventId? {
    guard let db = writeDB else { return nil }
    var statement: OpaquePointer?
    let sql = "SELECT value FROM index_state WHERE key = 'checkpoint';"
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      return nil
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return FSEventStreamEventId(bitPattern: sqlite3_column_int64(statement, 0))
  }

  private func saveCheckpoint(_ event: FSEventStreamEventId) {
    guard let db = writeDB else { return }
    var statement: OpaquePointer?
    let sql = "INSERT OR REPLACE INTO index_state (key, value) VALUES ('checkpoint', ?);"
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      return
    }
    sqlite3_bind_int64(statement, 1, Int64(bitPattern: event))
    sqlite3_step(statement)
    sqlite3_finalize(statement)
  }

  private func savedLogID() -> String? {
    guard let db = writeDB else { return nil }
    var statement: OpaquePointer?
    let sql = "SELECT value FROM index_state WHERE key = 'log_id';"
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      return nil
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
      let text = sqlite3_column_text(statement, 0)
    else { return nil }
    return String(cString: text)
  }

  private func saveLogID(_ id: String) {
    guard let db = writeDB else { return }
    var statement: OpaquePointer?
    let sql = "INSERT OR REPLACE INTO index_state (key, value) VALUES ('log_id', ?);"
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      return
    }
    sqlite3_bind_text(statement, 1, id, -1, SQLITE_TRANSIENT)
    sqlite3_step(statement)
    sqlite3_finalize(statement)
  }

  // Event ids only mean something inside one macOS log. A reset log looks
  // like a quiet replay, so its identity is stored beside the checkpoint.
  private func eventLogID(_ folders: [String]) -> String {
    var ids = Set<String>()
    for folder in folders {
      var current = folder
      var info = stat()
      while stat(current, &info) != 0 && current != "/" {
        current = (current as NSString).deletingLastPathComponent
      }
      if let uuid = FSEventsCopyUUIDForDevice(info.st_dev),
        let text = CFUUIDCreateString(nil, uuid)
      {
        ids.insert(text as String)
      }
    }
    return ids.sorted().joined(separator: ",")
  }

  private func rebuild(_ folders: [String]) {
    // Taken before the walk, so a change made during it replays next time
    // instead of being lost.
    let start = FSEventsGetCurrentEventId()
    // Goes first. If Sol quits mid-walk, the next update must rebuild rather
    // than replay onto a partial index.
    exec(writeDB, "DELETE FROM index_state;")
    exec(writeDB, "DELETE FROM files;")
    for folder in folders {
      walk(folder)
    }
    replaceRecordedFolders(folders)
    saveCheckpoint(start)
    saveLogID(eventLogID(folders))
    exec(writeDB, "VACUUM;")
    exec(writeDB, "PRAGMA wal_checkpoint(TRUNCATE);")
  }

  private func hasRows() -> Bool {
    guard let db = writeDB else { return false }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT 1 FROM files LIMIT 1;", -1, &statement, nil) == SQLITE_OK else {
      return false
    }
    defer { sqlite3_finalize(statement) }
    return sqlite3_step(statement) == SQLITE_ROW
  }

  private func hasUnfilledClocks() -> Bool {
    guard let db = writeDB else { return false }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
      db,
      "SELECT 1 FROM files WHERE clock_text IS NULL LIMIT 1;",
      -1,
      &statement,
      nil
    ) == SQLITE_OK else {
      return false
    }
    defer { sqlite3_finalize(statement) }
    return sqlite3_step(statement) == SQLITE_ROW
  }

  private func recordedFolders() -> Set<String> {
    guard let db = writeDB else { return [] }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT path FROM search_folders;", -1, &statement, nil) == SQLITE_OK else {
      return []
    }
    defer { sqlite3_finalize(statement) }
    var folders: Set<String> = []
    while sqlite3_step(statement) == SQLITE_ROW {
      if let cPath = sqlite3_column_text(statement, 0) {
        folders.insert(String(cString: cPath))
      }
    }
    return folders
  }

  private func replaceRecordedFolders(_ folders: [String]) {
    exec(writeDB, "DELETE FROM search_folders;")
    for folder in folders {
      recordFolder(folder)
    }
  }

  private func recordFolder(_ folder: String) {
    guard let db = writeDB else { return }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO search_folders (path) VALUES (?);", -1, &statement, nil) == SQLITE_OK else {
      return
    }
    sqlite3_bind_text(statement, 1, folder, -1, SQLITE_TRANSIENT)
    sqlite3_step(statement)
    sqlite3_finalize(statement)
  }

  private func forgetFolder(_ folder: String) {
    guard let db = writeDB else { return }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "DELETE FROM search_folders WHERE path = ?;", -1, &statement, nil) == SQLITE_OK else {
      return
    }
    sqlite3_bind_text(statement, 1, folder, -1, SQLITE_TRANSIENT)
    sqlite3_step(statement)
    sqlite3_finalize(statement)
  }

  // A range on the primary key, because a LIKE reads every row. '0' is the
  // byte after '/', so the range is exactly the paths inside the folder.
  static let deleteTreeSQL = "DELETE FROM files WHERE path = ?1 OR (path >= ?2 AND path < ?3);"

  private func deleteTree(_ folder: String) {
    guard let db = writeDB else { return }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, FileIndex.deleteTreeSQL, -1, &statement, nil) == SQLITE_OK else {
      return
    }
    sqlite3_bind_text(statement, 1, folder, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(statement, 2, folder + "/", -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(statement, 3, folder + "0", -1, SQLITE_TRANSIENT)
    sqlite3_step(statement)
    sqlite3_finalize(statement)
  }

  private func dropFolder(_ folder: String, remaining: [String]) {
    deleteTree(folder)
    forgetFolder(folder)
    // Search folders can nest, so that delete may have taken rows another
    // folder still covers. No later event would bring them back.
    for other in remaining where folder.hasPrefix(other + "/") || other.hasPrefix(folder + "/") {
      walk(other)
    }
  }

  private func walk(_ root: String) {
    guard let db = writeDB else { return }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK else {
      return
    }
    defer { sqlite3_finalize(statement) }

    exec(db, "BEGIN IMMEDIATE;")
    var pending = [root]
    var batch = 0
    while !pending.isEmpty {
      let directory = pending.removeLast()
      let children = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
      for name in children {
        let path = (directory as NSString).appendingPathComponent(name)
        let info = inspect(path)
        if shouldSkip(name: name, info: info) {
          continue
        }
        autoreleasepool {
          insertFile(
            path: path,
            name: name,
            isFolder: info.isDirectory,
            parent: directory,
            statement: statement
          )
        }
        if info.isDirectory {
          pending.append(path)
        }
        batch += 1
        if batch >= 250 {
          exec(db, "COMMIT;")
          exec(db, "BEGIN IMMEDIATE;")
          batch = 0
        }
      }
    }
    exec(db, "COMMIT;")
  }

  private struct EntryInfo {
    var isDirectory: Bool
    var isPackage: Bool
    var isSymlink: Bool
  }

  private func inspect(_ path: String) -> EntryInfo {
    let url = URL(fileURLWithPath: path)
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
    guard let values = try? url.resourceValues(forKeys: keys) else {
      var isDir: ObjCBool = false
      let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
      return EntryInfo(isDirectory: exists && isDir.boolValue, isPackage: false, isSymlink: false)
    }
    let isSymlink = values.isSymbolicLink == true
    // A symlink that points at a directory must not be walked, or a link
    // back to a parent loops forever.
    let isDirectory = values.isDirectory == true && !isSymlink
    // isPackage is macOS's own decision. An extension list misses packages
    // the system recognizes and keeps ones it does not.
    let isPackage = isDirectory && values.isPackage == true
    return EntryInfo(isDirectory: isDirectory, isPackage: isPackage, isSymlink: isSymlink)
  }

  private func shouldSkip(name: String, info: EntryInfo) -> Bool {
    // A leading dot is a hidden name. Skip the entry and, when it is a
    // directory, do not descend. That keeps .env and the inside of .git out.
    if name.hasPrefix(".") {
      return true
    }
    if name == "node_modules" && (info.isDirectory || info.isSymlink) {
      return true
    }
    return info.isPackage
  }

  // Answers from the path alone, with no disk or database work. A build or a
  // git command writes thousands of these, and none can ever have a row.
  private func isNeverStored(_ path: String, folders: [String]) -> Bool {
    guard let root = innermostSearchRoot(containing: path, roots: folders) else {
      return true
    }
    return path.dropFirst(root.count).split(separator: "/").contains {
      $0.hasPrefix(".") || $0 == "node_modules"
    }
  }

  private func eventIsOmitted(_ path: String, folders: [String]) -> Bool {
    let url = URL(fileURLWithPath: path)
    let roots = Set(folders)
    var current = url
    while true {
      if roots.contains(current.path) {
        return false
      }
      let name = current.lastPathComponent
      if name.hasPrefix(".") {
        return true
      }
      let info = inspect(current.path)
      if info.isPackage || (name == "node_modules" && (info.isDirectory || info.isSymlink)) {
        return true
      }
      let parent = current.deletingLastPathComponent()
      if parent.path == current.path {
        return false
      }
      current = parent
    }
  }

  private let insertSQL = """
    INSERT OR REPLACE INTO files (
      path, name, is_folder, parent_path, created_at, modified_at, clock_text, place_name
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
    """

  private func upsert(path: String, name: String, isFolder: Bool, parent: String) {
    guard let db = writeDB else { return }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK else {
      return
    }
    insertFile(path: path, name: name, isFolder: isFolder, parent: parent, statement: statement)
    sqlite3_finalize(statement)
  }

  private func insertFile(
    path: String,
    name: String,
    isFolder: Bool,
    parent: String,
    statement: OpaquePointer?
  ) {
    let clock = clocks(at: path)
    let place = placeName(path: path, isFolder: isFolder)
    sqlite3_reset(statement)
    sqlite3_clear_bindings(statement)
    sqlite3_bind_text(statement, 1, path, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(statement, 2, name, -1, SQLITE_TRANSIENT)
    sqlite3_bind_int(statement, 3, isFolder ? 1 : 0)
    sqlite3_bind_text(statement, 4, parent, -1, SQLITE_TRANSIENT)
    bindOptionalDouble(statement, 5, clock.created)
    bindOptionalDouble(statement, 6, clock.modified)
    sqlite3_bind_text(statement, 7, clock.text, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(statement, 8, place, -1, SQLITE_TRANSIENT)
    sqlite3_step(statement)
  }

  // Reads back what macOS logged since `since`, then applies it. Returns false
  // when the log cannot be trusted, and the caller rebuilds.
  private func replay(since: FSEventStreamEventId, folders: [String]) -> Bool {
    let log = ReplayLog()
    // Taken before reading, so a quiet folder's checkpoint still moves and
    // later replays do not lean on ever older macOS history.
    let start = FSEventsGetCurrentEventId()
    let roots = folderRoots(folders)
    var context = FSEventStreamContext(
      version: 0,
      info: Unmanaged.passUnretained(log).toOpaque(),
      retain: nil,
      release: nil,
      copyDescription: nil
    )
    let flags = FSEventStreamCreateFlags(
      kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
    )
    guard let stream = FSEventStreamCreate(
      kCFAllocatorDefault,
      { _, info, numEvents, eventPaths, eventFlags, eventIds in
        guard let info else { return }
        let log = Unmanaged<ReplayLog>.fromOpaque(info).takeUnretainedValue()
        let cfPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
        guard let paths = cfPaths as? [String] else { return }
        for index in 0..<min(numEvents, paths.count) {
          FileIndex.record(paths[index], flags: eventFlags[index], id: eventIds[index], in: log)
        }
      },
      &context,
      roots.map(\.real) as CFArray,
      since,
      0,
      flags
    ) else { return false }

    FSEventStreamSetDispatchQueue(stream, replayQueue)
    guard FSEventStreamStart(stream) else {
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      return false
    }
    let finished = log.historyDone.wait(timeout: .now() + replayTimeout) == .success
    if finished {
      // macOS can report the end of its history while a change from a moment
      // ago is still in transit, and FlushSync alone does not wait for it.
      // Update is a rare, manual action, so a short wait costs nothing.
      Thread.sleep(forTimeInterval: replaySettle)
      FSEventStreamFlushSync(stream)
    }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    // Stop returned, but a callback can still be queued. This waits it out.
    replayQueue.sync {}

    if !finished || log.idsWrapped {
      return false
    }
    apply(log, folders: folders, roots: roots)
    saveCheckpoint(max(start, log.latestEvent ?? 0))
    return true
  }

  private static func record(
    _ path: String,
    flags: FSEventStreamEventFlags,
    id: FSEventStreamEventId,
    in log: ReplayLog
  ) {
    func has(_ flag: Int) -> Bool {
      flags & FSEventStreamEventFlags(flag) != 0
    }
    if has(kFSEventStreamEventFlagHistoryDone) {
      log.historyDone.signal()
      return
    }
    if has(kFSEventStreamEventFlagEventIdsWrapped) {
      log.idsWrapped = true
      return
    }
    log.latestEvent = max(log.latestEvent ?? 0, id)
    if has(kFSEventStreamEventFlagMustScanSubDirs)
      || has(kFSEventStreamEventFlagUserDropped)
      || has(kFSEventStreamEventFlagKernelDropped)
    {
      log.rescans.insert(path)
      return
    }
    // Keyed by path because a replay merges days of changes. The disk says
    // what is true now, so only the union of what happened matters.
    log.flagsByPath[path, default: 0] |= flags
  }

  private func apply(_ log: ReplayLog, folders: [String], roots: [FolderRoot]) {
    var arrivedFolders: [String] = []
    // One transaction, so a replay of many changes is one disk write.
    exec(writeDB, "BEGIN IMMEDIATE;")
    for (eventPath, flags) in log.flagsByPath {
      let path = storedPath(fromEvent: eventPath, roots: roots)
      if applyEvent(path: path, flags: flags, folders: folders) {
        arrivedFolders.append(path)
      }
    }
    exec(writeDB, "COMMIT;")
    // Rescans open their own transactions, so these wait for the commit.
    for folder in arrivedFolders {
      rescan(folder, folders: folders)
    }
    for eventPath in log.rescans {
      rescanAll(eventPath: eventPath, folders: folders, roots: roots)
    }
  }

  // macOS can report a drop at a parent of the search folders, even at /.
  // That covers every search folder under it.
  private func rescanAll(eventPath: String, folders: [String], roots: [FolderRoot]) {
    let prefix = eventPath.hasSuffix("/") ? eventPath : eventPath + "/"
    let below = roots.filter { $0.real.hasPrefix(prefix) || $0.stored.hasPrefix(prefix) }
    if !below.isEmpty {
      for root in below {
        rescan(root.stored, folders: folders)
      }
      return
    }
    rescan(storedPath(fromEvent: eventPath, roots: roots), folders: folders)
  }

  private func rescan(_ path: String, folders: [String]) {
    if isNeverStored(path, folders: folders) {
      return
    }
    guard FileManager.default.fileExists(atPath: path) else {
      deleteTree(path)
      return
    }
    if folders.contains(path) {
      deleteTree(path)
      walk(path)
      return
    }
    let name = (path as NSString).lastPathComponent
    let info = inspect(path)
    if eventIsOmitted(path, folders: folders) || shouldSkip(name: name, info: info) {
      deleteTree(path)
      return
    }
    // Delete first: a folder swapped in at this path must not keep the old
    // folder's children. A walk stores what is inside, never the folder.
    deleteTree(path)
    upsert(
      path: path,
      name: name,
      isFolder: info.isDirectory,
      parent: (path as NSString).deletingLastPathComponent
    )
    if info.isDirectory {
      walk(path)
    }
  }

  // Returns true when the path is a folder that just arrived, so its contents
  // need a walk. FSEvents reports only the folder when one is moved in.
  private func applyEvent(path: String, flags: FSEventStreamEventFlags, folders: [String]) -> Bool {
    if isNeverStored(path, folders: folders) {
      return false
    }
    let arrived = FSEventStreamEventFlags(
      kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed
    )
    // Trust the disk over the flags. Merged events on a saved file carry both
    // removed and created, and that file still exists.
    guard FileManager.default.fileExists(atPath: path) else {
      deleteTree(path)
      return false
    }
    if folders.contains(path) {
      return flags & arrived != 0
    }
    let name = (path as NSString).lastPathComponent
    let info = inspect(path)
    if eventIsOmitted(path, folders: folders) || shouldSkip(name: name, info: info) {
      deleteTree(path)
      return false
    }
    let parent = (path as NSString).deletingLastPathComponent
    upsert(path: path, name: name, isFolder: info.isDirectory, parent: parent)
    return flags & arrived != 0 && info.isDirectory
  }

  private func folderRoots(_ folders: [String]) -> [FolderRoot] {
    folders
      .map { FolderRoot(stored: $0, real: realPath($0)) }
      .sorted { $0.real.count > $1.real.count }
  }

  // A search folder that is gone still needs a real path, so this resolves
  // the deepest part that exists and keeps the rest.
  private func realPath(_ path: String) -> String {
    var current = path
    var rest: [String] = []
    while current != "/" {
      if let resolved = realpath(current, nil) {
        defer { free(resolved) }
        return ([String(cString: resolved)] + rest).joined(separator: "/")
      }
      rest.insert((current as NSString).lastPathComponent, at: 0)
      current = (current as NSString).deletingLastPathComponent
    }
    return path
  }

  // FSEvents names real paths, and rows store the path as configured. A
  // symlinked search folder or /var (really /private/var) differs between the
  // two, and normalize cannot help because it only works on paths that exist.
  private func storedPath(fromEvent eventPath: String, roots: [FolderRoot]) -> String {
    var path = eventPath
    if path.count > 1 && path.hasSuffix("/") {
      path.removeLast()
    }
    for root in roots {
      if path == root.real {
        return root.stored
      }
      if path.hasPrefix(root.real + "/") {
        return root.stored + path.dropFirst(root.real.count)
      }
    }
    return path
  }

  private func normalize(_ path: String) -> String {
    var path = (path as NSString).standardizingPath
    if path.count > 1 && path.hasSuffix("/") {
      path.removeLast()
    }
    return path
  }

  private func normalizeAll(_ paths: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for path in paths {
      let normalized = normalize(path)
      if seen.insert(normalized).inserted {
        result.append(normalized)
      }
    }
    return result
  }

  private func nameMatches(db: OpaquePointer, query: String) -> [(file: IndexedFile, score: CGFloat)] {
    let sql = "SELECT path, name, is_folder FROM files WHERE name LIKE ? ESCAPE '\\'"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      return []
    }
    defer { sqlite3_finalize(statement) }

    let pattern = "%" + escapeLike(query) + "%"
    sqlite3_bind_text(statement, 1, pattern, -1, SQLITE_TRANSIENT)

    var matches: [(file: IndexedFile, score: CGFloat)] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let file = readIndexedFile(statement) else { continue }
      guard file.name.range(of: query, options: .caseInsensitive) != nil else { continue }
      let score = (file.name as NSString).scoreAgainst(query)
      matches.append((file, score))
    }
    return matches
  }

  // A path match is a case-insensitive contains on a folder name strictly
  // inside the search folder. The search folder's own last component does
  // not count: a file directly inside Documents does not match "documents".
  // The score is that folder's scoreAgainst the query. When several ancestor
  // folders contain the query, the highest score wins, so a short folder
  // outranks a long one that merely contains it.
  private func pathMatches(
    db: OpaquePointer,
    query: String,
    roots: [String],
    excluding namePaths: Set<String>
  ) -> [(file: IndexedFile, score: CGFloat)] {
    let folders = matchingFolders(db: db, query: query, roots: roots)
    if folders.isEmpty {
      return []
    }

    var best: [String: (file: IndexedFile, score: CGFloat)] = [:]
    for folder in folders {
      for file in files(under: folder.path, db: db) {
        if namePaths.contains(file.path) { continue }
        if let current = best[file.path], current.score >= folder.score { continue }
        best[file.path] = (file, folder.score)
      }
    }
    return Array(best.values)
  }

  private struct ScoredFolder {
    let path: String
    let score: CGFloat
  }

  private func matchingFolders(db: OpaquePointer, query: String, roots: [String]) -> [ScoredFolder] {
    if roots.isEmpty { return [] }
    let sql = "SELECT path, name FROM files WHERE is_folder = 1 AND name LIKE ? ESCAPE '\\'"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      return []
    }
    defer { sqlite3_finalize(statement) }

    let pattern = "%" + escapeLike(query) + "%"
    sqlite3_bind_text(statement, 1, pattern, -1, SQLITE_TRANSIENT)

    var folders: [ScoredFolder] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let cPath = sqlite3_column_text(statement, 0),
            let cName = sqlite3_column_text(statement, 1) else {
        continue
      }
      let path = String(cString: cPath)
      let name = String(cString: cName)
      guard name.range(of: query, options: .caseInsensitive) != nil else { continue }
      // The innermost search folder is the boundary. Its own name is not a
      // path match, and a wider search folder that contains it is not either.
      guard isStrictlyInsideSearchRoot(path, roots: roots) else { continue }
      folders.append(ScoredFolder(
        path: path,
        score: (name as NSString).scoreAgainst(query)
      ))
    }
    return folders
  }

  private func files(under folder: String, db: OpaquePointer) -> [IndexedFile] {
    let sql = "SELECT path, name, is_folder FROM files WHERE path LIKE ? ESCAPE '\\'"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      return []
    }
    defer { sqlite3_finalize(statement) }

    let pattern = escapeLike(folder) + "/%"
    sqlite3_bind_text(statement, 1, pattern, -1, SQLITE_TRANSIENT)

    var files: [IndexedFile] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      if let file = readIndexedFile(statement) {
        files.append(file)
      }
    }
    return files
  }

  private func isStrictlyInsideSearchRoot(_ path: String, roots: [String]) -> Bool {
    guard let root = innermostSearchRoot(containing: path, roots: roots) else { return false }
    return path.hasPrefix(root + "/")
  }

  private func innermostSearchRoot(containing path: String, roots: [String]) -> String? {
    var best: String?
    for root in roots where !root.isEmpty {
      let contains = path == root || path.hasPrefix(root + "/")
      guard contains else { continue }
      if let current = best, root.count <= current.count { continue }
      best = root
    }
    return best
  }

  private func readIndexedFile(_ statement: OpaquePointer?) -> IndexedFile? {
    guard let statement,
          let cPath = sqlite3_column_text(statement, 0),
          let cName = sqlite3_column_text(statement, 1) else {
      return nil
    }
    return IndexedFile(
      path: String(cString: cPath),
      name: String(cString: cName),
      isFolder: sqlite3_column_int(statement, 2) != 0
    )
  }

  // clock_text is local civil time for both clocks: "yyyy", English "MMMM",
  // "yyyy-MM-dd", and 24-hour "HH:mm". Relative words are absent on purpose,
  // so a query of yesterday cannot match a file just because of when it was
  // written. The English month is fixed so a non-English locale still
  // matches the form the file search promises.
  private func clockMatches(
    db: OpaquePointer,
    query: String,
    excluding taken: Set<String>
  ) -> [(file: IndexedFile, score: CGFloat)] {
    let sql = """
      SELECT path, name, is_folder, clock_text, place_name FROM files
      WHERE clock_text LIKE ? ESCAPE '\\' OR place_name LIKE ? ESCAPE '\\'
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      return []
    }
    defer { sqlite3_finalize(statement) }

    let pattern = "%" + escapeLike(query) + "%"
    sqlite3_bind_text(statement, 1, pattern, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(statement, 2, pattern, -1, SQLITE_TRANSIENT)

    var matches: [(file: IndexedFile, score: CGFloat)] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let file = readIndexedFile(statement) else { continue }
      if taken.contains(file.path) { continue }
      var score: CGFloat = 0
      var matched = false
      if let cText = sqlite3_column_text(statement, 3) {
        let text = String(cString: cText)
        if text.range(of: query, options: .caseInsensitive) != nil {
          matched = true
          score = max(score, bestTokenScore(text, query: query))
        }
      }
      if let cPlace = sqlite3_column_text(statement, 4) {
        let place = String(cString: cPlace)
        if place.range(of: query, options: .caseInsensitive) != nil {
          matched = true
          score = max(score, bestTokenScore(place, query: query))
        }
      }
      if matched {
        matches.append((file, score))
      }
    }
    return matches
  }

  // The clock string carries two clocks, so the month is not the whole
  // string. Score each token and keep the best, or "May" loses to a longer
  // place that merely starts with those letters.
  private func bestTokenScore(_ text: String, query: String) -> CGFloat {
    var best: CGFloat = (text as NSString).scoreAgainst(query)
    for token in text.split(whereSeparator: { $0.isWhitespace }) {
      best = max(best, (String(token) as NSString).scoreAgainst(query))
    }
    return best
  }

  // A place name is read only for a photo, a video, an audio file, or a map
  // link, and only when the file already carries one. Coordinates are not a
  // place: GPS and ISO 6709 strings are ignored, and nothing is geocoded.
  private func placeName(path: String, isFolder: Bool) -> String {
    if isFolder { return "" }
    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
    let raw: String
    switch ext {
    case "jpg", "jpeg", "png", "gif", "tif", "tiff", "heic", "heif", "webp", "bmp":
      raw = imagePlaceName(path)
    case "mov", "mp4", "m4v", "avi", "mkv", "mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "caf":
      raw = mediaPlaceName(path)
    case "webloc", "inetloc":
      raw = mapLinkPlaceName(path)
    default:
      return ""
    }
    if raw.isEmpty || isCoordinate(raw) { return "" }
    return raw
  }

  private func imagePlaceName(_ path: String) -> String {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] else {
      return ""
    }
    let keys = [
      kCGImagePropertyIPTCCity,
      kCGImagePropertyIPTCProvinceState,
      kCGImagePropertyIPTCCountryPrimaryLocationName,
    ]
    return keys.compactMap { key in
      (iptc[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty && !isCoordinate($0) }.joined(separator: " ")
  }

  private func mediaPlaceName(_ path: String) -> String {
    guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
    defer { try? handle.close() }
    let edge = 4 * 1024 * 1024
    let prefix = handle.readData(ofLength: edge)
    let end = handle.seekToEndOfFile()
    let data: Data
    if end > UInt64(edge) {
      let offset = end > UInt64(edge * 2) ? end - UInt64(edge) : UInt64(edge)
      handle.seek(toFileOffset: offset)
      data = prefix + handle.readDataToEndOfFile()
    } else {
      data = prefix
    }
    return quickTimePlaceName(data)
  }

  private func mapLinkPlaceName(_ path: String) -> String {
    let url = URL(fileURLWithPath: path)
    guard let dict = NSDictionary(contentsOf: url),
          let raw = dict["URL"] as? String,
          let components = URLComponents(string: raw) else {
      return ""
    }
    let named = ["q", "query", "address", "near"]
    if let items = components.queryItems {
      for name in named {
        guard let value = items.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value else {
          continue
        }
        let place = value.replacingOccurrences(of: "+", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !place.isEmpty && !isCoordinate(place) { return place }
      }
    }
    let parts = components.path.split(separator: "/").map(String.init)
    if let index = parts.firstIndex(of: "place"), index + 1 < parts.count {
      let place = (parts[index + 1].removingPercentEncoding ?? parts[index + 1])
        .replacingOccurrences(of: "+", with: " ")
      if !place.isEmpty && !isCoordinate(place) { return place }
    }
    return ""
  }

  private func isCoordinate(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let patterns = [
      #"^[+-]?\d+(\.\d+)?\s*,\s*[+-]?\d+(\.\d+)?$"#,
      #"^[+-]\d+(\.\d+)?[+-]\d+(\.\d+)?"#,
    ]
    return patterns.contains { trimmed.range(of: $0, options: .regularExpression) != nil }
  }

  private func quickTimePlaceName(_ data: Data) -> String {
    let bytes = [UInt8](data)
    let marker = Array("keys".utf8)
    var index = 4
    while index + 4 <= bytes.count {
      if bytes[index] == marker[0], bytes[index + 1] == marker[1],
         bytes[index + 2] == marker[2], bytes[index + 3] == marker[3],
         let place = placeName(inKeysBox: bytes, sizeAt: index - 4) {
        return place
      }
      index += 1
    }
    return ""
  }

  private func placeName(inKeysBox bytes: [UInt8], sizeAt: Int) -> String? {
    guard let size = u32(bytes, sizeAt), size >= 24, size < 1_000_000, sizeAt + size <= bytes.count else {
      return nil
    }
    let header = sizeAt + 8
    guard let count = u32(bytes, header + 4), count > 0, count < 10_000 else { return nil }
    var cursor = header + 8
    let end = sizeAt + size
    let wanted = Array("com.apple.quicktime.location.name".utf8)
    var placeIndex: Int?
    for keyIndex in 1...count {
      guard let entrySize = u32(bytes, cursor), entrySize >= 8, cursor + entrySize <= end else { return nil }
      let value = Array(bytes[(cursor + 8)..<(cursor + entrySize)])
      if value == wanted { placeIndex = keyIndex }
      cursor += entrySize
    }
    guard let placeIndex else { return nil }
    guard let raw = ilstValue(bytes, keyIndex: placeIndex) else { return nil }
    if raw.isEmpty || isCoordinate(raw) { return nil }
    return raw
  }

  private func ilstValue(_ bytes: [UInt8], keyIndex: Int) -> String? {
    let marker = Array("ilst".utf8)
    var index = 4
    while index + 4 <= bytes.count {
      let isIlst = bytes[index] == marker[0] && bytes[index + 1] == marker[1]
        && bytes[index + 2] == marker[2] && bytes[index + 3] == marker[3]
      if isIlst, let size = u32(bytes, index - 4), size >= 8, index - 4 + size <= bytes.count {
        var itemAt = index + 4
        let ilstEnd = index - 4 + size
        while itemAt + 8 <= ilstEnd {
          guard let itemSize = u32(bytes, itemAt), itemSize >= 8, itemAt + itemSize <= ilstEnd else { break }
          if u32(bytes, itemAt + 4) == keyIndex, let value = dataAtomString(bytes, itemAt: itemAt, itemEnd: itemAt + itemSize) {
            return value
          }
          itemAt += itemSize
        }
      }
      index += 1
    }
    return nil
  }

  private func dataAtomString(_ bytes: [UInt8], itemAt: Int, itemEnd: Int) -> String? {
    let marker = Array("data".utf8)
    var child = itemAt + 8
    while child + 16 <= itemEnd {
      guard let childSize = u32(bytes, child), childSize >= 16, child + childSize <= itemEnd else { break }
      let type = Array(bytes[(child + 4)..<(child + 8)])
      if type == marker {
        let payload = bytes[(child + 16)..<(child + childSize)]
        return String(bytes: payload, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      child += childSize
    }
    return nil
  }

  private func u32(_ bytes: [UInt8], _ offset: Int) -> Int? {
    guard offset >= 0, offset + 4 <= bytes.count else { return nil }
    return (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16)
      | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
  }

  private struct ClockRecord {
    var created: Double?
    var modified: Double?
    var text: String
  }

  private func clocks(at path: String) -> ClockRecord {
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    let created = attrs?[.creationDate] as? Date
    let modified = attrs?[.modificationDate] as? Date
    return ClockRecord(
      created: created?.timeIntervalSince1970,
      modified: modified?.timeIntervalSince1970,
      text: clockText(created: created, modified: modified)
    )
  }

  private func clockText(created: Date?, modified: Date?) -> String {
    [created, modified].compactMap { $0 }.map(civilClock).joined(separator: " ")
  }

  private let englishMonths = [
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
  ]

  private func civilClock(_ date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    let year = parts.year ?? 0
    let month = parts.month ?? 1
    let day = parts.day ?? 1
    let hour = parts.hour ?? 0
    let minute = parts.minute ?? 0
    let monthName = englishMonths[max(0, min(month - 1, englishMonths.count - 1))]
    let calendarDate = String(format: "%04d-%02d-%02d", year, month, day)
    let hourMinute = String(format: "%02d:%02d", hour, minute)
    return "\(year) \(monthName) \(calendarDate) \(hourMinute)"
  }

  private func bindOptionalDouble(_ statement: OpaquePointer?, _ index: Int32, _ value: Double?) {
    if let value {
      sqlite3_bind_double(statement, index, value)
    } else {
      sqlite3_bind_null(statement, index)
    }
  }

  private func ranked(_ matches: [(file: IndexedFile, score: CGFloat)]) -> [(file: IndexedFile, score: CGFloat)] {
    matches.sorted { lhs, rhs in
      if lhs.score != rhs.score {
        return lhs.score > rhs.score
      }
      return lhs.file.name < rhs.file.name
    }
  }

  private func escapeLike(_ value: String) -> String {
    var escaped = ""
    for character in value {
      if character == "\\" || character == "%" || character == "_" {
        escaped.append("\\")
      }
      escaped.append(character)
    }
    return escaped
  }
}
