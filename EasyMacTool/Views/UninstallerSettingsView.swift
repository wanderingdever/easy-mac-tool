import AppKit
import SwiftUI
import UniformTypeIdentifiers

private func uninstallByteString(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

@MainActor
private enum UninstallerIconCache {
    static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 500
        return cache
    }()

    static func icon(for url: URL) -> NSImage {
        let key = url.standardizedFileURL.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: key)
        return icon
    }
}

/// 卸载器设置页（Aurora v2）：拖入或选择 .app，查看残留文件并移至废纸篓。
struct UninstallerSettingsView: View {
    @ObservedObject private var uninstaller = AppUninstaller.shared
    @ObservedObject private var appCatalog = InstalledAppsCatalog.shared
    @State private var appQuery = ""
    @State private var showingRemovalConfirmation = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DesignTokens.Aurora.pageBackground)
            .sheet(isPresented: $showingRemovalConfirmation) {
                removalConfirmation
            }
    }

    @ViewBuilder
    private var content: some View {
        switch uninstaller.phase {
        case .empty: emptyState
        case .scanning: busyState("正在扫描残留文件…")
        case .results: resultsState
        case .removing: busyState("正在移动至废纸篓…")
        case let .done(freed, failed): doneState(freed: freed, failed: failed)
        }
    }

    // MARK: Empty / app list

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("已安装应用")
                    .scaledSystemFont(16, weight: .semibold, relativeTo: .headline)
                Text("\(uninstallableApps.count) 个")
                    .scaledSystemFont(12, relativeTo: .caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if appCatalog.isDiscovering || appCatalog.isMeasuringSizes {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text(appCatalog.isDiscovering ? "正在查找应用…" : "正在计算大小…")
                            .scaledSystemFont(11, relativeTo: .caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                Button(action: appCatalog.refresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("刷新应用列表")
                .accessibilityLabel("刷新应用列表")
            }
            TextField("搜索应用…", text: $appQuery)
                .textFieldStyle(.roundedBorder)
                .scaledSystemFont(13)
            appList
            Text("卸载操作会将文件移至废纸篓，可随时恢复。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { appCatalog.loadIfNeeded() }
        .dropDestination(for: URL.self) { urls, _ in
            guard let app = urls.first(where: { $0.pathExtension == "app" }) ?? urls.first else { return false }
            uninstaller.select(appURL: app)
            return true
        } isTargeted: { _ in }
    }

    /// 可卸载的非系统应用：排除本应用自身与符号链接。
    private var uninstallableApps: [InstalledApps.InstalledApp] {
        appCatalog.apps
    }

    private var filteredApps: [InstalledApps.InstalledApp] {
        let trimmed = appQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return uninstallableApps }
        return uninstallableApps.filter { app in
            app.name.localizedCaseInsensitiveContains(trimmed)
                || (app.bundleID?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    @ViewBuilder
    private var appList: some View {
        let shown = filteredApps
        if appCatalog.isDiscovering && appCatalog.apps.isEmpty {
            VStack(spacing: 8) {
                ProgressView()
                Text("正在查找应用…").scaledSystemFont(13).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity)
        } else if shown.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "app.dashed")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
                Text("未找到应用").scaledSystemFont(13).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(shown) { app in
                        UninstallableAppRow(app: app) {
                            uninstaller.select(appURL: app.url)
                        }
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    // MARK: Busy

    private func busyState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView().controlSize(.large)
            Text(message).foregroundStyle(.secondary)
            if let target = uninstaller.target {
                HStack(spacing: 8) {
                    Image(nsImage: target.icon).resizable().frame(width: 18, height: 18)
                    Text(target.name).font(.callout)
                }
            }
            Spacer()
        }
    }

    // MARK: Results

    private var resultsState: some View {
        VStack(spacing: 0) {
            targetHeader
            Rectangle()
                .fill(DesignTokens.Aurora.insetSeparator)
                .frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(AppUninstaller.Category.allCases, id: \.self) { category in
                        let group = uninstaller.items.filter { $0.category == category }
                        if !group.isEmpty {
                            Text(label(for: category))
                                .scaledSystemFont(12, weight: .semibold, relativeTo: .caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 10)
                                .padding(.bottom, 2)
                            ForEach(group) { item in row(item) }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            Rectangle()
                .fill(DesignTokens.Aurora.insetSeparator)
                .frame(height: 1)
            footer
        }
    }

    private var targetHeader: some View {
        HStack(spacing: 12) {
            if let target = uninstaller.target {
                Image(nsImage: target.icon).resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.name).scaledSystemFont(16, weight: .semibold, relativeTo: .headline)
                    Text(target.bundleID ?? target.url.path)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(uninstallByteString(uninstaller.totalSize))
                    .scaledSystemFont(15, weight: .semibold, design: .rounded)
                Text("共发现文件").font(.caption2).foregroundStyle(.secondary)
            }
            Button { uninstaller.reset() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("取消卸载")
        }
        .padding(16)
    }

    private func row(_ item: AppUninstaller.Leftover) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: includeBinding(item))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .accessibilityLabel("移除\(item.name)")
            Image(nsImage: UninstallerIconCache.icon(for: item.url))
                .resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).scaledSystemFont(12.5).lineLimit(1).truncationMode(.middle)
                Text(prettyPath(item.url))
                    .scaledSystemFont(10.5, relativeTo: .caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer()
            Text(uninstallByteString(item.size))
                .scaledSystemFont(11.5, relativeTo: .caption).foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name)，\(prettyPath(item.url))，\(uninstallByteString(item.size))")
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("已选 \(uninstaller.items.filter(\.include).count) / \(uninstaller.items.count) 项")
                    .scaledSystemFont(12, weight: .medium, relativeTo: .caption)
                Text(uninstallByteString(uninstaller.selectedSize))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("取消") { uninstaller.reset() }
            Button("移除") { showingRemovalConfirmation = true }
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.Colors.error)
                .disabled(!uninstaller.items.contains(where: \.include))
        }
        .padding(16)
    }

    // MARK: Done

    private func doneState(freed: Int64, failed: Int) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(.green)
            Text("卸载完成").scaledSystemFont(20, weight: .bold, relativeTo: .title2)
            Text("已释放 \(uninstallByteString(freed))")
                .scaledSystemFont(13).foregroundStyle(.secondary)
            if failed > 0 {
                Text("有 \(failed) 项未能移除，可能被占用或需要管理员权限。")
                    .font(.caption).foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(uninstaller.removalFailures) { failure in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(failure.url.path)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                Text(failure.reason)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
            Button("继续卸载") { uninstaller.reset() }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .padding(.top, 6)
            Spacer()
        }
        .padding(28)
    }

    // MARK: Helpers

    private var removalConfirmation: some View {
        let selected = uninstaller.items.filter(\.include)
        return VStack(alignment: .leading, spacing: 16) {
            Text("确认移至废纸篓")
                .font(.title2.bold())
            Text("将移动 \(selected.count) 项，共 \(uninstallByteString(uninstaller.selectedSize))。应用若正在运行会先收到退出请求。")
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(selected) { item in
                        Text(item.url.path)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 260)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { showingRemovalConfirmation = false }
                Button("移至废纸篓", role: .destructive) {
                    showingRemovalConfirmation = false
                    uninstaller.removeSelected()
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.Colors.error)
            }
        }
        .padding(24)
        .frame(width: 560, height: 420)
    }

    private func includeBinding(_ item: AppUninstaller.Leftover) -> Binding<Bool> {
        Binding(
            get: { uninstaller.items.first(where: { $0.id == item.id })?.include ?? false },
            set: { uninstaller.setInclude($0, for: item.id) }
        )
    }

    private func prettyPath(_ url: URL) -> String {
        url.deletingLastPathComponent().path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func label(for category: AppUninstaller.Category) -> String {
        switch category {
        case .app: return "应用"
        case .support: return "支持文件"
        case .caches: return "缓存"
        case .preferences: return "偏好设置"
        case .containers: return "容器与脚本"
        case .logs: return "日志"
        case .state: return "状态"
        case .other: return "其他"
        }
    }

}

/// 已安装应用行：图标 + 名称/bundleID + 占用存储 + 行尾「卸载」按钮。
private struct UninstallableAppRow: View {
    let app: InstalledApps.InstalledApp
    var onUninstall: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .scaledSystemFont(13, weight: .medium)
                    .lineLimit(1)
                Text(app.bundleID ?? app.url.path)
                    .scaledSystemFont(11, relativeTo: .caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Group {
                if let sizeBytes = app.sizeBytes {
                    Text(uninstallByteString(sizeBytes))
                        .accessibilityLabel("占用存储 \(uninstallByteString(sizeBytes))")
                } else {
                    Text("计算中…")
                        .accessibilityLabel("正在计算应用大小")
                }
            }
            .scaledSystemFont(11.5, relativeTo: .caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .frame(width: 72, alignment: .trailing)
            Button("卸载", action: onUninstall)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(DesignTokens.Colors.error)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

}
