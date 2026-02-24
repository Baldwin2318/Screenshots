import Foundation
import UIKit

enum FileStore {
    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func saveImage(_ image: UIImage) -> String? {
        let filename = UUID().uuidString + ".jpg"
        let url = documentsURL.appendingPathComponent(filename)
        guard let data = image.jpegData(compressionQuality: 0.88) else { return nil }

        do {
            try data.write(to: url)
            return filename
        } catch {
            print("Failed to save image: \(error)")
            return nil
        }
    }

    static func deleteImage(filename: String) {
        let url = documentsURL.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
    }
}
