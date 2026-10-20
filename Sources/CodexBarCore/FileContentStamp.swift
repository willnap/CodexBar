import Foundation

/// A regular file's identity and version. A reader that keeps what it last parsed skips a file whose stamp is
/// unchanged instead of reading and parsing it again on every refresh.
struct FileContentStamp: Equatable {
    let inode: UInt64
    let size: Int
    let modified: Date

    init?(_ url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let size = (attributes[.size] as? NSNumber)?.intValue,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        self.inode = inode
        self.size = size
        self.modified = modified
    }
}
