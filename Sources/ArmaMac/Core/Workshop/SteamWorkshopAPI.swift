import Foundation

/// Reads Steam Workshop metadata through the public, key-free endpoint
/// `ISteamRemoteStorage/GetPublishedFileDetails`.
///
/// This is what fills in mod titles, preview images, sizes and update times, and it also
/// resolves a Workshop *collection* into the items it contains.
struct SteamWorkshopAPI: Sendable {
    var session: URLSession = .shared
    /// Steam rejects very large batches; 100 ids per request is comfortably inside the limit.
    var batchSize = 100

    enum APIError: Error, LocalizedError {
        case badStatus(Int)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case let .badStatus(code): "Steam Workshop API returned HTTP \(code)."
            case .malformedResponse: "Steam Workshop API sent a response we could not read."
            }
        }
    }

    // MARK: - Wire format

    private struct DetailsEnvelope: Decodable {
        struct Response: Decodable { var publishedfiledetails: [Detail]? }
        var response: Response
    }

    private struct Detail: Decodable {
        struct Tag: Decodable { var tag: String? }
        var publishedfileid: String?
        var result: Int?
        var creator: String?
        var title: String?
        var description: String?
        var file_size: StringOrInt?
        var preview_url: String?
        var time_created: Int?
        var time_updated: Int?
        var subscriptions: Int?
        var favorited: Int?
        var tags: [Tag]?
        var file_type: Int?
        var children: [Child]?
    }

    private struct Child: Decodable {
        var publishedfileid: String?
    }

    /// Steam returns `file_size` as a string on some endpoints and a number on others.
    private struct StringOrInt: Decodable {
        var value: Int64?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let int = try? container.decode(Int64.self) { value = int }
            else if let text = try? container.decode(String.self) { value = Int64(text) }
            else { value = nil }
        }
    }

    private struct CollectionEnvelope: Decodable {
        struct Response: Decodable { var collectiondetails: [CollectionDetail]? }
        var response: Response
    }

    private struct CollectionDetail: Decodable {
        struct Item: Decodable {
            var publishedfileid: String?
            var sortorder: Int?
        }
        var publishedfileid: String?
        var result: Int?
        var children: [Item]?
    }

    // MARK: - Requests

    /// Fetches metadata for the given workshop ids, in batches.
    func details(for ids: [UInt64]) async throws -> [UInt64: WorkshopDetails] {
        var results: [UInt64: WorkshopDetails] = [:]
        for chunk in ids.uniqued().chunked(into: batchSize) {
            try Task.checkCancellation()
            let batch = try await fetchDetails(chunk)
            results.merge(batch) { current, _ in current }
        }
        return results
    }

    private func fetchDetails(_ ids: [UInt64]) async throws -> [UInt64: WorkshopDetails] {
        guard !ids.isEmpty else { return [:] }
        var body = "itemcount=\(ids.count)"
        for (index, id) in ids.enumerated() {
            body += "&publishedfileids%5B\(index)%5D=\(id)"
        }

        let data = try await post(
            url: URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")!,
            body: body
        )
        let envelope = try JSONDecoder().decode(DetailsEnvelope.self, from: data)

        var results: [UInt64: WorkshopDetails] = [:]
        for detail in envelope.response.publishedfiledetails ?? [] {
            guard let idText = detail.publishedfileid, let id = UInt64(idText) else { continue }
            results[id] = WorkshopDetails(
                publishedFileID: id,
                // result != 1 means delisted, private or removed; keep the row with an
                // empty title so the UI can flag it rather than silently dropping it.
                title: detail.result == 1 ? (detail.title ?? "") : "",
                previewURL: detail.preview_url.flatMap(URL.init(string:)),
                fileSize: detail.file_size?.value,
                timeUpdated: detail.time_updated.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                timeCreated: detail.time_created.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                subscriptions: detail.subscriptions,
                favorited: detail.favorited,
                creatorSteamID: detail.creator,
                descriptionText: detail.description,
                tags: (detail.tags ?? []).compactMap(\.tag)
            )
        }
        return results
    }

    /// Expands a Workshop collection into its member ids, preserving the author's order.
    func collectionItems(collectionID: UInt64) async throws -> [UInt64] {
        let body = "collectioncount=1&publishedfileids%5B0%5D=\(collectionID)"
        let data = try await post(
            url: URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetCollectionDetails/v1/")!,
            body: body
        )
        let envelope = try JSONDecoder().decode(CollectionEnvelope.self, from: data)
        guard let collection = envelope.response.collectiondetails?.first,
              collection.result == 1
        else { return [] }

        return (collection.children ?? [])
            .sorted { ($0.sortorder ?? 0) < ($1.sortorder ?? 0) }
            .compactMap { $0.publishedfileid.flatMap(UInt64.init) }
    }

    private func post(url: URL, body: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw APIError.badStatus(http.statusCode)
        }
        return data
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
