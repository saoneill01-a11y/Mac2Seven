import AppKit
import SwiftUI

struct SnipSettingsView: View {
    @EnvironmentObject var prefs: Preferences
    @State private var hasPermission = CGPreflightScreenCaptureAccess()

    private var snip: Binding<SnipSettings> { $prefs.data.snip }

    var body: some View {
        Form {
            Section {
                LabeledContent("Take a screenshot with") {
                    HotkeyRecorder(spec: snip.hotkey, isRecording: $prefs.isRecordingHotkey, defaultSpec: .snip)
                }
                Toggle("Show the Snip button on the taskbar", isOn: snip.taskbarButton)
            } footer: {
                Text("You can also start Snip from All Programs in the Start menu, or from the menu bar icon's right-click menu.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("After capture") {
                Toggle("Copy to the clipboard", isOn: snip.copyToClipboard)
                Toggle("Open in Preview", isOn: snip.openInPreview)
                Toggle("Show a thumbnail in the corner", isOn: snip.showThumbnail)
                Toggle("Save to the screenshots folder", isOn: snip.autoSave)
                LabeledContent("Folder") {
                    HStack {
                        Text(displayPath(prefs.data.snip.saveFolder))
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { chooseFolder() }
                        Button("Show") { showFolder() }
                    }
                }
                .disabled(!prefs.data.snip.autoSave)
            }

            Section("Include") {
                Toggle("Mouse pointer", isOn: snip.showPointer)
                Toggle("Window shadow (Window mode)", isOn: snip.windowShadow)
            }

            Section {
                LabeledContent("Screen Recording") {
                    if hasPermission {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Open Settings") {
                            CGRequestScreenCaptureAccess()
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            } header: {
                Text("Permission")
            } footer: {
                Text("Snip uses the same Screen Recording permission as the taskbar's window previews.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { hasPermission = CGPreflightScreenCaptureAccess() }
    }

    private func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.directoryURL = URL(fileURLWithPath: prefs.data.snip.saveFolder)
        if panel.runModal() == .OK, let url = panel.url {
            prefs.data.snip.saveFolder = url.path
        }
    }

    private func showFolder() {
        let url = URL(fileURLWithPath: prefs.data.snip.saveFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}
