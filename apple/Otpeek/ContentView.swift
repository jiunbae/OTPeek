import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    #if os(iOS)
    @State private var selectedTab: IOSTab = IOSTab.initialFromLaunchArguments
    #endif

    var body: some View {
        #if os(iOS)
        iosTabs
            .sheet(isPresented: $appState.showingAddAccount) {
                AddAccountView().environmentObject(appState)
            }
            .sheet(isPresented: $appState.showingQRScanner) {
                QRScannerView().environmentObject(appState)
            }
            .sheet(isPresented: $appState.showingQRImageImport) {
                QRImageImportView().environmentObject(appState)
            }
            .sheet(isPresented: $appState.showingAddFolder) {
                AddFolderView().environmentObject(appState)
            }
        #else
        NavigationSplitView {
            SidebarView()
        } detail: {
            // Unified with iOS: the main view is the favorites-on-top, folder-grouped
            // list. The sidebar still filters to a single folder when you pick one.
            AccountListView(groupByFolder: true)
        }
        .frame(minWidth: 700, minHeight: 450)
        .sheet(isPresented: $appState.showingAddAccount) {
            AddAccountView()
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showingQRImageImport) {
            QRImageImportView()
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showingAddFolder) {
            AddFolderView()
                .environmentObject(appState)
        }
        #endif
    }

    #if os(iOS)
    /// iOS 26: a 2-tab bar (Accounts · Settings) plus a detached Search dot
    /// (the `.search` role). iOS 17 falls back to three plain tabs.
    @ViewBuilder private var iosTabs: some View {
        if #available(iOS 18.0, *) {
            TabView(selection: $selectedTab) {
                Tab("Accounts", systemImage: "square.grid.2x2", value: IOSTab.all) { allTab }
                Tab("Settings", systemImage: "gearshape", value: IOSTab.settings) { settingsTab }
                Tab(value: IOSTab.search, role: .search) { searchTab }
            }
            .iOS26TabBar()
        } else {
            TabView(selection: $selectedTab) {
                allTab.tabItem { Label("Accounts", systemImage: "square.grid.2x2") }.tag(IOSTab.all)
                settingsTab.tabItem { Label("Settings", systemImage: "gearshape") }.tag(IOSTab.settings)
                searchTab.tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(IOSTab.search)
            }
        }
    }

    @ViewBuilder private var allTab: some View {
        NavigationStack {
            AllScreen()
                // Inline title so "Accounts" shares the bar with "+" instead of
                // taking its own large-title row.
                .navigationBarTitleDisplayMode(.inline)
        }
    }
    @ViewBuilder private var settingsTab: some View {
        NavigationStack {
            SettingsView()
                .environmentObject(appState)
                .navigationTitle("Settings")
        }
    }
    @ViewBuilder private var searchTab: some View {
        NavigationStack {
            AccountListView(searchable: true, titleOverride: "Search")
        }
    }
    #endif
}

// MARK: - macOS Sidebar

#if os(macOS)
struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @State private var editingFolder: OtpFolder?

    var body: some View {
        List(selection: $appState.selectedFolderId) {
            // Quick Actions Section
            Section("Quick Actions") {
                Button {
                    appState.showingQRImageImport = true
                } label: {
                    Label("Import QR Image", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(.plain)

                Button {
                    appState.showingAddAccount = true
                } label: {
                    Label("Add Manually", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)

                Button {
                    pasteOtpUri()
                } label: {
                    Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.plain)
            }

            Section("Library") {
                // All Accounts
                NavigationLink(value: Optional<String>.none) {
                    HStack {
                        Label("All Accounts", systemImage: "list.bullet")
                        Spacer()
                        Text("\(appState.accounts.count)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.2)))
                    }
                }

                // Favorites
                NavigationLink {
                    AccountListView(showOnlyFavorites: true)
                } label: {
                    HStack {
                        Label("Favorites", systemImage: "star.fill")
                            .foregroundColor(.yellow)
                        Spacer()
                        Text("\(appState.favoriteAccounts.count)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.2)))
                    }
                }

                // Uncategorized
                NavigationLink {
                    AccountListView(folderId: "uncategorized")
                } label: {
                    HStack {
                        Label("Uncategorized", systemImage: "tray")
                        Spacer()
                        Text("\(appState.unfolderedAccounts.count)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.2)))
                    }
                }
            }

            // Folders Section
            Section {
                ForEach(appState.folders) { folder in
                    NavigationLink {
                        AccountListView(folderId: folder.id)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: folder.iconName)
                                .foregroundColor(Color(hex: folder.displayColor) ?? .blue)
                                .frame(width: 20)

                            Text(folder.name)

                            Spacer()

                            Text("\(appState.accountCount(inFolder: folder.id))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.secondary.opacity(0.2)))
                        }
                    }
                    .contextMenu {
                        Button {
                            editingFolder = folder
                        } label: {
                            Label("Edit Folder", systemImage: "pencil")
                        }

                        Divider()

                        Button(role: .destructive) {
                            appState.deleteFolder(folder)
                        } label: {
                            Label("Delete Folder", systemImage: "trash")
                        }
                    }
                }
            } header: {
                HStack(alignment: .center, spacing: 8) {
                    Text("Folders")
                        .textCase(.uppercase)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    Button {
                        appState.showingAddFolder = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Add Folder")
                }
                .padding(.trailing, 4)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 220)
        .navigationTitle("OTP")
        .sheet(item: $editingFolder) { folder in
            EditFolderView(folder: folder)
                .environmentObject(appState)
        }
    }

    private func pasteOtpUri() {
        guard let string = NSPasteboard.general.string(forType: .string) else { return }
        appState.addFromUri(string)
    }
}
#endif

// MARK: - Add Folder View

struct AddFolderView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var selectedIcon = "folder.fill"
    @State private var selectedColor = "#007AFF"

    private let icons = ["folder.fill", "briefcase.fill", "building.2.fill", "creditcard.fill",
                         "gamecontroller.fill", "gift.fill", "globe", "heart.fill",
                         "house.fill", "lock.fill", "music.note", "person.fill",
                         "phone.fill", "cart.fill", "envelope.fill", "cloud.fill"]

    private let colors = ["#007AFF", "#34C759", "#FF9500", "#FF3B30",
                          "#5856D6", "#FF2D55", "#00C7BE", "#AF52DE"]

    var body: some View {
        VStack(spacing: 20) {
            Text("New Folder")
                .font(.title2)
                .fontWeight(.semibold)

            TextField("Folder Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)

            // Icon Selection
            VStack(alignment: .leading, spacing: 8) {
                Text("Icon")
                    .font(.headline)

                LazyVGrid(columns: Array(repeating: GridItem(.fixed(36)), count: 8), spacing: 8) {
                    ForEach(icons, id: \.self) { icon in
                        Button {
                            selectedIcon = icon
                        } label: {
                            Image(systemName: icon)
                                .font(.system(size: 16))
                                .frame(width: 32, height: 32)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(selectedIcon == icon ? Color.accentColor.opacity(0.2) : Color.clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(selectedIcon == icon ? Color.accentColor : Color.clear, lineWidth: 2)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Color Selection
            VStack(alignment: .leading, spacing: 8) {
                Text("Color")
                    .font(.headline)

                HStack(spacing: 8) {
                    ForEach(colors, id: \.self) { color in
                        Button {
                            selectedColor = color
                        } label: {
                            Circle()
                                .fill(Color(hex: color) ?? .blue)
                                .frame(width: 28, height: 28)
                                .overlay(
                                    Circle()
                                        .stroke(Color.primary, lineWidth: selectedColor == color ? 2 : 0)
                                        .padding(2)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Preview
            HStack {
                Image(systemName: selectedIcon)
                    .foregroundColor(Color(hex: selectedColor) ?? .blue)
                Text(name.isEmpty ? "Folder Name" : name)
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))

            HStack(spacing: 16) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)

                Button("Create") {
                    let folder = OtpFolder(
                        name: name,
                        icon: selectedIcon,
                        color: selectedColor,
                        sortOrder: appState.folders.count
                    )
                    appState.addFolder(folder)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty)
                .keyboardShortcut(.return)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

// MARK: - Edit Folder View

struct EditFolderView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let folder: OtpFolder
    @State private var name: String
    @State private var selectedIcon: String
    @State private var selectedColor: String

    private let icons = ["folder.fill", "briefcase.fill", "building.2.fill", "creditcard.fill",
                         "gamecontroller.fill", "gift.fill", "globe", "heart.fill",
                         "house.fill", "lock.fill", "music.note", "person.fill",
                         "phone.fill", "cart.fill", "envelope.fill", "cloud.fill"]

    private let colors = ["#007AFF", "#34C759", "#FF9500", "#FF3B30",
                          "#5856D6", "#FF2D55", "#00C7BE", "#AF52DE"]

    init(folder: OtpFolder) {
        self.folder = folder
        _name = State(initialValue: folder.name)
        _selectedIcon = State(initialValue: folder.iconName)
        _selectedColor = State(initialValue: folder.displayColor)
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Edit Folder")
                .font(.title2)
                .fontWeight(.semibold)

            TextField("Folder Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)

            // Icon Selection
            VStack(alignment: .leading, spacing: 8) {
                Text("Icon")
                    .font(.headline)

                LazyVGrid(columns: Array(repeating: GridItem(.fixed(36)), count: 8), spacing: 8) {
                    ForEach(icons, id: \.self) { icon in
                        Button {
                            selectedIcon = icon
                        } label: {
                            Image(systemName: icon)
                                .font(.system(size: 16))
                                .frame(width: 32, height: 32)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(selectedIcon == icon ? Color.accentColor.opacity(0.2) : Color.clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(selectedIcon == icon ? Color.accentColor : Color.clear, lineWidth: 2)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Color Selection
            VStack(alignment: .leading, spacing: 8) {
                Text("Color")
                    .font(.headline)

                HStack(spacing: 8) {
                    ForEach(colors, id: \.self) { color in
                        Button {
                            selectedColor = color
                        } label: {
                            Circle()
                                .fill(Color(hex: color) ?? .blue)
                                .frame(width: 28, height: 28)
                                .overlay(
                                    Circle()
                                        .stroke(Color.primary, lineWidth: selectedColor == color ? 2 : 0)
                                        .padding(2)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 16) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)

                Button("Save") {
                    var updated = folder
                    updated.name = name
                    updated.icon = selectedIcon
                    updated.color = selectedColor
                    appState.updateFolder(updated)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty)
                .keyboardShortcut(.return)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

// MARK: - iOS Tab Navigation (Liquid Glass)

#if os(iOS)
/// Tab bar sections. On iOS 26 the tab bar is Liquid Glass and `.search` renders
/// as a detached dot; the tab bar minimizes on scroll.
enum IOSTab: Hashable {
    case all, settings, search

    /// DEBUG screenshot harness: `-otpeekTab settings|search` opens that tab first.
    static var initialFromLaunchArguments: IOSTab {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-otpeekTab"), i + 1 < args.count {
            switch args[i + 1] {
            case "settings": return .settings
            case "search":   return .search
            default:         break
            }
        }
        #endif
        return .all
    }
}

private extension View {
    /// Applies iOS 26 tab-bar behaviors (the glass look is automatic); no-op on iOS 17–25.
    @ViewBuilder
    func iOS26TabBar() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}

/// The Accounts tab: every account in one scroll, grouped into folder sections
/// (iOS 26 Photos-style). The "+" menu also creates and edits folders.
private struct AllScreen: View {
    @EnvironmentObject var appState: AppState
    @State private var showingManageFolders = false

    var body: some View {
        AccountListView(searchable: false, titleOverride: "Accounts", groupByFolder: true)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { appState.showingQRScanner = true } label: {
                            Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                        }
                        Button { appState.showingQRImageImport = true } label: {
                            Label("Import from Image", systemImage: "photo")
                        }
                        Button { appState.showingAddAccount = true } label: {
                            Label("Add Manually", systemImage: "plus")
                        }
                        Divider()
                        Button { appState.showingAddFolder = true } label: {
                            Label("New Folder", systemImage: "folder.badge.plus")
                        }
                        if !appState.folders.isEmpty {
                            Button { showingManageFolders = true } label: {
                                Label("Edit Folders…", systemImage: "slider.horizontal.3")
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingManageFolders) {
                ManageFoldersView().environmentObject(appState)
            }
    }
}

/// Edit/delete folders — reached from the All screen's title menu.
private struct ManageFoldersView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var editingFolder: OtpFolder?

    var body: some View {
        NavigationStack {
            List {
                ForEach(appState.folders) { folder in
                    Button {
                        editingFolder = folder
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: folder.iconName)
                                .foregroundStyle(Color(hex: folder.displayColor) ?? .blue)
                                .frame(width: 26)
                            Text(folder.name).foregroundStyle(.primary)
                            Spacer()
                            Text("\(appState.accountCount(inFolder: folder.id))")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    offsets.map { appState.folders[$0] }.forEach { appState.deleteFolder($0) }
                }
            }
            .navigationTitle("Folders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { appState.showingAddFolder = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $editingFolder) { folder in
                EditFolderView(folder: folder).environmentObject(appState)
            }
        }
    }
}
#endif

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(AppState())
}
