import Foundation

/// Mirrors workshop mods into `<Arma 3>/!Workshop` as symlinks.
///
/// Arma is far happier with mod paths under its own install directory — especially through
/// Wine, where a workshop folder can sit on a different drive letter. This is the same
/// trick arma3-unix-launcher uses, and it keeps `-mod=` short enough to avoid the command
/// line length limit on large modsets.
struct ModLinker: Sendable {
    enum LinkError: Error, LocalizedError {
        case notWritable(URL)
        case failed(String, underlying: String)

        var errorDescription: String? {
            switch self {
            case let .notWritable(url):
                "Cannot write to \(url.path(percentEncoded: false)). Check the folder's permissions."
            case let .failed(name, underlying):
                "Could not link \(name): \(underlying)"
            }
        }
    }

    struct Result: Sendable {
        var linked: [String: URL] = [:]   // link name → link location
        var reused = 0
        var created = 0
        var removed = 0
    }

    var installation: GameInstallation

    private var linkRoot: URL { installation.workshopLinkDirectory }

    /// True when a link target lives in a Steam workshop folder for Arma 3 — i.e. we made
    /// it. Matching the path segment rather than one library's folder also covers a second
    /// Steam library and SteamCMD's own copy, which use the same layout.
    private func pointsIntoWorkshop(_ url: URL) -> Bool {
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
            .path(percentEncoded: false)
        return target.contains("/steamapps/workshop/content/\(Arma3.appIDString)/")
    }

    /// A stable, filesystem-safe folder name for a mod.
    ///
    /// Spaces are squeezed out along with the illegal characters. `-mod=` is a single
    /// argument holding a semicolon-separated list, and Arma re-parses it from the raw
    /// command line, so a link called `@Advanced Combat Environment` would be read as
    /// three separate arguments and the mod would silently not load. The name here is
    /// only ever a folder name; the game shows each mod's real name from its `mod.cpp`.
    static func linkName(for mod: Mod) -> String {
        // Prefer the mod's own @Name; fall back to the workshop id so two mods never collide.
        var base = mod.name.hasPrefix("@") ? mod.name : "@" + mod.name
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\0")
        base = base.components(separatedBy: illegal).joined(separator: "_")
        base = base.trimmingCharacters(in: .whitespaces)
        base = base.components(separatedBy: .whitespacesAndNewlines).joined(separator: "_")
        if base.count <= 1 { base = "@\(mod.folderName)" }
        if base.count > 64 { base = String(base.prefix(64)) }
        return base
    }

    /// The mods that get a link: every workshop mod, plus anything whose own path would
    /// put a space in `-mod=` — which would break the argument for *all* mods, not just
    /// that one.
    static func needsLink(_ mod: Mod) -> Bool {
        switch mod.origin {
        case .workshop: true
        case .bundled: false
        case .local:
            mod.folderName.contains(" ") || mod.path.path(percentEncoded: false).contains(" ")
        }
    }

    /// The link each mod would get, without touching the filesystem.
    ///
    /// Lets the UI show the real `-mod=` argument before anything has been linked.
    func plannedLinks(for mods: [Mod]) -> [String: URL] {
        var links: [String: URL] = [:]
        for mod in mods where Self.needsLink(mod) {
            var name = Self.linkName(for: mod)
            if links[name] != nil, let id = mod.publishedFileID { name = "\(name)_\(id)" }
            links[name] = linkRoot.appending(path: name)
        }
        return links
    }

    /// Creates (or refreshes) links for `mods`, then prunes links we no longer need.
    @discardableResult
    func synchronise(mods: [Mod], pruneStale: Bool = true) throws -> Result {
        let fileManager = FileManager.default
        var result = Result()

        let linkable = mods.filter(Self.needsLink)
        guard !linkable.isEmpty || pruneStale else { return result }

        if !fileManager.fileExists(atPath: linkRoot.path(percentEncoded: false)) {
            do {
                try fileManager.createDirectory(at: linkRoot, withIntermediateDirectories: true)
            } catch {
                throw LinkError.notWritable(installation.directory)
            }
        }

        var wanted = Set<String>()
        for mod in linkable {
            var name = Self.linkName(for: mod)
            // Disambiguate when two mods claim the same display name.
            if wanted.contains(name), let id = mod.publishedFileID {
                name = "\(name)_\(id)"
            }
            wanted.insert(name)

            let link = linkRoot.appending(path: name)
            let target = mod.path.standardizedFileURL

            let existing = try? fileManager.destinationOfSymbolicLink(
                atPath: link.path(percentEncoded: false)
            )
            if let existing {
                let resolved = existing.hasPrefix("/")
                    ? URL(filePath: existing)
                    : URL(filePath: existing, relativeTo: linkRoot)
                if resolved.standardizedFileURL == target {
                    result.reused += 1
                    result.linked[name] = link
                    continue
                }
                try? fileManager.removeItem(at: link)
            } else if fileManager.fileExists(atPath: link.path(percentEncoded: false)) {
                // A real folder is sitting where we want the link; leave the user's data alone.
                result.linked[name] = link
                continue
            }

            do {
                try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
                result.created += 1
                result.linked[name] = link
            } catch {
                throw LinkError.failed(mod.name, underlying: error.localizedDescription)
            }
        }

        if pruneStale {
            result.removed = pruneLinks(keeping: wanted)
        }
        return result
    }

    /// Removes the links this launcher manages that are no longer needed.
    ///
    /// Only links pointing into Steam's workshop folder are ours to delete. A link the user
    /// made by hand — say, to a mod checked out elsewhere — is left alone, and so is any
    /// real folder.
    @discardableResult
    func pruneLinks(keeping: Set<String>) -> Int {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: linkRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return 0 }

        var removed = 0
        for entry in entries {
            let name = entry.lastPathComponent
            guard let destination = try? fileManager.destinationOfSymbolicLink(
                atPath: entry.path(percentEncoded: false)
            ) else { continue }  // only ever delete symlinks, never real folders

            let resolved = destination.hasPrefix("/")
                ? URL(filePath: destination)
                : URL(filePath: destination, relativeTo: linkRoot)
            let isDangling = !fileManager.fileExists(atPath: resolved.path(percentEncoded: false))

            guard isDangling || pointsIntoWorkshop(resolved) else { continue }
            if !keeping.contains(name) || isDangling {
                if (try? fileManager.removeItem(at: entry)) != nil { removed += 1 }
            }
        }
        return removed
    }
}
