import Foundation
@_spi(Fuzz) import SwiftFTR

#if WITH_LIBFUZZER
  @_cdecl("LLVMFuzzerTestOneInput")
  public func LLVMFuzzerTestOneInput(_ dataPtr: UnsafePointer<UInt8>, _ size: Int) -> Int32 {
    let buf = UnsafeRawBufferPointer(start: UnsafeRawPointer(dataPtr), count: size)
    var ss = sockaddr_storage()
    var sin = sockaddr_in()
    sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    sin.sin_family = sa_family_t(AF_INET)
    sin.sin_addr = in_addr(s_addr: simpleHash32(buf))
    _ = withUnsafePointer(to: &sin) { sp in memcpy(&ss, sp, MemoryLayout<sockaddr_in>.size) }
    _ = __fuzz_parseICMP(buffer: buf, from: ss)
    return 0
  }
#else
  @main
  struct CorpusRunner {
    static func main() {
      let args = CommandLine.arguments
      guard args.count >= 2 else {
        fputs("Usage: icmpfuzzer <corpus_dir>\n", stderr)
        exit(2)
      }
      let dir = args[1]
      let fm = FileManager.default
      guard let iter = fm.enumerator(atPath: dir) else { return }
      var count = 0
      for case let path as String in iter {
        let url = URL(fileURLWithPath: dir).appendingPathComponent(path)
        if url.hasDirectoryPath { continue }
        if let data = try? Data(contentsOf: url) {
          data.withUnsafeBytes { raw in
            var ss = sockaddr_storage()
            var sin = sockaddr_in()
            sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sin.sin_family = sa_family_t(AF_INET)
            sin.sin_addr = in_addr(s_addr: simpleHash32(raw))
            _ = withUnsafePointer(to: &sin) { sp in memcpy(&ss, sp, MemoryLayout<sockaddr_in>.size)
            }
            _ = __fuzz_parseICMP(buffer: raw, from: ss)
          }
          count += 1
        }
      }
      print("Replayed corpus files: \(count)")
    }
  }
#endif

@inline(__always)
func simpleHash32(_ buf: UnsafeRawBufferPointer) -> in_addr_t {
  var h: UInt32 = 2_166_136_261
  let bytes = buf.bindMemory(to: UInt8.self)
  for i in 0..<bytes.count {
    h = (h &* 16_777_619) ^ UInt32(bytes[i])
  }
  return h
}
