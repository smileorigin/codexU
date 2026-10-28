import Darwin
import Foundation

/// 只在隔离解析进程内持有，每个槽位最多保留一个解压文件描述符
/// 临时文件创建后立即 unlink，超时强杀也不会遗留可见的会话正文副本
final class UsageParseSource {
    static let maximumDecodedBytes: UInt64 = 512 * 1024 * 1024
    let url: URL
    let descriptor: Int32?
    private let decoded: FileHandle?
    private let compressedStamp: UsageFileStamp?

    func matches(path: String, runtime: String) -> Bool {
        guard runtime == "codex", let compressedStamp else { return false }
        let requested = URL(fileURLWithPath: path)
        if requested != url {
            guard path + ".zst" == url.path else { return false }
            do { _ = try UsageFileStamp.capture(url: requested, committedOffset: 0); return false }
            catch UsageIndexError.sourceMissing {} catch { return false }
        }
        return (try? UsageFileStamp.capture(url: url, committedOffset: 0)) == compressedStamp
    }

    init(path: String, runtime: String, cached: UsageParseSource? = nil) throws {
        let requested = URL(fileURLWithPath: path)
        let compressed: URL
        if runtime == "codex", path.hasSuffix(".jsonl.zst") {
            compressed = requested
        } else {
            do {
                _ = try UsageFileStamp.capture(url: requested, committedOffset: 0)
                url = requested; descriptor = nil; decoded = nil; compressedStamp = nil
                return
            } catch UsageIndexError.sourceMissing {
                guard runtime == "codex", path.hasSuffix(".jsonl") else { throw UsageIndexError.sourceMissing }
                compressed = URL(fileURLWithPath: path + ".zst")
            }
        }
        let before = try UsageFileStamp.capture(url: compressed, committedOffset: 0)
        url = compressed
        if let cached, cached.url == compressed, cached.compressedStamp == before, let decoded = cached.decoded {
            self.decoded = decoded; descriptor = decoded.fileDescriptor; compressedStamp = before
            return
        }
        let input = open(compressed.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw UsageIndexError.sourceChanged }
        defer { close(input) }
        guard try UsageFileStamp.capture(url: compressed, committedOffset: 0, descriptor: input) == before else {
            throw UsageIndexError.sourceChanged
        }
        var template = Array(FileManager.default.temporaryDirectory.appendingPathComponent("codexu-decode-XXXXXX").path.utf8CString)
        let output = mkstemp(&template)
        guard output >= 0 else { throw UsageIndexError.diskFull }
        let handle = FileHandle(fileDescriptor: output, closeOnDealloc: true)
        let removed = template.withUnsafeBufferPointer { unlink($0.baseAddress!) }
        guard removed == 0, fchmod(output, 0o600) == 0, fcntl(output, F_SETFD, FD_CLOEXEC) == 0 else {
            throw UsageIndexError.cacheInvalid
        }
        switch codexu_decode_zstd(input, output, Self.maximumDecodedBytes, 3) {
        case 0: break
        case 2: throw UsageIndexError.resourceLimited
        case 3: throw UsageIndexError.diskFull
        case 4: throw UsageIndexError.cancelled
        default: throw UsageIndexError.cacheInvalid
        }
        guard try UsageFileStamp.capture(url: compressed, committedOffset: 0) == before,
              try UsageFileStamp.capture(url: compressed, committedOffset: 0, descriptor: input) == before else {
            throw UsageIndexError.sourceChanged
        }
        decoded = handle; descriptor = output; compressedStamp = before
    }

    func stamp(at offset: UInt64) throws -> UsageFileStamp {
        let content = try UsageFileStamp.capture(url: url, committedOffset: offset, descriptor: descriptor)
        guard let compressedStamp else { return content }
        guard try UsageFileStamp.capture(url: url, committedOffset: 0) == compressedStamp else {
            throw UsageIndexError.sourceChanged
        }
        // 大小、摘要和检查点使用解压后的字节；压缩文件变更则开启新世代
        return UsageFileStamp(identity: "zstd:" + compressedStamp.identity + ":\(compressedStamp.size):\(compressedStamp.modifiedSeconds):\(compressedStamp.modifiedNanoseconds)",
            size: content.size, modifiedSeconds: compressedStamp.modifiedSeconds,
            modifiedNanoseconds: compressedStamp.modifiedNanoseconds, committedOffset: offset,
            headDigest: content.headDigest, boundaryDigest: content.boundaryDigest)
    }
}
