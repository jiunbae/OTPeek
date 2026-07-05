import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        #if os(iOS)
        NavigationStack {
            AccountListView()
                .navigationTitle("OTP Authenticator")
                .toolbar {
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

                            Divider()

                            Button {
                                appState.showingAddAccount = true
                            } label: {
                                Label("Add Manually", systemImage: "plus")
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

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(AppState())
}
