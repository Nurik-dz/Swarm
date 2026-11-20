import SwiftUI
import AppKit

/// Choose a nearby Mac to send a file or folder to.
struct SendSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let path: URL

    private var lan: LanService { model.lan }
    private var busy: Bool { if let o = lan.outgoing, !o.state.isFinished { return true } else { return false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path.path)).resizable().frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send \u{201C}\(path.lastPathComponent)\u{201D}").font(.title3.weight(.semibold)).lineLimit(2).truncationMode(.middle)
                    Text("to a Mac on this network").foregroundStyle(.secondary)
                }
            }
            if let o = lan.outgoing {
                progress(o)
            } else {
                devices
            }
            HStack {
                Spacer()
                if let o = lan.outgoing, o.state.isFinished {
                    Button(o.state == .accepted ? "Done" : "Try Again") {
                        if o.state == .accepted { lan.dismissOutgoing(); dismiss() } else { lan.dismissOutgoing() }
                    }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    if o.state != .accepted { Button("Close") { lan.dismissOutgoing(); dismiss() } }
                } else {
                    Button("Cancel", role: .cancel) { lan.cancelSending(); dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 480)
        .onAppear { lan.startBrowsing() }
        .onDisappear { lan.stopBrowsing(); if busy { lan.cancelSending() } }
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: 10) {
            if lan.devices.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Looking for Macs running Swarm\u{2026}").foregroundStyle(.secondary)
                }
                Text("On the other Mac open Swarm \u{2192} Settings \u{2192} Network and turn on \u{201C}Receive files from nearby Macs\u{201D}. Both Macs need to be on the same network.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(lan.devices) { d in
                    Button {
                        lan.send(path, to: d)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "laptopcomputer").font(.system(size: 22)).frame(width: 30)
                            Text(d.name).font(.body.weight(.medium))
                            Spacer()
                            Image(systemName: "paperplane.fill").foregroundStyle(Color.accentColor)
                        }
                        .padding(12).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))
                }
            }
        }
    }

    @ViewBuilder
    private func progress(_ o: LanService.Outgoing) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            switch o.state {
            case .preparing(let p):
                ProgressView(value: p).progressViewStyle(.linear)
                Text("Getting \u{201C}\(path.lastPathComponent)\u{201D} ready\u{2026} \(Int(p * 100))%").font(.callout).foregroundStyle(.secondary).monospacedDigit()
            case .asking:
                ProgressView().progressViewStyle(.linear)
                Text("Waiting for \(o.deviceName) to accept\u{2026}").font(.callout)
                codeCard(o.code)
            case .accepted:
                Label("\(o.deviceName) accepted. The files are on their way.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text("It appears in your list while it sends. Keep Swarm open until it finishes; if the connection drops it carries on from where it stopped.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .declined(let why):
                Label("\(o.deviceName) said no (\(why)).", systemImage: "xmark.circle.fill").foregroundStyle(.orange)
            case .failed(let why):
                Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func codeCard(_ code: String) -> some View {
        VStack(spacing: 4) {
            Text(code).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit().tracking(6)
            Text("The other Mac should show the same four digits.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))
    }
}

/// Another Mac wants to send something: nothing happens until the person says yes.
struct IncomingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let incoming: LanService.Incoming
    @State private var folder = Prefs.folder

    private var o: LanProtocol.Checked { incoming.offer }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "laptopcomputer.and.arrow.down")
                    .font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.accentColor.gradient))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(o.sender) wants to send you files").font(.title3.weight(.semibold)).lineLimit(2)
                    Text("Only accept if you just started this on your other Mac.").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(o.name).font(.headline).lineLimit(2).truncationMode(.middle)
                Text("\(o.files == 1 ? "1 file" : "\(o.files.formatted()) files"), \(Format.bytes(o.size))").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))
            VStack(spacing: 4) {
                Text(o.code).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit().tracking(6)
                Text("Does the other Mac show these four digits?").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path)).resizable().frame(width: 18, height: 18)
                Text("Save to \(folder.lastPathComponent)").font(.callout)
                Button("Change\u{2026}") { pick() }
                Spacer()
            }
            HStack {
                Spacer()
                Button("Decline") { model.lan.declineIncoming(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Accept") { model.lan.acceptIncoming(into: folder); dismiss() }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 480)
        .interactiveDismissDisabled()
        .onDisappear { if model.lan.incoming?.id == incoming.id { model.lan.declineIncoming() } }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = folder; panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
