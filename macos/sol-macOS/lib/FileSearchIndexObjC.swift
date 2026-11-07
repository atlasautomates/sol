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

  @objc(setSearchFolders:)
  func setSearchFolders(_ paths: [String]) {
    index.setSearchFolders(paths)
  }

  @objc(updateWithCompletion:)
  func update(_ completion: @escaping () -> Void) {
    index.update(completion: completion)
  }

  @objc(addSearchFolder:completion:)
  func addSearchFolder(_ path: String, completion: @escaping () -> Void) {
    index.addSearchFolder(path, completion: completion)
  }

  @objc(clearWithCompletion:)
  func clear(_ completion: @escaping () -> Void) {
    index.clear(completion: completion)
  }

  @objc(removeSearchFolder:completion:)
  func removeSearchFolder(_ path: String, completion: @escaping () -> Void) {
    index.removeSearchFolder(path, completion: completion)
  }
}
