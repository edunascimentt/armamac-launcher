import AppKit
import Foundation

/// Builds the command line and starts Arma 3, whichever way it is installed.
struct GameLauncher: Sendable {
    enum LaunchError: Error, LocalizedError {
        case noInstallation
        case noExecutable
        case noWineRuntime
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .noInstallation:
                "No Arma 3 installation was found. Set one in Settings."
            case .noExecutable:
                "The selected Arma 3 folder has no runnable game binary."
            case .noWineRuntime:
                "This install needs CrossOver or Wine to run, and neither was found."
            case let .launchFailed(reason):
                "Arma 3 could not be started: \(reason)"
            }
        }
    }

    /// Assembles the full plan without running anything — the UI shows this before launch.
    func makePlan(
        installation: GameInstallation,
        mods: [Mod],
        options: LaunchOptions,
        connect: ConnectTarget?,
        linkedMods: [String: URL]
    ) throws -> LaunchPlan {
        guard let executable = installation.executable(
            battlEye: options.useBattlEye, prefer64Bit: options.prefer64Bit
        ) else { throw LaunchError.noExecutable }

        var arguments = options.gameArguments()
        if let connect { arguments.append(contentsOf: connect.arguments()) }

        let modArgument = makeModArgument(
            installation: installation, mods: mods, linkedMods: linkedMods
        )
        if let modArgument { arguments.append(modArgument) }

        var plan = LaunchPlan(
            installation: installation,
            executable: executable,
            arguments: arguments
        )
        plan.displayCommand = describe(plan: plan)
        return plan
    }

    /// `-mod=` with one entry per mod. Workshop mods go through their `!Workshop` symlink so
    /// the path stays relative to the game folder.
    ///
    /// No entry may contain a space. Arma re-reads `-mod=` from the raw command line, so a
    /// single space anywhere truncates the list and the game silently starts vanilla — the
    /// reason the link names are sanitised.
    func makeModArgument(
        installation: GameInstallation,
        mods: [Mod],
        linkedMods: [String: URL]
    ) -> String? {
        guard !mods.isEmpty else { return nil }
        let container = installation.container
        let mapper = container.prefix.map { WinePathMapper(prefix: $0) }
        // The native macOS build takes POSIX paths; only Wine-hosted Arma wants backslashes.
        let separator = container.isWindows ? "\\" : "/"
        var entries: [String] = []

        for mod in mods {
            // A link is always preferred: it is inside the game folder and its name is
            // known to be space-free.
            let name = ModLinker.linkName(for: mod)
            let link = mod.origin == .bundled ? nil : linkedMods[name] ?? linkedMods.first {
                $0.key.hasPrefix(name)
            }?.value

            if let link {
                entries.append("!Workshop\(separator)\(link.lastPathComponent)")
                continue
            }

            switch mod.origin {
            case .bundled:
                // Official content is loaded by its folder name relative to the game dir.
                entries.append(mod.folderName)
            case .workshop:
                if let path = modPath(mod.path, mapper: mapper, container: container) {
                    entries.append(path)
                }
            case .local:
                if isInside(mod.path, of: installation.directory) {
                    entries.append(mod.folderName)
                } else if let path = modPath(mod.path, mapper: mapper, container: container) {
                    entries.append(path)
                }
            }
        }

        guard !entries.isEmpty else { return nil }
        // Arma wants a trailing separator on the list.
        return "-mod=" + entries.joined(separator: ";") + ";"
    }

    private func modPath(
        _ url: URL, mapper: WinePathMapper?, container: RuntimeContainer
    ) -> String? {
        if container.isWindows {
            return mapper?.windowsPath(for: url)
        }
        return url.path(percentEncoded: false)
    }

    private func isInside(_ url: URL, of directory: URL) -> Bool {
        url.standardizedFileURL.path(percentEncoded: false)
            .hasPrefix(directory.standardizedFileURL.path(percentEncoded: false) + "/")
    }

    // MARK: - Running

    /// Starts the game and returns the process that was spawned, when there is one.
    /// Steam-mediated launches hand off to the Steam client and return nil.
    ///
    /// Launching an `.app` bundle is asynchronous and can fail long after this returns —
    /// a damaged or quarantined bundle, for instance — so failures that arrive late are
    /// reported through `onAsyncFailure` rather than being dropped.
    @discardableResult
    func launch(
        plan: LaunchPlan,
        viaSteam: Bool,
        onAsyncFailure: (@Sendable (String) -> Void)? = nil
    ) throws -> Process? {
        if viaSteam {
            try launchThroughSteam(plan: plan)
            return nil
        }

        switch plan.installation.container {
        case .native:
            return try launchNative(plan: plan, onAsyncFailure: onAsyncFailure)
        case let .crossover(bottle, _):
            return try launchCrossOver(plan: plan, bottle: bottle)
        case let .wine(_, prefix, binary):
            return try launchWine(plan: plan, prefix: prefix, wine: binary)
        }
    }

    /// `steam://run/107410//<args>` — Steam then applies its own overlay and cloud sync,
    /// exactly like pressing Play in the library.
    private func launchThroughSteam(plan: LaunchPlan) throws {
        let joined = plan.arguments.joined(separator: " ")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&?#/")
        let encoded = joined.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        guard let url = URL(string: "steam://run/\(Arma3.appIDString)//\(encoded)") else {
            throw LaunchError.launchFailed("could not build the steam:// URL")
        }
        // `open` reports whether anything handled the URL; ignoring it made a missing Steam
        // install look like a successful launch.
        guard NSWorkspace.shared.open(url) else {
            throw LaunchError.launchFailed(
                "nothing handled the steam:// link. Is the Steam client installed?"
            )
        }
    }

    private func launchNative(
        plan: LaunchPlan,
        onAsyncFailure: (@Sendable (String) -> Void)? = nil
    ) throws -> Process? {
        let url = plan.executable.url
        if url.pathExtension == "app" {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = plan.arguments
            if !plan.environment.isEmpty { configuration.environment = plan.environment }

            NSWorkspace.shared.openApplication(
                at: url, configuration: configuration
            ) { _, error in
                // Without this handler a failed launch was completely silent: the UI said
                // "Launching Arma 3…" and nothing ever happened.
                if let error {
                    onAsyncFailure?(
                        LaunchError.launchFailed(error.localizedDescription).localizedDescription
                    )
                }
            }
            return nil
        }

        return try run(
            executable: url,
            arguments: plan.arguments,
            workingDirectory: plan.installation.directory,
            environment: plan.environment
        )
    }

    private func launchCrossOver(plan: LaunchPlan, bottle: String) throws -> Process {
        let wine = SteamLocator.crossOverWine
        guard FileManager.default.isExecutableFile(atPath: wine.path(percentEncoded: false)) else {
            throw LaunchError.noWineRuntime
        }
        let mapper = plan.installation.container.prefix.map { WinePathMapper(prefix: $0) }
        let exePath = mapper?.windowsPath(for: plan.executable.url)
            ?? plan.executable.url.path(percentEncoded: false)

        var arguments = [
            "--bottle", bottle,
            "--workdir", plan.installation.directory.path(percentEncoded: false),
            "--cx-app", exePath,
        ]
        arguments.append(contentsOf: plan.arguments)

        return try run(
            executable: wine,
            arguments: arguments,
            workingDirectory: plan.installation.directory,
            environment: plan.environment
        )
    }

    private func launchWine(plan: LaunchPlan, prefix: URL, wine: URL) throws -> Process {
        var environment = plan.environment
        environment["WINEPREFIX"] = prefix.path(percentEncoded: false)
        let mapper = WinePathMapper(prefix: prefix)
        let exePath = mapper.windowsPath(for: plan.executable.url)
            ?? plan.executable.url.path(percentEncoded: false)

        return try run(
            executable: wine,
            arguments: [exePath] + plan.arguments,
            workingDirectory: plan.installation.directory,
            environment: environment
        )
    }

    private func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]
    ) throws -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        do {
            try process.run()
        } catch {
            throw LaunchError.launchFailed(error.localizedDescription)
        }
        return process
    }

    /// A copy-pasteable rendering of what will be executed.
    func describe(plan: LaunchPlan) -> String {
        func quote(_ value: String) -> String {
            value.contains(where: \.isWhitespace) ? "\"\(value)\"" : value
        }

        switch plan.installation.container {
        case .native:
            return ([plan.executable.url.path(percentEncoded: false)] + plan.arguments)
                .map(quote).joined(separator: " ")
        case let .crossover(bottle, prefix):
            let mapper = WinePathMapper(prefix: prefix)
            let exe = mapper.windowsPath(for: plan.executable.url)
                ?? plan.executable.url.path(percentEncoded: false)
            return ([
                SteamLocator.crossOverWine.path(percentEncoded: false),
                "--bottle", bottle, "--cx-app", exe,
            ] + plan.arguments).map(quote).joined(separator: " ")
        case let .wine(_, prefix, binary):
            let mapper = WinePathMapper(prefix: prefix)
            let exe = mapper.windowsPath(for: plan.executable.url)
                ?? plan.executable.url.path(percentEncoded: false)
            return "WINEPREFIX=\(quote(prefix.path(percentEncoded: false))) "
                + ([binary.path(percentEncoded: false), exe] + plan.arguments)
                .map(quote).joined(separator: " ")
        }
    }
}
