import Foundation

extension Process {
    func runAndWait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            terminationHandler = { [weak self] _ in
                self?.terminationHandler = nil
                continuation.resume()
            }
            do {
                try run()
            } catch {
                terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}
