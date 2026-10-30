import Foundation
import CoreServices
import SQLite3

struct IndexedFile {
  let path: String
  let name: String
  let isFolder: Bool
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1 as Int, to: sqlite3_destructor_type?.self)

final class FileIndex {
  private let walkQueue = DispatchQueue(label: "com.ospfranco.sol.fileindex.walk")
  private let eventQueue = DispatchQueue(label: "com.ospfranco.sol.fileindex.events")
  private let readLock = NSLock()
  private var writeDB: OpaquePointer?
  // Walks write on writeDB. Search uses readDB so a query can return while a
  // walk transaction is open. WAL is what makes that legal.
  private var readDB: OpaquePointer?
  private var searchFolders: [String] = []
  private var eventStream: FSEventStreamRef?

  init(databaseURL: URL) {
    let directory = databaseURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = databaseURL.path
    writeDB = openDatabase(path: path)
    createSchema()
    readDB = openDatabase(path: path)
    if let readDB {
      sqlite3_exec(readDB, "PRAGMA query_only=ON;", nil, nil, nil)
    }
  }

  static func applicationDatabaseURL() -> URL {
    let paths = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true)
    let appSupportDir = paths[0]
    let solDir = (appSupportDir as NSString).appendingPathComponent("Sol")
    try? FileManager.default.createDirectory(atPath: solDir, withIntermediateDirectories: true)
    let dbPath = (solDir as NSString).appendingPathComponent("filesearch.db")
    return URL(fileURLWithPath: dbPath)
  }

  func setSearchFolders(_ paths: [String], completion: @escaping () -> Void) {
    let folders = normalizeAll(paths)
    walkQueue.async { [weak self] in
      guard let self else {
        completion()
        return
      }
      self.searchFolders = folders
      self.startWatching(folders)
      let recorded = self.recordedFolders()
      if !self.hasRows() {
        for folder in folders {
          self.walk(folder)
        }
        self.replaceRecordedFolders(folders)
      } else if recorded.isEmpty {
        // Files are already stored, but this database has no record of which
        // search folders were walked. That is an index from before this
        // module. Watch it. Walking here would redo the user's index.
        self.replaceRecordedFolders(folders)
      } else {
        for folder in folders where !recorded.contains(folder) {
          self.walk(folder)
          self.recordFolder(folder)
        }
      }
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

    let sql = "SELECT path, name, is_folder FROM files WHERE name LIKE ? ESCAPE '\\'"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      return []
    }
    defer { sqlite3_finalize(statement) }

    let pattern = "%" + escapeLike(trimmed) + "%"
    sqlite3_bind_text(statement, 1, pattern, -1, SQLITE_TRANSIENT)

    var scored: [(file: IndexedFile, score: CGFloat)] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let cPath = sqlite3_column_text(statement, 0),
            let cName = sqlite3_column_text(statement, 1) else {
        continue
      }
      let path = String(cString: cPath)
      let name = String(cString: cName)
      guard name.range(of: trimmed, options: .caseInsensitive) != nil else {
        continue
      }
      let isFolder = sqlite3_column_int(statement, 2) != 0
      let score = (name as NSString).scoreAgainst(trimmed)
      scored.append((
        IndexedFile(path: path, name: name, isFolder: isFolder),
        score
      ))
    }

    scored.sort { lhs, rhs in
      if lhs.score != rhs.score {
        return lhs.score > rhs.score
      }
      return lhs.file.name < rhs.file.name
    }
    return scored.prefix(100).map(\.file)
  }

  func reindex(completion: @escaping () -> Void) {
    walkQueue.async { [weak self] in
      guard let self else {
        completion()
        return
      }
      self.exec(self.writeDB, "DELETE FROM files;")
      for folder in self.searchFolders {
        self.walk(folder)
      }
      self.replaceRecordedFolders(self.searchFolders)
      completion()
    }
  }

  func removeSearchFolder(_ path: String, completion: @escaping () -> Void) {
    let folder = normalize(path)
    walkQueue.async { [weak self] in
      guard let self else {
        completion()
        return
      }
      self.searchFolders.removeAll { $0 == folder }
      self.deleteTree(folder)
      self.forgetFolder(folder)
      self.startWatching(self.searchFolders)
      completion()
    }
  }

  deinit {
    stopWatching()
    if let writeDB {
      sqlite3_close(writeDB)
    }
    if let readDB {
      sqlite3_close(readDB)
    }
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
        indexed_at DATETIME DEFAULT CURRENT_TIMESTAMP
      );
      CREATE INDEX IF NOT EXISTS idx_name ON files(name);
      CREATE TABLE IF NOT EXISTS search_folders (
        path TEXT PRIMARY KEY
      );
    """
    exec(writeDB, sql)
  }

  private func exec(_ db: OpaquePointer?, _ sql: String) {
    sqlite3_exec(db, sql, nil, nil, nil)
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

  private func deleteTree(_ folder: String) {
    guard let db = writeDB else { return }
    let sql = "DELETE FROM files WHERE path = ? OR path LIKE ? ESCAPE '\\';"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      return
    }
    sqlite3_bind_text(statement, 1, folder, -1, SQLITE_TRANSIENT)
    let pattern = escapeLike(folder) + "/%"
    sqlite3_bind_text(statement, 2, pattern, -1, SQLITE_TRANSIENT)
    sqlite3_step(statement)
    sqlite3_finalize(statement)
  }

  private func walk(_ root: String) {
    guard let db = writeDB else { return }
    let sql = "INSERT OR REPLACE INTO files (path, name, is_folder, parent_path) VALUES (?, ?, ?, ?);"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
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
          sqlite3_reset(statement)
          sqlite3_clear_bindings(statement)
          sqlite3_bind_text(statement, 1, path, -1, SQLITE_TRANSIENT)
          sqlite3_bind_text(statement, 2, name, -1, SQLITE_TRANSIENT)
          sqlite3_bind_int(statement, 3, info.isDirectory ? 1 : 0)
          sqlite3_bind_text(statement, 4, directory, -1, SQLITE_TRANSIENT)
          sqlite3_step(statement)
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

  private func eventIsOmitted(_ path: String) -> Bool {
    let url = URL(fileURLWithPath: path)
    if url.pathComponents.contains("node_modules") {
      return true
    }
    let roots = Set(searchFolders)
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

  private func upsert(path: String, name: String, isFolder: Bool, parent: String) {
    guard let db = writeDB else { return }
    let sql = "INSERT OR REPLACE INTO files (path, name, is_folder, parent_path) VALUES (?, ?, ?, ?);"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      return
    }
    sqlite3_bind_text(statement, 1, path, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(statement, 2, name, -1, SQLITE_TRANSIENT)
    sqlite3_bind_int(statement, 3, isFolder ? 1 : 0)
    sqlite3_bind_text(statement, 4, parent, -1, SQLITE_TRANSIENT)
    sqlite3_step(statement)
    sqlite3_finalize(statement)
  }

  private func startWatching(_ paths: [String]) {
    stopWatching()
    guard !paths.isEmpty else { return }

    let pathsCF = paths as CFArray
    var context = FSEventStreamContext(
      version: 0,
      info: Unmanaged.passUnretained(self).toOpaque(),
      retain: nil,
      release: nil,
      copyDescription: nil
    )

    // Coalesce a burst of changes. kFSEventStreamCreateFlagNoDefer ignores
    // this latency on local disks, so leave it off.
    let flags = FSEventStreamCreateFlags(
      kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
    )
    guard let stream = FSEventStreamCreate(
      kCFAllocatorDefault,
      { _, info, numEvents, eventPaths, eventFlags, _ in
        guard let info else { return }
        let index = Unmanaged<FileIndex>.fromOpaque(info).takeUnretainedValue()
        let cfPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
        guard let paths = cfPaths as? [String] else { return }
        let flags = Array(UnsafeBufferPointer(start: eventFlags, count: numEvents))
        index.handleEvents(paths: paths, flags: flags)
      },
      &context,
      pathsCF,
      FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
      0.5,
      flags
    ) else { return }

    eventStream = stream
    FSEventStreamSetDispatchQueue(stream, eventQueue)
    FSEventStreamStart(stream)
  }

  private func stopWatching() {
    guard let stream = eventStream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    eventStream = nil
  }

  private func handleEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
    walkQueue.async { [weak self] in
      guard let self else { return }
      for (path, flag) in zip(paths, flags) {
        self.applyEvent(path: path, flags: flag)
      }
    }
  }

  private func applyEvent(path: String, flags: FSEventStreamEventFlags) {
    let removed = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0
    let renamed = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0
    let fileManager = FileManager.default
    if removed || (renamed && !fileManager.fileExists(atPath: path)) {
      deleteTree(path)
      return
    }
    guard fileManager.fileExists(atPath: path) else { return }
    if eventIsOmitted(path) {
      deleteTree(path)
      return
    }
    let name = (path as NSString).lastPathComponent
    let info = inspect(path)
    if shouldSkip(name: name, info: info) {
      deleteTree(path)
      return
    }
    let parent = (path as NSString).deletingLastPathComponent
    upsert(path: path, name: name, isFolder: info.isDirectory, parent: parent)
    let created = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0
    if created && info.isDirectory {
      walk(path)
    }
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
