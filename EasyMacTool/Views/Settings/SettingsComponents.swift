import SwiftUI

/// Shared Aurora settings primitives. Feature-specific side effects remain in
/// each page's bindings; these views own presentation only.
struct SettingsSectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            AuroraIconChip(systemName: systemImage, size: 26)
            Text(title)
                .scaledSystemFont(DesignTokens.SettingsTypography.subHeader, weight: .semibold)
                .foregroundStyle(.primary)
        }
    }
}

struct SettingsCard<Content: View>: View {
    private let spacing: CGFloat
    private let contentInsets: EdgeInsets
    private let content: Content

    init(
        spacing: CGFloat = 12,
        contentInsets: EdgeInsets = EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14),
        @ViewBuilder content: () -> Content
    ) {
        self.spacing = spacing
        self.contentInsets = contentInsets
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(contentInsets)
        .frame(maxWidth: .infinity, alignment: .leading)
        .auroraSettingsCard()
    }
}

struct SettingsToggleRow: View {
    let title: String
    let description: String?
    @Binding var isOn: Bool

    init(title: String, description: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.description = description
        _isOn = isOn
    }

    var body: some View {
        HStack(alignment: description == nil ? .center : .top,
               spacing: DesignTokens.Settings.formRowGap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .scaledSystemFont(DesignTokens.SettingsTypography.toggleTitle, weight: .medium)
                    .foregroundStyle(.primary)
                if let description {
                    Text(description)
                        .scaledSystemFont(DesignTokens.SettingsTypography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .accessibilityLabel(title)
                .accessibilityHint(description ?? "")
                .toggleStyle(.switch)
                .tint(DesignTokens.Aurora.controlOn)
                .controlSize(.small)
                .padding(.top, description == nil ? 0 : 2)
        }
    }
}

struct SettingsRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(DesignTokens.Aurora.insetSeparator)
            .frame(height: 1)
    }
}
