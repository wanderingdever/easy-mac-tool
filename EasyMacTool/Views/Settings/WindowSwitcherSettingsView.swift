import SwiftUI

/// Window-switcher settings: a global multi-screen target picker at the top,
/// and below it a master-detail list of configurable shortcuts.
struct WindowSwitcherSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var selectedShortcutID: ShortcutConfig.ID?
    /// Tracks the proportional width of the left column. Default 0.2 (20%),
    /// so the shortcut list is narrow and the detail editor is wide (80%).
    @State private var splitFraction: CGFloat = 0.2

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            displayTargetSection
            Divider()
            shortcutSection
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { selectFirstShortcutIfNeeded() }
        .onChange(of: selectedShortcutID) { _, newValue in
            if newValue == nil {
                selectedShortcutID = settings.shortcuts.first?.id
            }
        }
    }

    // MARK: - Multi-screen target (global)

    private var displayTargetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("多屏幕", systemImage: "display")
                .font(.headline)
            Picker("显示于", selection: $settings.displayTarget) {
                ForEach(AppSettings.DisplayTarget.allCases) { target in
                    Text(target.displayName).tag(target)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 480)
            Text("切换窗口面板在哪个屏幕弹出。当前：\(settings.displayTarget.displayName)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Shortcuts

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("快捷键", systemImage: "keyboard")
                .font(.headline)

            // Custom split: left column at `splitFraction` of width, draggable
            // divider in the middle, right column fills the rest. Default 20/80.
            GeometryReader { geo in
                let totalWidth = geo.size.width
                let dividerWidth: CGFloat = 8
                let leftWidth = max(180, min(totalWidth - 380 - dividerWidth,
                                             totalWidth * splitFraction - dividerWidth / 2))
                HStack(spacing: 0) {
                    shortcutListColumn
                        .frame(width: leftWidth)
                    // Draggable divider
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 1)
                        .overlay(
                            Rectangle()
                                .fill(.clear)
                                .frame(width: dividerWidth)
                                .contentShape(Rectangle())
                                .cursor(NSCursor.resizeLeftRight)
                                .gesture(
                                    DragGesture(minimumDistance: 1)
                                        .onChanged { value in
                                            let proposed = leftWidth + value.translation.width
                                            let newFraction = proposed / totalWidth
                                            splitFraction = max(0.15, min(0.6, newFraction))
                                        }
                                )
                        )
                    shortcutDetail
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(minHeight: 280)
        }
    }

    /// Left column: the shortcut list on top, add/delete buttons at the bottom
    /// (matching macOS System Settings layout).
    private var shortcutListColumn: some View {
        VStack(spacing: 0) {
            shortcutList
            Divider()
            // Toolbar with + / − buttons at the bottom, like macOS settings.
            HStack(spacing: 4) {
                Button {
                    let new = ShortcutConfig(name: "快捷键 \(settings.shortcuts.count + 1)",
                                             keyCode: 0x30,
                                             modifiers: [.maskCommand, .maskAlternate])
                    settings.shortcuts.append(new)
                    selectedShortcutID = new.id
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)

                Button {
                    deleteSelectedShortcut()
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(!canDeleteSelected)

                Spacer()
            }
            .padding(6)
        }
    }

    private var shortcutList: some View {
        List(selection: $selectedShortcutID) {
            ForEach(settings.shortcuts) { shortcut in
                HStack {
                    Text(shortcut.name).lineLimit(1)
                    if shortcut.isDefault {
                        Text("默认")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(shortcut.displayString)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .tag(shortcut.id)
            }
        }
    }

    private var canDeleteSelected: Bool {
        guard let id = selectedShortcutID,
              let shortcut = settings.shortcuts.first(where: { $0.id == id }) else { return false }
        return !shortcut.isDefault
    }

    private func deleteSelectedShortcut() {
        guard let id = selectedShortcutID,
              let index = settings.shortcuts.firstIndex(where: { $0.id == id }),
              !settings.shortcuts[index].isDefault else { return }
        settings.shortcuts.remove(at: index)
        let newIndex = min(index, settings.shortcuts.count - 1)
        selectedShortcutID = settings.shortcuts.indices.contains(newIndex)
            ? settings.shortcuts[newIndex].id
            : settings.shortcuts.first?.id
    }

    @ViewBuilder
    private var shortcutDetail: some View {
        if let index = settings.shortcuts.firstIndex(where: { $0.id == selectedShortcutID }) {
            ShortcutDetailView(shortcut: Binding(
                get: { settings.shortcuts[index] },
                set: { settings.shortcuts[index] = $0 }
            ))
        } else {
            ContentUnavailableView("未选择快捷键",
                                   systemImage: "keyboard",
                                   description: Text("从左侧选择一个快捷键进行编辑"))
        }
    }

    private func selectFirstShortcutIfNeeded() {
        if selectedShortcutID == nil, let first = settings.shortcuts.first {
            selectedShortcutID = first.id
        }
    }
}

/// The right-hand detail editor for a single shortcut.
struct ShortcutDetailView: View {
    @Binding var shortcut: ShortcutConfig

    var body: some View {
        Form {
            Section("基本信息") {
                if shortcut.isDefault {
                    HStack {
                        Text("名称")
                        Spacer()
                        Text(shortcut.name)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    TextField("名称", text: $shortcut.name)
                }
                HStack {
                    Text("快捷键")
                    Spacer()
                    KeyRecorderView(keyCode: $shortcut.keyCode,
                                    modifiers: Binding(
                                        get: { shortcut.modifiers },
                                        set: { shortcut.modifiersRaw = $0.rawValue }
                                    ))
                }
            }
            
            Section("预览图大小") {
                Picker("大小", selection: $shortcut.previewSize) {
                    ForEach(AppSettings.PreviewSize.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("此快捷键切换窗口时的缩略图大小。当前：\(shortcut.previewSize.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("显示窗口") {
                Toggle("显示最小化窗口", isOn: $shortcut.showMinimized)
                Toggle("显示隐藏窗口", isOn: $shortcut.showHidden)
                Toggle("显示没有打开窗口的应用", isOn: $shortcut.showEmptyApps)
            }

           

            Section("释放行为") {
                Picker("快捷键释放后", selection: $shortcut.releaseBehavior) {
                    ForEach(ShortcutConfig.ReleaseBehavior.allCases) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }
                .pickerStyle(.radioGroup)
            }
        }
        .formStyle(.grouped)
    }
}

private extension View {
    /// Applies a system cursor over the view's frame. Used for the split divider.
    @ViewBuilder
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { hovering in
            if hovering {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
