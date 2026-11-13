import Foundation

extension UUID {
    nonisolated static func deterministic(from string: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in string.utf8.enumerated() {
            bytes[index % 16] &+= byte
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
