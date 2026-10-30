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

  func setSearchFolders(_ paths: [String], completion: @escaping () -> Void) {
    let folders = normalizeAll(paths)
    walkQueue.async { [weak self] in
      guard let self else {
        completion()
        return
      }
      self.readLock.lock()
      self.searchFolders = folders
      self.readLock.unlock()
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
      self.readLock.lock()
      self.searchFolders.removeAll { $0 == folder }
      let remaining = self.searchFolders
      self.readLock.unlock()
      self.deleteTree(folder)
      self.forgetFolder(folder)
      self.startWatching(remaining)
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
