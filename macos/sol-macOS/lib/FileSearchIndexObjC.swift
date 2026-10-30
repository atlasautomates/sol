import Foundation

@objc public class FileSearchIndexObjC: NSObject {
  @objc static let shared = FileSearchIndexObjC()

  private let index = FileIndex(databaseURL: FileIndex.applicationDatabaseURL())

  @objc(searchFilesWithQuery:)
  func searchFiles(query: String) -> [[String: Any]] {
    index.search(query: query).map { file in
      [
        "path": file.path,
        "name": file.name,
        "is_folder": file.isFolder
      ]
    }
  }

  @objc(setSearchFolders:completion:)
  func setSearchFolders(_ paths: [String], completion: @escaping () -> Void) {
    index.setSearchFolders(paths, completion: completion)
  }

  @objc(reindexWithCompletion:)
  func reindex(_ completion: @escaping () -> Void) {
    index.reindex(completion: completion)
  }

  @objc(removeSearchFolder:completion:)
  func removeSearchFolder(_ path: String, completion: @escaping () -> Void) {
    index.removeSearchFolder(path, completion: completion)
  }
}
