import Foundation

struct CollectionSummary: Identifiable {
    var id: String { name }
    let name: String
    let items: [ScreenshotItem]

    var count: Int { items.count }
}
