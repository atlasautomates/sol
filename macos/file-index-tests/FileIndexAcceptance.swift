import Foundation

// Lead-authored acceptance tests for ticket 01. The implementer must not edit
// this file. The module under test is FileIndex. Construct it with a database
// URL. Do not use a process-wide singleton here.
//
// Contract:
// - setSearchFolders returns after scheduling. It does not wait for a walk.
// - Its completion runs when that walk has finished, or when no walk was required.
// - search may run while a walk is in progress and must return without waiting
//   for that walk to finish.
// - A name match is a case-insensitive contains on the file name. This ticket
//   does not score folder names.
// - Among name matches, the higher fuzzy score ranks first.
// - One search returns at most 100 files.
// - An empty query returns no files.
// - setSearchFolders on a database that already has rows watches and does not
//   walk those folders again. An empty database is walked.
// - reindex forgets the stored files and walks the current search folders.
// - removeSearchFolder drops that folder's files.
// - A directory named node_modules, and a directory macOS treats as a package,
//   is not stored, and neither are its contents.
// - A year, an English month name, a calendar date yyyy-MM-dd, or a 24-hour
//   HH:mm matches the file's creation time or its modification time. Those
//   four forms are the file's local civil time. yesterday does not match on
//   the clock alone.
// - A date match ranks below every path match and every name match.
// - A file that matches its name and its date appears once, as a name match.

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
  waitFor { store.setSearchFolders([folder.path], completion: $0) }
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
  waitFor { store.setSearchFolders([folder.path], completion: $0) }
  let names = store.search(query: "cat").map(\.name)
  check(names.first == "cat.txt", "tighter name ranks first, got \(names)")
}

private func testEmptyQueryReturnsNothing() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("notes", isDirectory: true)
  write(folder, "cat.txt")
  let store = index(at: root)
  waitFor { store.setSearchFolders([folder.path], completion: $0) }
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
  waitFor { store.setSearchFolders([folder.path], completion: $0) }
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
  store.setSearchFolders([folder.path]) {
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
  waitFor { store.setSearchFolders([folder.path], completion: $0) }
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
  waitFor { store.setSearchFolders([folder.path], completion: $0) }
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
  waitFor { store.setSearchFolders([folder.path], completion: $0) }
  check(store.search(query: "hidden").isEmpty, "files inside a package are absent")
  check(store.search(query: "Widget").isEmpty, "the package itself is absent")
  check(store.search(query: "visible").map(\.name).contains("visible.txt"), "a file beside a package is kept")
}

private func testReindexClearsThenWalks() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("desk", isDirectory: true)
  write(folder, "old.txt")
  let store = index(at: root)
  waitFor { store.setSearchFolders([folder.path], completion: $0) }
  try? FileManager.default.removeItem(at: folder.appendingPathComponent("old.txt"))
  write(folder, "fresh.txt")
  waitFor { store.reindex(completion: $0) }
  check(store.search(query: "old").isEmpty, "reindex forgets a file that is gone")
  check(store.search(query: "fresh").map(\.name).contains("fresh.txt"), "reindex walks the folder again")
}

private func testRemoveFolderDropsItsFiles() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let keep = root.appendingPathComponent("keep", isDirectory: true)
  let drop = root.appendingPathComponent("drop", isDirectory: true)
  write(keep, "stay.txt")
  write(drop, "gone.txt")
  let store = index(at: root)
  waitFor { store.setSearchFolders([keep.path, drop.path], completion: $0) }
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
  waitFor { store.setSearchFolders([folder.path], completion: $0) }
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
  waitFor { store.setSearchFolders([folder.path], completion: $0) }
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
  waitFor { store.setSearchFolders([folder.path], completion: $0) }
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

private func testEmptyDatabaseWalks() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("seed", isDirectory: true)
  write(folder, "seeded.txt")
  let store = index(at: root)
  waitFor { store.setSearchFolders([folder.path], completion: $0) }
  check(store.search(query: "seeded").map(\.name).contains("seeded.txt"), "an empty index walks")
}

private func testPopulatedDatabaseDoesNotWalkAgain() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("kept", isDirectory: true)
  write(folder, "first.txt")
  let store = index(at: root)
  waitFor { store.setSearchFolders([folder.path], completion: $0) }
  write(folder, "late.txt")
  waitFor { store.setSearchFolders([folder.path], completion: $0) }
  check(store.search(query: "late").isEmpty, "a populated index does not walk again")
  check(store.search(query: "first").map(\.name).contains("first.txt"), "files already stored are still searchable")
}

private func testClocksMatchYearMonthDateAndMinute() {
  let root = makeRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("papers", isDirectory: true)
  write(folder, "alpha.txt")
  write(folder, "beta.txt")
  setClocks(
    folder, "alpha.txt",
    created: localDate(2026, 10, 28, 9, 15),
    modified: localDate(2010, 1, 1, 8, 0)
  )
  setClocks(
    folder, "beta.txt",
    created: localDate(2001, 1, 1, 8, 0),
    modified: localDate(2011, 4, 4, 14, 5)
  )
  let store = index(at: root)
  waitFor { store.setSearchFolders([folder.path], completion: $0) }

  check(store.search(query: "2026").map(\.name).contains("alpha.txt"), "a creation year matches")
  check(store.search(query: "October").map(\.name).contains("alpha.txt"), "an English month name matches")
  check(store.search(query: "october").map(\.name).contains("alpha.txt"), "a month name is case insensitive")
  check(store.search(query: "2026-10-28").map(\.name).contains("alpha.txt"), "a calendar date matches")
  check(store.search(query: "2010").map(\.name).contains("alpha.txt"), "a modification year matches")
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
  waitFor { store.setSearchFolders([folder.path], completion: $0) }
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
  waitFor { store.setSearchFolders([folder.path], completion: $0) }
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

let tests: [(String, () -> Void)] = [
  ("name contains is case insensitive", testNameContainsIsCaseInsensitive),
  ("higher fuzzy score ranks first", testHigherFuzzyScoreRanksFirst),
  ("empty query returns nothing", testEmptyQueryReturnsNothing),
  ("search returns at most one hundred", testSearchReturnsAtMostOneHundred),
  ("search returns while a walk is running", testSearchReturnsWhileWalkIsRunning),
  ("skips node_modules", testSkipsNodeModules),
  ("skips hidden names", testSkipsHiddenNames),
  ("skips a package", testSkipsPackage),
  ("reindex clears then walks", testReindexClearsThenWalks),
  ("remove folder drops its files", testRemoveFolderDropsItsFiles),
  ("empty database walks", testEmptyDatabaseWalks),
  ("populated database does not walk again", testPopulatedDatabaseDoesNotWalkAgain),
  ("path match ranks below a name match", testPathMatchRanksBelowNameMatch),
  ("search folder name does not match", testSearchFolderNameDoesNotMatch),
  ("path tier uses fuzzy score", testPathTierUsesFuzzyScore),
  ("clocks match a year, month, date, and minute", testClocksMatchYearMonthDateAndMinute),
  ("yesterday does not match the clock", testYesterdayDoesNotMatchTheClock),
  ("a date match ranks below a path match and a name match", testDateMatchRanksBelowPathAndName),
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
