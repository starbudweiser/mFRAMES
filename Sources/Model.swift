// mFRAMES — modèle de données : projets, versions, annotations, messages, opérations du journal.
// Chaque modification est une « opération » (identifiant unique, auteur, numéro d'ordre, horloge logique de Lamport) :
// le journal garde toutes les opérations, l'état s'en déduit (la plus récente gagne), la fusion est donc sans perte ni doublon.
import Foundation

enum MediaKind: String, Codable { case video, image, pdf, design }
enum AnnotationKind: String, Codable { case pin, zone }
enum ReviewStatus: String, Codable { case open, resolved }

struct Author: Codable, Hashable {
    var id: String
    var name: String
    var colorIndex: Int
}

struct ProjectVersion: Codable, Identifiable, Hashable {
    var id: UUID
    var number: Int
    var path: String          // fichier d'origine (jamais envoyé au client)
    var proxyPath: String?    // copie locale du proxy (cache du client)
    var date: Date
    /// Ce que l'appli affiche : la copie du proxy chez le client, l'original chez le prestataire.
    var mediaPath: String { path.isEmpty ? (proxyPath ?? "") : path }
}

struct Project: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var client: String
    var kind: MediaKind
    var versions: [ProjectVersion]
    var created: Date
    var currentVersion: ProjectVersion? { versions.max(by: { $0.number < $1.number }) }
}

struct Annotation: Codable, Identifiable, Hashable {
    var id: UUID
    var versionID: UUID
    var author: Author
    var kind: AnnotationKind
    var x: Double, y: Double, w: Double, h: Double   // 0…1 dans l'image
    var time: Double?                                // secondes (vidéo)
    var page: Int?                                   // page (PDF)
    var text: String
    var status: ReviewStatus
    var deleted: Bool
    var lamport: Int
    var created: Date
}

struct ChatMessage: Codable, Identifiable, Hashable {
    var id: UUID
    var versionID: UUID
    var annotationID: UUID?
    var author: Author
    var text: String
    var deleted: Bool
    var lamport: Int
    var created: Date
}

enum OpKind: String, Codable { case annotation, message }

struct Op: Codable, Identifiable, Hashable {
    var id: UUID
    var author: String     // identifiant de l'auteur
    var seq: Int           // numéro d'ordre propre à l'auteur : sert à ne renvoyer que ce que l'autre côté n'a pas
    var lamport: Int
    var kind: OpKind
    var payload: Data      // JSON de l'annotation ou du message
}

/// Position de lecture partagée (mode « Suivez-moi »).
struct Cursor: Codable, Equatable {
    var versionID: UUID?
    var time: Double
    var playing: Bool
    var page: Int?
}

struct PeerInfo: Codable, Equatable {
    var name: String
    var role: String       // "host" ou "client"
    var authorID: String
}

enum JSON {
    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
