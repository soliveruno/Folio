import SwiftUI

/// Paste a link → yt-dlp downloads the audio into the music library.
struct DownloadView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationView {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Image(systemName: "link")
                                .foregroundStyle(.secondary)
                            TextField("Paste a YouTube, SoundCloud or Bandcamp link", text: $link)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                                .submitLabel(.go)
                                .focused($fieldFocused)
                                .onSubmit(start)
                            if !link.isEmpty {
                                Button { link = "" } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(12)
                        .background(Palette.surfaceHigh, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        HStack(spacing: 10) {
                            Button {
                                if let s = UIPasteboard.general.string ?? UIPasteboard.general.url?.absoluteString {
                                    link = s.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            } label: {
                                Label("Paste", systemImage: "doc.on.clipboard")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 11)
                                    .background(Palette.surfaceHigh, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)

                            Button(action: start) {
                                Label("Download", systemImage: "arrow.down.circle.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 11)
                                    .background(Palette.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .foregroundColor(.black)
                            }
                            .buttonStyle(.plain)
                            .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                            .opacity(link.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                    .listRowBackground(Color.clear)
                } footer: {
                    Text("Audio is saved as M4A with title, artist and cover art, straight into Music. Playlists download every track. Only download things you have the right to.")
                }

                if !downloads.jobs.isEmpty {
                    Section {
                        ForEach(downloads.jobs) { job in
                            DownloadRow(job: job)
                                .swipeActions {
                                    if job.status.isActive {
                                        Button(role: .destructive) { downloads.cancel(job) } label: {
                                            Label("Cancel", systemImage: "xmark")
                                        }
                                    } else {
                                        Button(role: .destructive) { downloads.remove(job) } label: {
                                            Label("Remove", systemImage: "trash")
                                        }
                                    }
                                }
                        }
                    } header: {
                        HStack {
                            Text("Downloads")
                            Spacer()
                            if downloads.jobs.contains(where: { !$0.status.isActive }) {
                                Button("Clear") { downloads.clearFinished() }
                                    .font(.caption.weight(.semibold))
                            }
                        }
                    }
                }

                Section {
                    HStack {
                        Label("yt-dlp", systemImage: "shippingbox")
                        Spacer()
                        if let v = downloads.engineVersion {
                            Text(v).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        } else if downloads.engineError != nil {
                            Text("Unavailable").foregroundStyle(.red)
                        } else {
                            ProgressView()
                        }
                    }
                    Button {
                        downloads.updateEngine()
                    } label: {
                        HStack {
                            Label("Update yt-dlp", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if downloads.isUpdating { ProgressView() }
                        }
                    }
                    .disabled(downloads.isUpdating)
                    if let m = downloads.updateMessage {
                        Text(m).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let e = downloads.engineError {
                        Text(e).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("Engine")
                } footer: {
                    Text("Sites change often. If downloads start failing, update yt-dlp here without reinstalling Folio.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Download Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.font(.body.weight(.semibold))
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Button(role: .destructive) { downloads.resetEngine() } label: {
                            Label("Use built-in yt-dlp", systemImage: "arrow.uturn.backward")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .onAppear { downloads.prepareEngine() }
        }
        .navigationViewStyle(.stack)
        .tint(Palette.accent)
        .preferredColorScheme(.dark)
    }

    private func start() {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        downloads.enqueue(text)
        link = ""
        fieldFocused = false
    }
}

struct DownloadRow: View {
    @EnvironmentObject private var downloads: DownloadManager
    let job: DownloadManager.Job

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 6) {
                Text(job.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if job.status == .running || job.status == .processing {
                    if job.progress >= 0 {
                        ProgressView(value: job.progress)
                    } else {
                        ProgressView(value: 0.0).opacity(0.25)
                            .overlay(IndeterminateBar())
                    }
                }
                Text(job.message)
                    .font(.caption)
                    .foregroundStyle(isFailure ? Color.red : Color.secondary)
                    .lineLimit(3)
                if case .failed = job.status {
                    Button("Try again") { downloads.retry(job) }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderless)
                }
            }
            Spacer(minLength: 0)
            if job.status.isActive {
                Button { downloads.cancel(job) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    private var isFailure: Bool {
        if case .failed = job.status { return true }
        return false
    }

    @ViewBuilder private var statusIcon: some View {
        switch job.status {
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .running, .processing:
            ProgressView()
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent).font(.title3)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        }
    }
}

/// Small sliding bar for "working, size unknown".
struct IndeterminateBar: View {
    @State private var phase: CGFloat = -0.4

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(Palette.accent)
                .frame(width: geo.size.width * 0.35, height: 4)
                .offset(x: geo.size.width * phase)
                .onAppear {
                    withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { phase = 1.05 }
                }
        }
        .frame(height: 4)
        .clipped()
    }
}
