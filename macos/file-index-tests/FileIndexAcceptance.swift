import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import SQLite3

// Lead-authored acceptance tests for ticket 01. The implementer must not edit
// this file. The module under test is FileIndex. Construct it with a database
// URL. Do not use a process-wide singleton here.
//
// Contract:
// - setSearchFolders only records the folders. It never walks, never watches.
// - Nothing changes the stored files until update, addSearchFolder,
//   removeSearchFolder, or clear is called.
// - update replays what macOS logged since the saved checkpoint. With no
//   checkpoint it rebuilds: forget the stored files, walk, compact.
// - addSearchFolder walks that one folder and no other.
// - clear deletes the database's contents and leaves the index usable.
// - search may run while a walk is in progress and must return without waiting
//   for that walk to finish.
// - A name match is a case-insensitive contains on the file name. This ticket
//   does not score folder names.
// - Among name matches, the higher fuzzy score ranks first.
// - One search returns at most 100 files.
// - An empty query returns no files.
// - removeSearchFolder drops that folder's files.
// - A directory named node_modules, and a directory macOS treats as a package,
//   is not stored, and neither are its contents.
// - A year, an English month name, a calendar date yyyy-MM-dd, or a 24-hour
//   HH:mm matches the file's creation time or its modification time. Those
//   four forms are the file's local civil time. yesterday does not match on
//   the clock alone.
// - A date match ranks below every path match and every name match.
// - A file that matches its name and its date appears once, as a name match.
// - A photo's IPTC city, a video or audio file's QuickTime location.name,
//   and the place named by a map link all match. An ordinary file, a file
//   with no place name, and a coordinate string do not.
// - A place match sits in the same tier as a date match, below path and
//   name. A file that also matches a better tier appears once, in that tier.
// - A database stored before clock and place columns existed stays as it is
//   on open. The first update rebuilds it. After that, a date query and a
//   place query find those files, and a later open does not walk.

private var failures: [String] = []

private func check(_ condition: Bool, _ message: String) {
  if !condition {
    failures.append(message)
    fputs("FAIL \(message)\n", stderr)
  }
}

private func waitFor(_ start: (@escaping () -> Void) -> Void) {
  let semaphore = DispatchSemaphore(value: 0)
  start { semaphore.signal() }
  if semaphore.wait(timeout: .now() + 120) != .success {
    check(false, "timed out waiting for the file index")
  }
}

private func indexNow(_ store: FileIndex, _ folders: [String]) {
  store.setSearchFolders(folders)
  waitFor { store.update(completion: $0) }
}

private func pause(_ seconds: TimeInterval) {
  Thread.sleep(forTimeInterval: seconds)
}

// A row no walk would keep. It survives only when update replays changes
// instead of rebuilding, which is how these tests tell the two apart.
private func insertGhost(at root: URL, path: String) {
  var db: OpaquePointer?
  guard sqlite3_open(root.appendingPathComponent("filesearch.db").path, &db) == SQLITE_OK else {
    check(false, "could not open the database for a ghost row")
    return
  }
  defer { sqlite3_close(db) }
  let name = (path as NSString).lastPathComponent
  let parent = (path as NSString).deletingLastPathComponent
  let sql = """
    INSERT INTO files (path, name, is_folder, parent_path, clock_text, place_name)
    VALUES ('\(path)', '\(name)', 0, '\(parent)', '', '');
    """
  check(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "could not insert a ghost row")
}

private func makeRoot() -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("file-index-\(UUID().uuidString)", isDirectory: true)
  try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root
}

private func write(_ root: URL, _ relative: String, _ contents: String = "x") {
  let url = root.appendingPathComponent(relative)
  try! FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try! contents.write(to: url, atomically: true, encoding: .utf8)
}

private func index(at root: URL) -> FileIndex {
  FileIndex(databaseURL: root.appendingPathComponent("filesearch.db"))
}

private func localDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = .current
  return calendar.date(from: DateComponents(
    year: year, month: month, day: day, hour: hour, minute: minute
  ))!
}

private func calendarDate(_ date: Date) -> String {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = .current
  let parts = calendar.dateComponents([.year, .month, .day], from: date)
  return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
}

private func writePhoto(_ root: URL, _ relative: String, city: String?, latitude: Double? = nil) {
  let url = root.appendingPathComponent(relative)
  try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  let space = CGColorSpaceCreateDeviceRGB()
  let context = CGContext(
    data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
  )!
  let image = context.makeImage()!
  let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
  var props: [CFString: Any] = [:]
  if let city {
    props[kCGImagePropertyIPTCDictionary] = [kCGImagePropertyIPTCCity: city]
  }
  if let latitude {
    props[kCGImagePropertyGPSDictionary] = [
      kCGImagePropertyGPSLatitude: latitude,
      kCGImagePropertyGPSLongitude: 2.3522,
    ]
  }
  CGImageDestinationAddImage(dest, image, props as CFDictionary)
  if !CGImageDestinationFinalize(dest) {
    check(false, "could not write \(relative)")
  }
}

private func placeBoxes(_ name: String) -> Data {
  func be32(_ n: Int) -> Data {
    var v = UInt32(n).bigEndian
    return Data(bytes: &v, count: 4)
  }
  let key = Data("com.apple.quicktime.location.name".utf8)
  var entry = be32(8 + key.count)
  entry.append(contentsOf: "mdta".utf8)
  entry.append(key)
  var keysBody = be32(0)
  keysBody.append(be32(1))
  keysBody.append(entry)
  var keys = be32(8 + keysBody.count)
  keys.append(contentsOf: "keys".utf8)
  keys.append(keysBody)
  let value = Data(name.utf8)
  var dataAtom = be32(16 + value.count)
  dataAtom.append(contentsOf: "data".utf8)
  dataAtom.append(be32(1))
  dataAtom.append(be32(0))
  dataAtom.append(value)
  var item = be32(8 + dataAtom.count)
  item.append(be32(1))
  item.append(dataAtom)
  var ilst = be32(8 + item.count)
  ilst.append(contentsOf: "ilst".utf8)
  ilst.append(item)
  keys.append(ilst)
  return keys
}

private func writeMedia(_ root: URL, _ relative: String, place: String?) {
  let url = root.appendingPathComponent(relative)
  try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  var data = Data("sol-media".utf8)
  if let place {
    data.append(placeBoxes(place))
  }
  try! data.write(to: url)
}

private func writeMapLink(_ root: URL, _ relative: String, urlString: String) {
  let url = root.appendingPathComponent(relative)
  try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  let plist = """
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0"><dict><key>URL</key><string>\(urlString)</string></dict></plist>
  """
  try! plist.write(to: url, atomically: true, encoding: .utf8)
}

private func setClocks(_ root: URL, _ relative: String, created: Date, modified: Date) {
  let url = root.appendingPathComponent(relative)
  try! FileManager.default.setAttributes([
    .creationDate: created,
    .modificationDate: modified,
  ], ofItemAtPath: url.path)
}

private func testNameContainsIsCaseInsensitive() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("papers", isDirectory: true)
  write(folder, "Report.TXT")
  let store = index(at: root)
  indexNow(store, [folder.path])
  let names = store.search(query: "report").map(\.name)
  check(names.contains("Report.TXT"), "case-insensitive name match for report")
}

private func testHigherFuzzyScoreRanksFirst() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("notes", isDirectory: true)
  write(folder, "cat.txt")
  write(folder, "cat-in-a-very-long-file-name.txt")
  let store = index(at: root)
  indexNow(store, [folder.path])
  let names = store.search(query: "cat").map(\.name)
  check(names.first == "cat.txt", "tighter name ranks first, got \(names)")
}

private func testEmptyQueryReturnsNothing() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("notes", isDirectory: true)
  write(folder, "cat.txt")
  let store = index(at: root)
  indexNow(store, [folder.path])
  check(store.search(query: "").isEmpty, "empty query returns no files")
  check(store.search(query: "   ").isEmpty, "blank query returns no files")
}

private func testSearchReturnsAtMostOneHundred() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("many", isDirectory: true)
  for n in 0..<101 {
    write(folder, String(format: "item-%03d.txt", n))
  }
  let store = index(at: root)
  indexNow(store, [folder.path])
  check(store.search(query: "item").count == 100, "search returns 100 name matches, not the 101st")
}

private func testSearchReturnsWhileWalkIsRunning() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("bulk", isDirectory: true)
  for n in 0..<8000 {
    write(folder, String(format: "bulk-%05d.txt", n))
  }
  let store = index(at: root)
  let finished = NSLock()
  var walkFinished = false
  store.setSearchFolders([folder.path])
  store.update {
    finished.lock()
    walkFinished = true
    finished.unlock()
  }
  _ = store.search(query: "bulk-00001")
  finished.lock()
  let done = walkFinished
  finished.unlock()
  check(!done, "search waited until the walk finished")
}

private func testSkipsNodeModules() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("proj", isDirectory: true)
  write(folder, "readme.txt")
  write(folder, "node_modules/leftpad/index.js")
  let store = index(at: root)
  indexNow(store, [folder.path])
  let names = store.search(query: "index").map(\.name)
  check(!names.contains("index.js"), "files inside node_modules are absent")
  check(store.search(query: "node_modules").isEmpty, "the node_modules directory is absent")
  check(store.search(query: "readme").map(\.name).contains("readme.txt"), "a sibling of node_modules is kept")
}

private func testSkipsHiddenNames() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("proj", isDirectory: true)
  write(folder, "visible.txt")
  write(folder, ".env")
  write(folder, ".git/objects/secret-object")
  let store = index(at: root)
  indexNow(store, [folder.path])
  check(store.search(query: ".env").isEmpty, "a hidden file is absent")
  check(store.search(query: "secret-object").isEmpty, "files inside a hidden directory are absent")
  check(store.search(query: "visible").map(\.name).contains("visible.txt"), "a visible sibling is kept")
}

private func testSkipsPackage() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("apps", isDirectory: true)
  write(folder, "visible.txt")
  write(folder, "Widget.app/Contents/hidden.txt")
  let store = index(at: root)
  indexNow(store, [folder.path])
  check(store.search(query: "hidden").isEmpty, "files inside a package are absent")
  check(store.search(query: "Widget").isEmpty, "the package itself is absent")
  check(store.search(query: "visible").map(\.name).contains("visible.txt"), "a file beside a package is kept")
}

private func testUpdateSeesAddedAndRemovedFiles() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("desk", isDirectory: true)
  write(folder, "old.txt")
  let store = index(at: root)
  indexNow(store, [folder.path])
  try? FileManager.default.removeItem(at: folder.appendingPathComponent("old.txt"))
  write(folder, "fresh.txt")
  waitFor { store.update(completion: $0) }
  check(store.search(query: "old").isEmpty, "update forgets a file that is gone")
  check(store.search(query: "fresh").map(\.name).contains("fresh.txt"), "update finds a new file")
}

private func testRemoveFolderDropsItsFiles() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let keep = root.appendingPathComponent("keep", isDirectory: true)
  let drop = root.appendingPathComponent("drop", isDirectory: true)
  write(keep, "stay.txt")
  write(drop, "gone.txt")
  let store = index(at: root)
  indexNow(store, [keep.path, drop.path])
  waitFor { store.removeSearchFolder(drop.path, completion: $0) }
  check(store.search(query: "gone").isEmpty, "removing a search folder drops its files")
  check(store.search(query: "stay").map(\.name).contains("stay.txt"), "another search folder stays")
}

private func testPathMatchRanksBelowNameMatch() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("library", isDirectory: true)
  write(folder, "Invoices/notes.txt")
  write(folder, "Invoices/invoices.txt")
  let store = index(at: root)
  indexNow(store, [folder.path])
  let names = store.search(query: "invoices").map(\.name)
  check(names.contains("notes.txt"), "a file inside Invoices matches invoices")
  check(names.contains("invoices.txt"), "a name match still appears")
  check(names.filter { $0 == "invoices.txt" }.count == 1, "a file that matches name and path appears once")
  if let nameIndex = names.firstIndex(of: "invoices.txt"),
     let pathIndex = names.firstIndex(of: "notes.txt") {
    check(nameIndex < pathIndex, "a name match ranks above a path match")
  }
}

private func testSearchFolderNameDoesNotMatch() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("Documents", isDirectory: true)
  write(folder, "notes.txt")
  write(folder, "Taxes/form.txt")
  let store = index(at: root)
  indexNow(store, [folder.path])
  check(
    store.search(query: "documents").isEmpty,
    "the search folder's own name does not match every file inside it"
  )
  check(
    store.search(query: "taxes").map(\.name).contains("form.txt"),
    "a folder inside the search folder still matches"
  )
}

private func testPathTierUsesFuzzyScore() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("library", isDirectory: true)
  write(folder, "Invoices/zzz.txt")
  write(folder, "Invoices-and-a-very-long-folder-name/aaa.txt")
  let store = index(at: root)
  indexNow(store, [folder.path])
  let names = store.search(query: "invoices").map(\.name)
  guard let zzz = names.firstIndex(of: "zzz.txt"), let aaa = names.firstIndex(of: "aaa.txt") else {
    check(false, "both path matches appear, got \(names)")
    return
  }
  check(zzz < aaa, "the tighter folder ranks first in the path tier, got \(names)")
  for folder in ["Invoices", "Invoices-and-a-very-long-folder-name"] {
    if let folderIndex = names.firstIndex(of: folder) {
      check(folderIndex < zzz, "a folder whose name matches ranks above a path match")
    }
  }
}

private func testFirstUpdateWalksAnEmptyIndex() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("seed", isDirectory: true)
  write(folder, "seeded.txt")
  let store = index(at: root)
  indexNow(store, [folder.path])
  check(store.search(query: "seeded").map(\.name).contains("seeded.txt"), "the first update walks")
}

private func testSettingFoldersNeverWalks() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("seed", isDirectory: true)
  write(folder, "seeded.txt")
  let store = index(at: root)
  store.setSearchFolders([folder.path])
  pause(0.5)
  check(store.search(query: "seeded").isEmpty, "launch does not walk an empty index")
}

private func testChangesWaitForUpdate() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("kept", isDirectory: true)
  write(folder, "first.txt")
  let store = index(at: root)
  indexNow(store, [folder.path])
  write(folder, "late.txt")
  try? FileManager.default.removeItem(at: folder.appendingPathComponent("first.txt"))
  pause(1.5)
  check(store.search(query: "late").isEmpty, "a new file waits for update")
  check(store.search(query: "first").map(\.name).contains("first.txt"), "a removed file waits for update")
  waitFor { store.update(completion: $0) }
  check(store.search(query: "late").map(\.name).contains("late.txt"), "update adds the new file")
  check(store.search(query: "first").isEmpty, "update removes the old file")
}

private func testUpdateReplaysInsteadOfRebuilding() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("kept", isDirectory: true)
  write(folder, "first.txt")
  let store = index(at: root)
  indexNow(store, [folder.path])
  insertGhost(at: root, path: folder.appendingPathComponent("ghost.txt").path)
  write(folder, "late.txt")
  waitFor { store.update(completion: $0) }
  check(store.search(query: "ghost").map(\.name).contains("ghost.txt"), "update did not rebuild")
  check(store.search(query: "late").map(\.name).contains("late.txt"), "update replayed the change")
}

private func testCheckpointSurvivesRelaunch() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("kept", isDirectory: true)
  write(folder, "first.txt")
  do {
    let store = index(at: root)
    indexNow(store, [folder.path])
  }
  insertGhost(at: root, path: folder.appendingPathComponent("ghost.txt").path)
  write(folder, "while-closed.txt")
  let again = index(at: root)
  again.setSearchFolders([folder.path])
  pause(0.3)
  check(again.search(query: "while-closed").isEmpty, "a relaunch does not catch up by itself")
  waitFor { again.update(completion: $0) }
  check(again.search(query: "while-closed").map(\.name).contains("while-closed.txt"), "update finds changes made while Sol was closed")
  check(again.search(query: "ghost").map(\.name).contains("ghost.txt"), "a relaunch keeps the checkpoint")
}

private func testReplacedFileStaysIndexed() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("kept", isDirectory: true)
  write(folder, "saved.txt")
  let store = index(at: root)
  indexNow(store, [folder.path])
  let saved = folder.appendingPathComponent("saved.txt")
  try! FileManager.default.removeItem(at: saved)
  write(folder, "saved.txt", "new contents")
  waitFor { store.update(completion: $0) }
  check(store.search(query: "saved").map(\.name).contains("saved.txt"), "a file removed and recreated stays")
}

private func testMovedFolderMovesItsFiles() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("kept", isDirectory: true)
  write(folder, "before/inner.txt")
  let store = index(at: root)
  indexNow(store, [folder.path])
  try! FileManager.default.moveItem(
    at: folder.appendingPathComponent("before"),
    to: folder.appendingPathComponent("after")
  )
  waitFor { store.update(completion: $0) }
  let paths = store.search(query: "inner").map(\.path)
  check(paths.count == 1, "a moved file appears once, got \(paths)")
  check(paths.first?.contains("/after/") == true, "a moved file has its new path, got \(paths)")
}

private func testRemovedFolderTakesItsFiles() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("kept", isDirectory: true)
  write(folder, "doomed/deep/inner.txt")
  write(folder, "doomedly.txt")
  let store = index(at: root)
  indexNow(store, [folder.path])
  try! FileManager.default.removeItem(at: folder.appendingPathComponent("doomed"))
  waitFor { store.update(completion: $0) }
  check(store.search(query: "inner").isEmpty, "files under a removed folder are gone")
  check(store.search(query: "doomedly").map(\.name).contains("doomedly.txt"), "a sibling sharing the prefix stays")
}

private func testHiddenChurnStaysOut() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("kept", isDirectory: true)
  write(folder, "visible.txt")
  let store = index(at: root)
  indexNow(store, [folder.path])
  write(folder, ".git/objects/churn.txt")
  write(folder, "node_modules/pkg/churn.js")
  write(folder, "real.txt")
  waitFor { store.update(completion: $0) }
  check(store.search(query: "churn").isEmpty, "hidden and node_modules changes stay out")
  check(store.search(query: "real").map(\.name).contains("real.txt"), "a change beside them lands")
}

private func testAddFolderWalksOnlyThatFolder() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let first = root.appendingPathComponent("first", isDirectory: true)
  let second = root.appendingPathComponent("second", isDirectory: true)
  write(first, "one.txt")
  write(second, "two.txt")
  let store = index(at: root)
  indexNow(store, [first.path])
  write(first, "unasked.txt")
  waitFor { store.addSearchFolder(second.path, completion: $0) }
  check(store.search(query: "two").map(\.name).contains("two.txt"), "adding a folder walks it")
  check(store.search(query: "unasked").isEmpty, "adding a folder does not update the others")
}

private func testDeleteTreeNeverScansTheTable() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = index(at: root)
  var db: OpaquePointer?
  sqlite3_open(root.appendingPathComponent("filesearch.db").path, &db)
  defer { sqlite3_close(db) }
  var statement: OpaquePointer?
  guard sqlite3_prepare_v2(db, "EXPLAIN QUERY PLAN " + FileIndex.deleteTreeSQL, -1, &statement, nil) == SQLITE_OK else {
    check(false, "the delete does not prepare")
    return
  }
  defer { sqlite3_finalize(statement) }
  var plan: [String] = []
  while sqlite3_step(statement) == SQLITE_ROW {
    if let detail = sqlite3_column_text(statement, 3) {
      plan.append(String(cString: detail))
    }
  }
  check(!plan.isEmpty, "the delete has a query plan")
  check(!plan.contains { $0.contains("SCAN") }, "the delete scans the table: \(plan)")
}

private func testClearEmptiesTheDatabase() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("kept", isDirectory: true)
  for n in 0..<2000 {
    write(folder, String(format: "file-%05d.txt", n))
  }
  let store = index(at: root)
  indexNow(store, [folder.path])
  waitFor { store.clear(completion: $0) }
  check(store.search(query: "file").isEmpty, "clear forgets every file")
  let size = (try? FileManager.default.attributesOfItem(
    atPath: root.appendingPathComponent("filesearch.db").path
  )[.size] as? Int) ?? Int.max
  check(size < 64 * 1024, "clear gives the disk space back, file is \(size) bytes")
  store.setSearchFolders([folder.path])
  pause(0.3)
  check(store.search(query: "file").isEmpty, "turning back on does not walk by itself")
  waitFor { store.update(completion: $0) }
  check(store.search(query: "file-00001").count == 1, "update after clear rebuilds")
}

private func testClocksMatchYearMonthDateAndMinute() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("papers", isDirectory: true)
  write(folder, "alpha.txt")
  write(folder, "beta.txt")
  // APFS drops a creation time that is later than the modification time.
  // The later clock is written as the modification time.
  setClocks(
    folder, "alpha.txt",
    created: localDate(2010, 1, 1, 8, 0),
    modified: localDate(2026, 10, 28, 9, 15)
  )
  setClocks(
    folder, "beta.txt",
    created: localDate(2001, 1, 1, 8, 0),
    modified: localDate(2011, 4, 4, 14, 5)
  )
  let store = index(at: root)
  indexNow(store, [folder.path])

  check(store.search(query: "2026").map(\.name).contains("alpha.txt"), "a modification year matches")
  check(store.search(query: "October").map(\.name).contains("alpha.txt"), "an English month name matches")
  check(store.search(query: "october").map(\.name).contains("alpha.txt"), "a month name is case insensitive")
  check(store.search(query: "2026-10-28").map(\.name).contains("alpha.txt"), "a calendar date matches")
  check(store.search(query: "2010").map(\.name).contains("alpha.txt"), "a creation year matches")
  check(store.search(query: "14:05").map(\.name).contains("beta.txt"), "an hour and minute matches the modification time")
  check(store.search(query: "April").map(\.name).contains("beta.txt"), "a modification month matches")
  check(store.search(query: "2001").map(\.name).contains("beta.txt"), "a creation year matches when the modification year differs")
  check(!store.search(query: "14:05").map(\.name).contains("alpha.txt"), "a different minute does not match")
}

private func testYesterdayDoesNotMatchTheClock() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("papers", isDirectory: true)
  write(folder, "notes.txt")
  let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
  setClocks(folder, "notes.txt", created: yesterday, modified: yesterday)
  let store = index(at: root)
  indexNow(store, [folder.path])
  check(store.search(query: "yesterday").isEmpty, "yesterday does not match on the clock alone")
  check(
    store.search(query: calendarDate(yesterday)).map(\.name).contains("notes.txt"),
    "the same file still matches its calendar date"
  )
}

private func testDateMatchRanksBelowPathAndName() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("library", isDirectory: true)
  write(folder, "2026.txt")
  write(folder, "Year2026/notes.txt")
  write(folder, "photo.txt")
  let inTwentyTwentySix = localDate(2026, 6, 2, 12, 0)
  let longAgo = localDate(2010, 1, 1, 8, 0)
  setClocks(folder, "2026.txt", created: inTwentyTwentySix, modified: inTwentyTwentySix)
  setClocks(folder, "Year2026/notes.txt", created: longAgo, modified: longAgo)
  setClocks(folder, "photo.txt", created: inTwentyTwentySix, modified: inTwentyTwentySix)
  let store = index(at: root)
  indexNow(store, [folder.path])
  let names = store.search(query: "2026").map(\.name)
  check(names.filter { $0 == "2026.txt" }.count == 1, "a file that matches its name and its date appears once")
  guard let nameIndex = names.firstIndex(of: "2026.txt"),
        let pathIndex = names.firstIndex(of: "notes.txt"),
        let dateIndex = names.firstIndex(of: "photo.txt") else {
    check(false, "name, path, and date matches all appear, got \(names)")
    return
  }
  check(nameIndex < pathIndex, "a name match ranks above a path match, got \(names)")
  check(pathIndex < dateIndex, "a date match ranks below a path match, got \(names)")
}

private func testPlaceNamesForMediaAndMapLinks() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("trips", isDirectory: true)
  writePhoto(folder, "city.jpg", city: "Paris")
  writeMedia(folder, "song.m4a", place: "Lyon")
  writeMedia(folder, "clip.mp4", place: "Nantes")
  writeMapLink(folder, "pin.webloc", urlString: "https://maps.apple.com/?q=Bordeaux")
  writePhoto(folder, "exact.jpg", city: "Oslo")
  writePhoto(folder, "long.jpg", city: "Oslo Heights District")
  let store = index(at: root)
  indexNow(store, [folder.path])
  check(store.search(query: "paris").map(\.name).contains("city.jpg"), "a photo matches its place name")
  check(store.search(query: "Lyon").map(\.name).contains("song.m4a"), "an audio file matches its place name")
  check(store.search(query: "Nantes").map(\.name).contains("clip.mp4"), "a video matches its place name")
  check(store.search(query: "Bordeaux").map(\.name).contains("pin.webloc"), "a map link matches the place it names")
  let oslo = store.search(query: "Oslo").map(\.name)
  guard let exact = oslo.firstIndex(of: "exact.jpg"), let long = oslo.firstIndex(of: "long.jpg") else {
    check(false, "both place matches appear, got \(oslo)")
    return
  }
  check(exact < long, "the tighter place name ranks first in the tier, got \(oslo)")
}

private func testOrdinaryFileAndMissingPlaceDoNotMatch() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("desk", isDirectory: true)
  write(folder, "notes.txt", "Meet in Paris tomorrow")
  writePhoto(folder, "plain.jpg", city: nil)
  writeMedia(folder, "silent.m4a", place: nil)
  let store = index(at: root)
  indexNow(store, [folder.path])
  check(store.search(query: "Paris").isEmpty, "an ordinary file does not gain a place name")
  check(store.search(query: "plain").map(\.name).contains("plain.jpg"), "a photo with no place name is still indexed")
  check(store.search(query: "Paris").map(\.name).contains("plain.jpg") == false, "a photo with no place name does not match")
  check(store.search(query: "Paris").map(\.name).contains("silent.m4a") == false, "audio with no place name does not match")
}

private func testCoordinateIsNotAPlace() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("maps", isDirectory: true)
  writePhoto(folder, "gps.jpg", city: nil, latitude: 48.8566)
  writeMapLink(folder, "pin.webloc", urlString: "https://maps.apple.com/?ll=48.8566,2.3522")
  writeMedia(folder, "where.m4a", place: "+48.8566+002.3522/")
  let store = index(at: root)
  indexNow(store, [folder.path])
  for query in ["48.8566", "2.3522", "Paris"] {
    check(store.search(query: query).isEmpty, "\(query) is not a place match")
  }
}

private func testPlaceRanksWithDatesBelowPathAndName() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("library", isDirectory: true)
  write(folder, "May.txt")
  write(folder, "May/form.txt")
  write(folder, "notes.txt")
  writePhoto(folder, "trip.jpg", city: "Mayfair Heights")
  let may = localDate(2019, 5, 2, 8, 0)
  let longAgo = localDate(2010, 1, 1, 8, 0)
  setClocks(folder, "May.txt", created: longAgo, modified: longAgo)
  setClocks(folder, "May/form.txt", created: longAgo, modified: longAgo)
  setClocks(folder, "notes.txt", created: localDate(2010, 1, 1, 8, 0), modified: may)
  setClocks(folder, "trip.jpg", created: longAgo, modified: longAgo)
  let store = index(at: root)
  indexNow(store, [folder.path])
  let names = store.search(query: "May").map(\.name)
  guard let nameIndex = names.firstIndex(of: "May.txt"),
        let pathIndex = names.firstIndex(of: "form.txt"),
        let dateIndex = names.firstIndex(of: "notes.txt"),
        let placeIndex = names.firstIndex(of: "trip.jpg") else {
    check(false, "name, path, date, and place matches all appear, got \(names)")
    return
  }
  check(nameIndex < pathIndex, "a name match ranks above a path match, got \(names)")
  check(pathIndex < dateIndex, "a date match ranks below a path match, got \(names)")
  check(pathIndex < placeIndex, "a place match ranks below a path match, got \(names)")
  check(dateIndex < placeIndex, "inside the bottom tier the tighter score ranks first, got \(names)")
  check(names.filter { $0 == "May.txt" }.count == 1, "a file that matches its name and its place appears once")
}

private func testNameAndPlaceAppearsOnce() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("photos", isDirectory: true)
  writePhoto(folder, "Paris.jpg", city: "Paris")
  writePhoto(folder, "trip.jpg", city: "Paris")
  let store = index(at: root)
  indexNow(store, [folder.path])
  let names = store.search(query: "Paris").map(\.name)
  check(names.filter { $0 == "Paris.jpg" }.count == 1, "a photo that matches its name and its place appears once")
  guard let nameIndex = names.firstIndex(of: "Paris.jpg"),
        let placeIndex = names.firstIndex(of: "trip.jpg") else {
    check(false, "the name match and the place match both appear, got \(names)")
    return
  }
  check(nameIndex < placeIndex, "the name match ranks above the place match, got \(names)")
}

private func writeLegacyDatabase(at root: URL, folder: String, files: [(path: String, name: String, parent: String)]) {
  var db: OpaquePointer?
  let path = root.appendingPathComponent("filesearch.db").path
  guard sqlite3_open(path, &db) == SQLITE_OK else {
    check(false, "could not create a legacy database")
    return
  }
  defer { sqlite3_close(db) }
  let schema = """
    CREATE TABLE files (
      path TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      is_folder INTEGER NOT NULL,
      parent_path TEXT,
      indexed_at DATETIME DEFAULT CURRENT_TIMESTAMP
    );
    CREATE TABLE search_folders (path TEXT PRIMARY KEY);
    """
  sqlite3_exec(db, schema, nil, nil, nil)
  var insert: OpaquePointer?
  sqlite3_prepare_v2(db, "INSERT INTO files (path, name, is_folder, parent_path) VALUES (?, ?, 0, ?);", -1, &insert, nil)
  for file in files {
    sqlite3_reset(insert)
    sqlite3_bind_text(insert, 1, file.path, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    sqlite3_bind_text(insert, 2, file.name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    sqlite3_bind_text(insert, 3, file.parent, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    sqlite3_step(insert)
  }
  sqlite3_finalize(insert)
  var folderInsert: OpaquePointer?
  sqlite3_prepare_v2(db, "INSERT INTO search_folders (path) VALUES (?);", -1, &folderInsert, nil)
  sqlite3_bind_text(folderInsert, 1, folder, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
  sqlite3_step(folderInsert)
  sqlite3_finalize(folderInsert)
}

private func testLegacyIndexIsFilledOnce() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("kept", isDirectory: true)
  write(folder, "notes.txt")
  let dated = localDate(2018, 7, 9, 16, 40)
  setClocks(folder, "notes.txt", created: localDate(2010, 1, 1, 8, 0), modified: dated)
  writePhoto(folder, "city.jpg", city: "Paris")
  let notes = folder.appendingPathComponent("notes.txt").path
  let photo = folder.appendingPathComponent("city.jpg").path
  writeLegacyDatabase(at: root, folder: folder.path, files: [
    (notes, "notes.txt", folder.path),
    (photo, "city.jpg", folder.path),
  ])

  do {
    let store = index(at: root)
    store.setSearchFolders([folder.path])
    pause(0.3)
    check(store.search(query: "2018-07-09").isEmpty, "opening a legacy index does not fill it")
    waitFor { store.update(completion: $0) }
    check(store.search(query: "2018-07-09").map(\.name).contains("notes.txt"), "a date query finds a file that was already stored")
    check(store.search(query: "Paris").map(\.name).contains("city.jpg"), "a place query finds a file that was already stored")
  }

  write(folder, "late.txt")
  let again = index(at: root)
  again.setSearchFolders([folder.path])
  pause(0.3)
  check(again.search(query: "late").isEmpty, "the launch after the fill does not walk again")
  check(again.search(query: "Paris").map(\.name).contains("city.jpg"), "the filled place is still searchable")
}

private func testRebuildCompactsTheDatabase() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("kept", isDirectory: true)
  write(folder, "notes.txt")
  let notes = folder.appendingPathComponent("notes.txt").path
  let stale = (0..<20000).map { (folder.path + "/stale-\($0)-" + String(repeating: "x", count: 200), "stale-\($0)", folder.path) }
  writeLegacyDatabase(at: root, folder: folder.path, files: [(notes, "notes.txt", folder.path)] + stale)
  let path = root.appendingPathComponent("filesearch.db").path
  let before = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
  let store = index(at: root)
  indexNow(store, [folder.path])
  let after = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? Int.max
  check(before > 1_000_000, "the fixture is large, got \(before)")
  check(after < before / 10, "a rebuild gives empty space back, \(before) became \(after)")
}

private func stateValue(at root: URL, key: String) -> String? {
  var db: OpaquePointer?
  guard sqlite3_open(root.appendingPathComponent("filesearch.db").path, &db) == SQLITE_OK else { return nil }
  defer { sqlite3_close(db) }
  var statement: OpaquePointer?
  sqlite3_prepare_v2(db, "SELECT value FROM index_state WHERE key = '\(key)';", -1, &statement, nil)
  defer { sqlite3_finalize(statement) }
  guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
  return String(cString: text)
}

private func testRescanKeepsTheFolderItself() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("kept", isDirectory: true)
  write(folder, "Projects/inner.txt")
  let store = index(at: root)
  indexNow(store, [folder.path])
  write(folder, "Projects/added.txt")
  waitFor { store.rescan(eventPath: folder.appendingPathComponent("Projects").path, completion: $0) }
  check(store.search(query: "Projects").map(\.name).contains("Projects"), "a rescan keeps the folder's own row")
  check(store.search(query: "added").map(\.name).contains("added.txt"), "a rescan finds new files")
}

private func testDropReportedAboveAFolderRescansIt() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("kept", isDirectory: true)
  write(folder, "first.txt")
  let store = index(at: root)
  indexNow(store, [folder.path])
  write(folder, "dropped.txt")
  waitFor { store.rescan(eventPath: root.path, completion: $0) }
  check(store.search(query: "dropped").map(\.name).contains("dropped.txt"), "a drop above a search folder rescans it")
}

private func testNestedFoldersKeepCoveredFiles() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let outer = root.appendingPathComponent("outer", isDirectory: true)
  let inner = outer.appendingPathComponent("inner", isDirectory: true)
  write(outer, "inner/deep.txt")
  write(outer, "shallow.txt")
  let store = index(at: root)
  indexNow(store, [outer.path, inner.path])
  waitFor { store.removeSearchFolder(inner.path, completion: $0) }
  check(store.search(query: "deep").map(\.name).contains("deep.txt"), "removing a nested folder keeps files the outer one covers")
  store.setSearchFolders([outer.path, inner.path])
  waitFor { store.removeSearchFolder(outer.path, completion: $0) }
  check(store.search(query: "deep").map(\.name).contains("deep.txt"), "removing the outer folder keeps the nested folder's files")
  check(store.search(query: "shallow").isEmpty, "removing the outer folder drops its own files")
}

private func testMovedSearchFolderLeavesNoGhosts() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("kept", isDirectory: true)
  write(folder, "inner.txt")
  let store = index(at: root)
  indexNow(store, [folder.path])
  try! FileManager.default.moveItem(at: folder, to: root.appendingPathComponent("elsewhere"))
  waitFor { store.update(completion: $0) }
  check(store.search(query: "inner").isEmpty, "a moved search folder leaves no ghosts")
}

private func testSymlinkedSearchFolderUpdates() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let real = root.appendingPathComponent("real", isDirectory: true)
  write(real, "first.txt")
  let link = root.appendingPathComponent("link")
  try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
  let store = index(at: root)
  indexNow(store, [link.path])
  write(real, "late.txt")
  try! FileManager.default.removeItem(at: real.appendingPathComponent("first.txt"))
  waitFor { store.update(completion: $0) }
  check(store.search(query: "late").map(\.name).contains("late.txt"), "update follows a symlinked search folder")
  check(store.search(query: "first").isEmpty, "a removal under a symlinked search folder lands")
}

private func testQuietUpdateAdvancesTheCheckpoint() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("kept", isDirectory: true)
  write(folder, "first.txt")
  let store = index(at: root)
  indexNow(store, [folder.path])
  let before = UInt64(stateValue(at: root, key: "checkpoint") ?? "0") ?? 0
  write(root, "outside.txt")
  pause(1.2)
  waitFor { store.update(completion: $0) }
  let after = UInt64(stateValue(at: root, key: "checkpoint") ?? "0") ?? 0
  check(after > before, "a quiet update moves the checkpoint, \(before) stayed \(after)")
}

private func testChangedEventLogRebuilds() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("kept", isDirectory: true)
  write(folder, "first.txt")
  let store = index(at: root)
  indexNow(store, [folder.path])
  insertGhost(at: root, path: folder.appendingPathComponent("ghost.txt").path)
  var db: OpaquePointer?
  sqlite3_open(root.appendingPathComponent("filesearch.db").path, &db)
  let changed = sqlite3_exec(db, "UPDATE index_state SET value = 'other-log' WHERE key = 'log_id';", nil, nil, nil)
  check(changed == SQLITE_OK && sqlite3_changes(db) == 1, "the log id is stored")
  sqlite3_close(db)
  waitFor { store.update(completion: $0) }
  check(store.search(query: "ghost").isEmpty, "a replaced macOS log forces a rebuild")
}

private func testReplacedFolderDropsOldChildren() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("kept", isDirectory: true)
  write(folder, "swap/old-child.txt")
  write(root, "incoming/new-child.txt")
  let store = index(at: root)
  indexNow(store, [folder.path])
  let swap = folder.appendingPathComponent("swap")
  try! FileManager.default.moveItem(at: swap, to: root.appendingPathComponent("away"))
  try! FileManager.default.moveItem(at: root.appendingPathComponent("incoming"), to: swap)
  waitFor { store.update(completion: $0) }
  check(store.search(query: "old-child").isEmpty, "a folder replaced at the same path drops old children")
  check(store.search(query: "new-child").map(\.name).contains("new-child.txt"), "a folder replaced at the same path gains new children")
}

private func testFolderDroppedFromConfigLeavesOnUpdate() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let keep = root.appendingPathComponent("keep", isDirectory: true)
  let drop = root.appendingPathComponent("drop", isDirectory: true)
  write(keep, "stay.txt")
  write(drop, "gone.txt")
  let store = index(at: root)
  indexNow(store, [keep.path, drop.path])
  indexNow(store, [keep.path])
  check(store.search(query: "gone").isEmpty, "a folder dropped from the settings file leaves on update")
  check(store.search(query: "stay").map(\.name).contains("stay.txt"), "a kept folder stays")
}

let tests: [(String, () -> Void)] = [
  ("name contains is case insensitive", testNameContainsIsCaseInsensitive),
  ("higher fuzzy score ranks first", testHigherFuzzyScoreRanksFirst),
  ("empty query returns nothing", testEmptyQueryReturnsNothing),
  ("search returns at most one hundred", testSearchReturnsAtMostOneHundred),
  ("search returns while a walk is running", testSearchReturnsWhileWalkIsRunning),
  ("skips node_modules", testSkipsNodeModules),
  ("skips hidden names", testSkipsHiddenNames),
  ("skips a package", testSkipsPackage),
  ("update sees added and removed files", testUpdateSeesAddedAndRemovedFiles),
  ("remove folder drops its files", testRemoveFolderDropsItsFiles),
  ("path match ranks below a name match", testPathMatchRanksBelowNameMatch),
  ("search folder name does not match", testSearchFolderNameDoesNotMatch),
  ("path tier uses fuzzy score", testPathTierUsesFuzzyScore),
  ("clocks match a year, month, date, and minute", testClocksMatchYearMonthDateAndMinute),
  ("yesterday does not match the clock", testYesterdayDoesNotMatchTheClock),
  ("a date match ranks below a path match and a name match", testDateMatchRanksBelowPathAndName),
  ("place names match for media and map links", testPlaceNamesForMediaAndMapLinks),
  ("an ordinary file and a missing place do not match", testOrdinaryFileAndMissingPlaceDoNotMatch),
  ("a coordinate is not a place", testCoordinateIsNotAPlace),
  ("a place match ranks with dates below path and name", testPlaceRanksWithDatesBelowPathAndName),
  ("a name and a place appear once", testNameAndPlaceAppearsOnce),
  ("a legacy index is filled once", testLegacyIndexIsFilledOnce),
  ("a rebuild compacts the database", testRebuildCompactsTheDatabase),
  ("the first update walks an empty index", testFirstUpdateWalksAnEmptyIndex),
  ("setting folders never walks", testSettingFoldersNeverWalks),
  ("changes wait for update", testChangesWaitForUpdate),
  ("update replays instead of rebuilding", testUpdateReplaysInsteadOfRebuilding),
  ("the checkpoint survives a relaunch", testCheckpointSurvivesRelaunch),
  ("a replaced file stays indexed", testReplacedFileStaysIndexed),
  ("a moved folder moves its files", testMovedFolderMovesItsFiles),
  ("a removed folder takes its files", testRemovedFolderTakesItsFiles),
  ("hidden churn stays out", testHiddenChurnStaysOut),
  ("adding a folder walks only that folder", testAddFolderWalksOnlyThatFolder),
  ("deleting a tree never scans the table", testDeleteTreeNeverScansTheTable),
  ("clear empties the database", testClearEmptiesTheDatabase),
  ("a rescan keeps the folder itself", testRescanKeepsTheFolderItself),
  ("a drop above a folder rescans it", testDropReportedAboveAFolderRescansIt),
  ("nested folders keep covered files", testNestedFoldersKeepCoveredFiles),
  ("a moved search folder leaves no ghosts", testMovedSearchFolderLeavesNoGhosts),
  ("a symlinked search folder updates", testSymlinkedSearchFolderUpdates),
  ("a quiet update advances the checkpoint", testQuietUpdateAdvancesTheCheckpoint),
  ("a changed event log rebuilds", testChangedEventLogRebuilds),
  ("a replaced folder drops old children", testReplacedFolderDropsOldChildren),
  ("a folder dropped from config leaves on update", testFolderDroppedFromConfigLeavesOnUpdate),
]

@main
struct FileIndexAcceptanceMain {
  static func main() {
    for (name, test) in tests {
      let before = failures.count
      test()
      if failures.count == before {
        fputs("ok \(name)\n", stdout)
      }
    }

    if !failures.isEmpty {
      fputs("\(failures.count) failed\n", stderr)
      exit(1)
    }
  }
}
