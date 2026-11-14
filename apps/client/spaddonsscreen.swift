// Settings' Addons pages for one game (spsettings.swift pushes them from the game's section): Installed,
// with each addon's version and where it updates from, Update, Update All, Remove, and the "Update
// Automatically" switch; Browse, the catalog filtered to the game; Add from GitHub…; and Open AddOns Folder.
// The work is spaddons.m's, on its queue (sp_addons_run, through spswift.h); these pages only show what
// it reads back (sp_addons_rows, sp_addons_browse) and say what went wrong.
import SwiftUI
import UIKit

private func say(_ s: String) { sp_launch_say("addons: " + s) }

// One row of Installed (spaddons.h's sp_addons_list).
struct AddonRow: Identifiable, Hashable {
    let id: String, name: String, version: String, source: String, folders: [String]
    let latest: String?, update: Bool, catalog: String?, previous: String?, updated: Date?, needs: [String]
    init(_ d: NSDictionary) {
        id = d["id"] as? String ?? ""
        name = d["name"] as? String ?? id
        version = d["version"] as? String ?? ""
        source = d["source"] as? String ?? "hand"
        folders = d["folders"] as? [String] ?? []
        latest = d["latest"] as? String
        update = d["update"] as? Bool ?? false
        catalog = d["catalog"] as? String
        previous = d["previous"] as? String
        updated = (d["updated"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        needs = d["needs"] as? [String] ?? []
    }
    // Installed by Slashplayed, so it can remove it; a folder added by hand is the person's to remove, in Files.
    var removable: Bool { source == "catalog" || source == "github" }
}

// One addon the catalog offers for the game (sp_addons_offered).
struct CatalogAddon: Identifiable, Hashable {
    let id: String, name: String, notes: String, version: String, folders: [String], requires: [String]
    init(_ d: NSDictionary) {
        id = d["id"] as? String ?? ""
        name = d["name"] as? String ?? id
        notes = d["notes"] as? String ?? ""
        version = d["version"] as? String ?? ""
        let file = d["file"] as? [String: Any] ?? [:]
        folders = (file["folders"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        requires = file["requires"] as? [String] ?? []
    }
}

// The asks the pages make, each with Cancel as its default.
enum AddonAsk: Identifiable {
    case remove(AddonRow)
    case dependencies(CatalogAddon, [CatalogAddon])  // an install whose requirements the catalog has
    var id: String {
        switch self {
        case .remove(let r): "remove-" + r.id
        case .dependencies(let a, _): "deps-" + a.id
        }
    }
}

// One game's addons, shared by its Installed and Browse pages.
final class Addons: ObservableObject {
    let flavor: String
    @Published var rows: [AddonRow] = []
    @Published var offered: [CatalogAddon] = []
    @Published var busy: Set<String> = []  // ids being worked on; "all", "link", and "catalog" for the rest
    @Published var problem: String?
    @Published var ask: AddonAsk?
    @Published var linkShown = false
    @Published var link = ""
    @Published var automatic = sp_addons_auto()
    private var refreshed = false
    private var afterRefresh: [() -> Void] = []

    init(flavor: String) {
        self.flavor = flavor
        reload()
    }

    func reload() {
        rows = sp_addons_rows(flavor).map { AddonRow($0 as NSDictionary) }
        offered = sp_addons_browse(flavor).map { CatalogAddon($0 as NSDictionary) }
    }

    // The catalog (and GitHub links' latest releases), once per sheet: the Installed page's updates come from it.
    // `then` runs once it's done.
    func refreshOnce(then: (() -> Void)? = nil) {
        if let then { afterRefresh.append(then) }
        if refreshed {
            if !busy.contains("catalog") { runAfterRefresh() }
            return
        }
        refreshed = true
        busy.insert("catalog")
        sp_addons_refresh(flavor) { [weak self] problem in
            guard let self else { return }
            busy.remove("catalog")
            reload()
            // Offline with a catalog kept from before: the lists say what they can, without an alert.
            if let problem, offered.isEmpty { self.problem = problem }
            runAfterRefresh()
        }
    }

    private func runAfterRefresh() {
        let waiting = afterRefresh
        afterRefresh = []
        waiting.forEach { $0() }
    }

    // Settings' addon-install, addon-update, addon-remove, and addon-link drills: the install tap (with its
    // dependency ask), the update tap, the removal with no confirmation, or Add from GitHub with `id` typed, once
    // the catalog's in.
    func drill(_ action: String, _ id: String) {
        refreshOnce { [self] in
            if action == "link" { link = id; addLink() }
            else if action == "remove", let r = rows.first(where: { $0.id == id }) { remove(r) }
            else if action == "update", let r = rows.first(where: { $0.id == id }) { update(r) }
            else if action == "install", let a = offered.first(where: { $0.id == id }) { install(a) }
            else { say("drill: no \(action == "install" ? "catalog" : "installed") addon \(id) for \(flavor)") }
        }
    }

    private func run(_ action: String, _ argument: String, busy key: String) {
        busy.insert(key)
        sp_addons_run(flavor, action, argument) { [weak self] problem in
            guard let self else { return }
            busy.remove(key)
            reload()
            if let problem { self.problem = problem }
        }
    }

    private var installedFolders: Set<String> { Set(rows.flatMap(\.folders).map { $0.lowercased() }) }

    // The catalog's addon that installs `folder`, if any.
    func providing(_ folder: String) -> CatalogAddon? {
        offered.first { $0.folders.contains { $0.caseInsensitiveCompare(folder) == .orderedSame } }
    }

    // Install: first asks to add what it requires when the catalog has it.
    func install(_ addon: CatalogAddon) {
        let have = installedFolders
        let deps = addon.requires.filter { !have.contains($0.lowercased()) }.compactMap(providing)
        if deps.isEmpty { run("install", addon.id, busy: addon.id) }
        else { ask = .dependencies(addon, Array(Set(deps)).sorted { $0.name < $1.name }) }
    }

    // After the dependency ask: the requirements first, so the addon's first start finds them.
    func install(_ addon: CatalogAddon, with deps: [CatalogAddon]) {
        for d in deps { run("install", d.id, busy: d.id) }
        run("install", addon.id, busy: addon.id)
    }

    func update(_ row: AddonRow) { run("update", row.id, busy: row.id) }
    func updateAll() { run("update-all", "", busy: "all") }
    func remove(_ row: AddonRow) { run("remove", row.id, busy: row.id) }

    func addLink() {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        link = ""
        if !text.isEmpty { run("link", text, busy: "link") }
    }

    func setAutomatic(_ on: Bool) {
        sp_addons_set_auto(on)
        automatic = sp_addons_auto()
    }

    // The game's Interface/AddOns in Files (as Settings' Open in Files opens the game's folder): before anything
    // made it, the nearest folder there is.
    func openFolder() {
        var folder = sp_addons_folder(flavor)
        var directory: ObjCBool = false
        while !(FileManager.default.fileExists(atPath: folder, isDirectory: &directory) && directory.boolValue) && folder.count > 1 {
            folder = (folder as NSString).deletingLastPathComponent
        }
        var url = URLComponents()
        url.scheme = "shareddocuments"
        url.path = folder
        guard let target = url.url else { return }
        UIApplication.shared.open(target) { opened in
            say("open \(self.flavor) folder: \((folder as NSString).lastPathComponent) \(opened ? "opened" : "refused")")
        }
    }
}

// What a row says under its name: its version, where it updates from, and what's new.
private func detail(_ r: AddonRow) -> String {
    var parts: [String] = []
    if r.update, let latest = r.latest, !latest.isEmpty {
        parts.append(r.version.isEmpty ? "Update to \(latest)" : "\(r.version) → \(latest)")
    } else if !r.version.isEmpty {
        parts.append(r.version)
    }
    switch r.source {
    case "catalog": parts.append("From the catalog")
    case "github": parts.append("From GitHub")
    default: parts.append(r.catalog != nil ? "Added by hand, in the catalog" : "Updated by hand")
    }
    if let when = r.updated, let previous = r.previous, -when.timeIntervalSinceNow < 7 * 86400, !r.update {
        parts.append("Updated from \(previous.isEmpty ? "an earlier version" : previous) \(when.formatted(.relative(presentation: .named)))")
    }
    return parts.joined(separator: " · ")
}

private struct BusyOr<Content: View>: View {
    let busy: Bool
    @ViewBuilder let content: Content
    var body: some View {
        if busy { ProgressView() } else { content }
    }
}

struct AddonsView: View {
    @ObservedObject var addons: Addons
    let settings: Settings

    private var name: String { sp_flavor_name(addons.flavor) }

    var body: some View {
        List {
            installed
            updates
            add
        }
        .listStyle(.insetGrouped)
        .navigationTitle("\(name) Addons")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { DoneButton(settings: settings) }
        .onAppear { addons.reload(); addons.refreshOnce() }
        .modifier(AddonAlerts(addons: addons))
    }

    private var installed: some View {
        Section {
            if addons.rows.isEmpty {
                Text("No addons yet.").foregroundStyle(.secondary)
            }
            ForEach(addons.rows) { r in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(r.name)
                        Spacer()
                        BusyOr(busy: addons.busy.contains(r.id) || (addons.busy.contains("all") && r.update)) {
                            if r.update { Button("Update") { addons.update(r) }.buttonStyle(.borderless) }
                        }
                    }
                    Text(detail(r)).font(.subheadline).foregroundStyle(.secondary)
                    ForEach(r.needs, id: \.self) { need in
                        if let provider = addons.providing(need) {
                            Button("Needs \(need): Install \(provider.name)") { addons.install(provider) }
                                .font(.subheadline).buttonStyle(.borderless)
                        } else {
                            Text("Needs \(need), which isn’t in the catalog.").font(.subheadline).foregroundStyle(.orange)
                        }
                    }
                }
                .swipeActions {
                    if r.removable { Button("Remove", role: .destructive) { addons.ask = .remove(r) } }
                }
                .contextMenu {
                    if r.removable { Button("Remove", systemImage: "trash", role: .destructive) { addons.ask = .remove(r) } }
                }
            }
        } header: {
            Text("Installed")
        } footer: {
            Text("Changes apply the next time \(name) starts. Addons you added in Files are updated by hand, unless the catalog has them: then Update replaces them with the catalog’s.")
        }
    }

    private var updates: some View {
        Section {
            if addons.rows.contains(where: \.update) {
                BusyOr(busy: addons.busy.contains("all")) {
                    Button("Update All") { addons.updateAll() }
                }
            }
            Toggle("Update Automatically", isOn: Binding(get: { addons.automatic }, set: { addons.setAutomatic($0) }))
        } footer: {
            Text("For every game. When Slashplayed opens, it checks at most every few hours, and updates the addons it installed.")
        }
    }

    private var add: some View {
        Section {
            NavigationLink(value: Page.browse(addons.flavor)) {
                LabeledContent("Browse the Catalog") {
                    if addons.busy.contains("catalog") && addons.offered.isEmpty { ProgressView() }
                    else { Text("\(addons.offered.count)") }
                }
            }
            BusyOr(busy: addons.busy.contains("link")) {
                Button("Add from GitHub…") { addons.linkShown = true }
            }
            Button("Open AddOns Folder") { addons.openFolder() }
        } footer: {
            Text("Each addon downloads from where its author publishes it, checked against Slashplayed’s catalog. Add from GitHub installs the latest release of a repository the catalog doesn’t have.")
        }
    }
}

// The catalog's addons for the game, searchable.
struct AddonBrowseView: View {
    @ObservedObject var addons: Addons
    let settings: Settings
    @State private var search = ""

    private var shown: [CatalogAddon] {
        let s = search.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return addons.offered }
        return addons.offered.filter { $0.name.localizedCaseInsensitiveContains(s) || $0.notes.localizedCaseInsensitiveContains(s) }
    }

    var body: some View {
        List {
            Section {
                if addons.offered.isEmpty {
                    if addons.busy.contains("catalog") { ProgressView() }
                    else { Text("The catalog couldn’t be downloaded. Check your connection, then come back.").foregroundStyle(.secondary) }
                }
                ForEach(shown) { a in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.name)
                            if !a.notes.isEmpty { Text(a.notes).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                            Text(a.version).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        BusyOr(busy: addons.busy.contains(a.id)) { action(a) }
                    }
                }
            } footer: {
                if !addons.offered.isEmpty {
                    Text("Addons whose authors publish them on GitHub, WoWInterface, or Tukui, for \(sp_flavor_name(addons.flavor)). Addons only on CurseForge or Wago aren’t here: add those in Files.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search)
        .navigationTitle("Catalog")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { DoneButton(settings: settings) }
        .onAppear { addons.refreshOnce() }
        .modifier(AddonAlerts(addons: addons))
    }

    @ViewBuilder private func action(_ a: CatalogAddon) -> some View {
        if let row = addons.rows.first(where: { $0.id == a.id || $0.catalog == a.id }) {
            if row.update { Button("Update") { addons.update(row) }.buttonStyle(.borderless) }
            else { Text("Installed").foregroundStyle(.secondary) }
        } else {
            Button("Install") { addons.install(a) }.buttonStyle(.borderless)
        }
    }
}

// The pages' alerts: what went wrong, Remove's confirmation, the dependency ask, and Add from GitHub's field.
private struct AddonAlerts: ViewModifier {
    @ObservedObject var addons: Addons

    func body(content: Content) -> some View {
        content
            .alert("Addons", isPresented: Binding(get: { addons.problem != nil }, set: { if !$0 { addons.problem = nil } })) {
                Button("OK") {}
            } message: {
                Text(addons.problem ?? "")
            }
            .alert(askTitle, isPresented: Binding(get: { addons.ask != nil }, set: { if !$0 { addons.ask = nil } }),
                   presenting: addons.ask) { ask in
                switch ask {
                case .remove(let r):
                    Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
                    Button("Remove", role: .destructive) { addons.remove(r) }
                case .dependencies(let a, let deps):
                    Button("Install Both") { addons.install(a, with: deps) }.keyboardShortcut(.defaultAction)
                    Button("Install \(a.name) Only") { addons.install(a, with: []) }
                    Button("Cancel", role: .cancel) {}
                }
            } message: { ask in
                switch ask {
                case .remove(let r):
                    Text("Its folders (\(r.folders.joined(separator: ", "))) are deleted. Its saved settings are kept.")
                case .dependencies(let a, let deps):
                    Text("\(a.name) needs \(deps.map(\.name).formatted(.list(type: .and))), which the catalog has.")
                }
            }
            .alert("Add from GitHub", isPresented: $addons.linkShown) {
                TextField("owner/repo", text: $addons.link)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Cancel", role: .cancel) { addons.link = "" }
                Button("Add") { addons.addLink() }
            } message: {
                Text("owner/repo, or its link. Its latest release is installed and kept up to date.")
            }
    }

    private var askTitle: String {
        switch addons.ask {
        case .remove(let r): "Remove \(r.name)?"
        case .dependencies(let a, _): "Install \(a.name)?"
        case nil: ""
        }
    }
}
