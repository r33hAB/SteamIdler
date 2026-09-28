// The main window (game list, controls, status line) and the Add AppID sheet.
//
// No @State anywhere: in the macOS 27 SDK it is a macro whose plugin ships with
// Xcode but not with the Command Line Tools, and build.sh must work with those
// alone. The little view state there is lives in AddGameForm instead.
import SwiftUI

/// The Add AppID sheet's fields, owned by the app delegate.
final class AddGameForm: ObservableObject {
    @Published var isPresented = false
    @Published var appIdText = ""
    @Published var name = ""
    @Published var error: String?

    func open() {
        appIdText = ""
        name = ""
        error = nil
        isPresented = true
    }
}

struct ContentView: View {
    @ObservedObject var idler: Idler
    @ObservedObject var addForm: AddGameForm

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            table
            controls
            Divider()
            Text(idler.statusLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(12)
        .frame(minWidth: 620, minHeight: 400)
        .sheet(isPresented: $addForm.isPresented) { AddGameSheet(idler: idler, form: addForm) }
        .alert(idler.notice?.title ?? "",
               isPresented: Binding(get: { idler.notice != nil }, set: { if !$0 { idler.notice = nil } }),
               presenting: idler.notice) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(idler.steamRunning ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            if idler.steamRunning {
                Text("Steam is running.")
                Text("Library: " + (idler.steamPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "not found"))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Steam is not running. Start Steam and sign in before idling.")
                    .foregroundStyle(.red)
            }
        }
    }

    private var table: some View {
        Table(idler.rows, selection: $idler.selection) {
            TableColumn("") { row in
                Toggle("", isOn: Binding(get: { row.checked }, set: { idler.setChecked(row.id, $0) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }
            .width(20)

            TableColumn("Game") { row in
                // Games added by AppID (not installed) are tinted, as on Windows.
                Text(row.name).foregroundStyle(row.installed ? Color.primary : Color.indigo)
            }
            .width(min: 140, ideal: 220)

            TableColumn("AppID") { row in
                Text(String(row.id)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(70)

            TableColumn("Status") { row in
                Text(row.status).foregroundStyle(color(for: row.tone))
            }
            .width(min: 100, ideal: 130)

            TableColumn("Session") { row in
                Text(row.session).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(80)

            TableColumn("Tracked total") { row in
                Text(row.total).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(100)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Start idling") { idler.startChecked() }
                    .disabled(!idler.rows.contains(where: \.checked))
                Button("Stop all") { idler.stopAll() }
                    .disabled(idler.runningCount == 0)
                Button("Add AppID...") { addForm.open() }
                Button("Remove") { idler.removeSelected() }
                    .disabled(!idler.canRemoveSelection)
                Button("Refresh") { idler.refreshGames() }
            }

            HStack(spacing: 6) {
                Toggle("Stop automatically after", isOn: $idler.autoStopEnabled)
                TextField("", value: $idler.autoStopHours, format: .number.precision(.fractionLength(0...1)))
                    .frame(width: 50)
                    .multilineTextAlignment(.trailing)
                Stepper("", value: $idler.autoStopHours, in: 0.1...1000, step: 0.5)
                    .labelsHidden()
                Text("hours per game")
            }
        }
    }

    private func color(for tone: GameRow.Tone) -> Color {
        switch tone {
        case .normal: return .primary
        case .active: return .green
        case .failed: return .red
        }
    }
}

/// Dialog for adding an owned-but-not-installed game by AppID.
struct AddGameSheet: View {
    @ObservedObject var idler: Idler
    @ObservedObject var form: AddGameForm

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add game by AppID").font(.headline)
            Text("You can idle any game your account owns, installed or not, including games "
                 + "with no Mac version. The AppID is the number in the store URL: "
                 + "store.steampowered.com/app/440/ is 440. Pasting the whole URL works too.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("AppID:", text: $form.appIdText)
                TextField("Name:", text: $form.name, prompt: Text("optional"))
            }

            if let error = form.error {
                Text(error).font(.callout).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { form.isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func add() {
        guard let id = Self.parseAppId(form.appIdText) else {
            form.error = "Enter a numeric AppID, or paste the game's store URL."
            return
        }
        if let message = idler.addCustom(appId: id, name: form.name.trimmingCharacters(in: .whitespaces)) {
            form.error = message
            return
        }
        form.isPresented = false
    }

    /// Accepts "440" or any URL containing "/app/440".
    static func parseAppId(_ text: String) -> UInt32? {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = candidate.range(of: "/app/") {
            candidate = String(candidate[range.upperBound...].prefix(while: \.isNumber))
        }
        guard let id = UInt32(candidate), id != 0 else { return nil }
        return id
    }
}
