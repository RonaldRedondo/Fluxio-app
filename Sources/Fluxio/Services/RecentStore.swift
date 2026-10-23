import Foundation

/// Últimas conversiones, para el submenú "Recientes" de la barra de menú.
@MainActor
final class RecentStore: ObservableObject {
    static let shared = RecentStore()

    struct Item: Codable, Identifiable {
        var id = UUID()
        let date: Date
        /// Qué se hizo ("Convertir a PNG").
        let title: String
        let paths: [String]

        var urls: [URL] { paths.map { URL(fileURLWithPath: $0) } }

        /// Texto del menú: "foto.png — Convertir a PNG" o "3 archivos — Unir en PDF".
        var menuTitle: String {
            let name = paths.count == 1 ? URL(fileURLWithPath: paths[0]).lastPathComponent : "\(paths.count) archivos"
            return "\(name) — \(title)"
        }

        /// Si al menos uno de los archivos sigue existiendo.
        var exists: Bool { paths.contains { FileManager.default.fileExists(atPath: $0) } }
    }

    /// Cuántas conversiones se recuerdan.
    static let limit = 10
    private let key = "recentConversions"

    @Published private(set) var items: [Item] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved
        }
    }

    func add(title: String, outputs: [URL]) {
        guard !outputs.isEmpty else { return }
        items.insert(Item(date: Date(), title: title, paths: outputs.map(\.path)), at: 0)
        items = Array(items.prefix(Self.limit))
        save()
    }

    func clear() {
        items = []
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
