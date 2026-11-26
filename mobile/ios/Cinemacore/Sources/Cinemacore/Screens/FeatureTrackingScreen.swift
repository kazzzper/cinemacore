import SwiftUI
import UIKit
import CinemacoreCore

/// Which features exist, whether they are on, and what they have actually done.
///
/// The whole report is local: it exists so a dead feature is visible without a
/// third-party SDK, and the copy button is the only way it leaves the device —
/// deliberately, by hand.
struct FeatureTrackingScreen: View {
    let app: AppModel

    @State private var snapshot: FeatureSnapshot?
    @State private var report = ""
    @State private var copied = false
    @State private var confirmsReset = false
    @Environment(\.theme) private var theme

    private var tracker: FeatureTracker { app.features }

    var body: some View {
        ZStack {
            theme.background.color.ignoresSafeArea()

            if let snapshot {
                list(snapshot)
            } else {
                LoadingView(message: "Reading feature usage")
            }
        }
        .navigationTitle("Feature tracking")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarItems }
        .confirmationDialog(
            "Reset feature tracking?",
            isPresented: $confirmsReset,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                Task {
                    await tracker.reset()
                    await reload()
                }
            }
        } message: {
            Text("Usage counts and every enabled/disabled override are cleared. This cannot be undone.")
        }
        .task { await reload() }
    }

    private func list(_ snapshot: FeatureSnapshot) -> some View {
        List {
            Section {
                LabeledContent("Enabled") {
                    Text("\(snapshot.enabledCount) of \(snapshot.entries.count)")
                        .foregroundStyle(theme.textSecondary.color)
                }
                LabeledContent("Never used") {
                    Text("\(snapshot.unusedCount)")
                        .foregroundStyle(theme.textSecondary.color)
                }
            } footer: {
                Text("Recorded on this device only. Nothing is uploaded, and no titles or identifiers are stored.")
            }

            ForEach(Feature.Category.allCases, id: \.self) { category in
                let rows = snapshot.entries.filter { $0.feature.category == category }
                if !rows.isEmpty {
                    Section(category.displayName) {
                        ForEach(rows) { entry in
                            row(entry)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func row(_ entry: FeatureSnapshot.Entry) -> some View {
        VStack(alignment: .leading, spacing: Layout.spacing1) {
            Toggle(isOn: enabledBinding(entry)) {
                Text(entry.feature.displayName)
                    .font(Typography.rowTitle)
                    .foregroundStyle(theme.textPrimary.color)
            }
            .tint(theme.brand.color)

            HStack(spacing: Layout.spacing2) {
                Text("\(entry.usage.useCount) uses")
                if entry.usage.failureCount > 0 {
                    Text("· \(entry.usage.failureCount) failed")
                        .foregroundStyle(theme.brand.color)
                }
                Spacer(minLength: 0)
                Text(lastUsedText(entry.usage))
            }
            .font(Typography.metadata)
            .foregroundStyle(theme.textSecondary.color)
            // Not combined with the toggle: merging them would take the switch
            // out of VoiceOver's reach, and this row's whole job is to be
            // toggleable.
            .accessibilityElement(children: .combine)
        }
        .padding(.vertical, Layout.spacing1)
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    UIPasteboard.general.string = report
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy report", systemImage: "doc.on.doc")
                }
                ShareLink(item: report) {
                    Label("Share report", systemImage: "square.and.arrow.up")
                }
                Divider()
                Button("Reset", role: .destructive) { confirmsReset = true }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: Layout.minimumTarget, height: Layout.minimumTarget)
            }
            .accessibilityLabel("Report actions")
        }
    }

    /// Every toggle writes through the tracker and re-reads the snapshot, so the
    /// row cannot show a state the store did not accept.
    private func enabledBinding(_ entry: FeatureSnapshot.Entry) -> Binding<Bool> {
        Binding(
            get: { entry.isEnabled },
            set: { enabled in
                Task {
                    await tracker.setEnabled(entry.feature, enabled)
                    // The shell reads the same flags; refresh it so the tab or
                    // entry point belonging to this feature appears or goes
                    // without waiting for a relaunch.
                    await app.reloadEnabledFeatures()
                    await reload()
                }
            }
        )
    }

    private func lastUsedText(_ usage: FeatureUsage) -> String {
        guard let last = usage.lastUsed else { return "Never used" }
        return "Last used \(last.formatted(date: .abbreviated, time: .shortened))"
    }

    private func reload() async {
        snapshot = await tracker.snapshot()
        // Flushed first so the shared text is what is actually on disk.
        await tracker.flush()
        report = await tracker.report().text()
        copied = false
    }
}
