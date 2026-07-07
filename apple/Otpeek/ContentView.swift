import SwiftUI

#if os(iOS)
/// iOS 계정 목록의 폴더 필터. macOS 는 사이드바가 담당한다.
enum FolderFilter: Hashable {
    case all, favorites, uncategorized, folder(String)
}
#endif

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    #if os(iOS)
    @EnvironmentObject var store: StoreManager
    // iOS 는 설정을 담을 별도 씬(macOS Settings/MenuBar)이 없으므로 시트로 띄운다.
    @State private var showingSettings = false
    // iOS 폴더(그룹) 필터/편집 상태.
    @State private var folderFilter: FolderFilter = .all
    @State private var editingFolder: OtpFolder?

    /// 선택된 폴더 칩에 맞춰 계정 목록을 필터링해서 보여준다.
    @ViewBuilder private var filteredAccountList: some View {
        switch folderFilter {
        case .all:            AccountListView()
        case .favorites:      AccountListView(showOnlyFavorites: true)
        case .uncategorized:  AccountListView(folderId: "uncategorized")
        case .folder(let id): AccountListView(folderId: id)
        }
    }
    #endif

    var body: some View {
        #if os(iOS)
        NavigationStack {
            VStack(spacing: 0) {
                FolderChipBar(filter: $folderFilter, onEdit: { editingFolder = $0 })
                filteredAccountList
                // 하단 배너 광고(무료 사용자). "Remove Ads" 구매 시 즉시 사라진다.
                if !store.adsRemoved {
                    AdBannerView().frame(height: 60)
                }
            }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button {
                                appState.showingQRScanner = true
                            } label: {
                                Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                            }

                            Button {
                                appState.showingQRImageImport = true
                            } label: {
                                Label("Import from Image", systemImage: "photo")
                            }

                            Button {
                                appState.showingAddAccount = true
                            } label: {
                                Label("Add Manually", systemImage: "plus")
                            }

                            Divider()

                            Button {
                                appState.showingAddFolder = true
                            } label: {
                                Label("New Folder", systemImage: "folder.badge.plus")
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
                .sheet(isPresented: $appState.showingAddAccount) {
                    AddAccountView()
                        .environmentObject(appState)
                }
                .sheet(isPresented: $appState.showingQRScanner) {
                    QRScannerView()
                        .environmentObject(appState)
                }
                .sheet(isPresented: $appState.showingQRImageImport) {
                    QRImageImportView()
                        .environmentObject(appState)
                }
                .sheet(isPresented: $showingSettings) {
                    NavigationStack {
                        SettingsView()
                            .environmentObject(appState)
                            .navigationTitle("Settings")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { showingSettings = false }
                                }
                            }
                    }
                }
                .sheet(isPresented: $appState.showingAddFolder) {
                    AddFolderView()
                        .environmentObject(appState)
                }
                .sheet(item: $editingFolder) { folder in
                    EditFolderView(folder: folder)
                        .environmentObject(appState)
                }
        }
        #else
        NavigationSplitView {
            SidebarView()
        } detail: {
            AccountListView()
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

// MARK: - iOS Folder Chip Bar

#if os(iOS)
/// 계정 목록 위 가로 스크롤 폴더(그룹) 칩 바. 탭으로 필터 전환, 롱프레스로 편집/삭제.
struct FolderChipBar: View {
    @EnvironmentObject var appState: AppState
    @Binding var filter: FolderFilter
    var onEdit: (OtpFolder) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "All", icon: "square.grid.2x2",
                     count: appState.accounts.count, value: .all)

                chip(title: "Favorites", icon: "star.fill",
                     count: appState.accounts.filter { $0.isFavorite }.count, value: .favorites)

                ForEach(appState.folders) { folder in
                    chip(title: folder.name, icon: folder.iconName,
                         count: appState.accountCount(inFolder: folder.id), value: .folder(folder.id))
                        .contextMenu {
                            Button { onEdit(folder) } label: { Label("Edit Folder", systemImage: "pencil") }
                            Button(role: .destructive) {
                                if filter == .folder(folder.id) { filter = .all }
                                appState.deleteFolder(folder)
                            } label: { Label("Delete Folder", systemImage: "trash") }
                        }
                }

                chip(title: "Uncategorized", icon: "tray",
                     count: appState.unfolderedAccounts.count, value: .uncategorized)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    @ViewBuilder
    private func chip(title: String, icon: String, count: Int, value: FolderFilter) -> some View {
        let selected = filter == value
        Button {
            filter = value
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(selected ? Color.white.opacity(0.9) : .secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(selected ? Color.accentColor : Color.secondary.opacity(0.15))
            )
            .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}
#endif

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(AppState())
}
