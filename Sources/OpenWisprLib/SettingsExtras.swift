import AppKit
import SwiftUI

// MARK: - Snippets

/// Saved notes: a name you say and the text it pastes.
struct SnippetsView: View {
    @ObservedObject var model: SettingsModel
    @State private var selectedID: UUID?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    selectedID = model.addSnippet().id
                } label: {
                    Label("New snippet", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(model.snippets) { snippet in
                            Button { selectedID = snippet.id } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(snippet.name.isEmpty ? "Untitled" : snippet.name)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(snippet.name.isEmpty ? .secondary : .primary)
                                    Text(snippet.text.isEmpty ? "Empty" : snippet.text)
                                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 8)
                                    .fill(snippet.id == current?.id ? Theme.accent.opacity(0.10) : .clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(16)
            .frame(width: 250)
            Divider().opacity(0.5)
            Group {
                if let snippet = current {
                    editor(snippet)
                } else {
                    empty
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 24).padding(.vertical, 18)
        }
    }

    private var current: Snippet? {
        model.snippets.first { $0.id == selectedID } ?? model.snippets.first
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Snippets", subtitle: "Save text you use a lot, then paste it by saying its name.")
            Text("Example: save your YouTube script template as \"YouTube script\". Hit your hotkey, say \"YouTube script\", and the whole template is pasted, exactly as saved.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Make your first snippet") { selectedID = model.addSnippet().id }
                .buttonStyle(GradientButtonStyle())
        }
    }

    private func editor(_ snippet: Snippet) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionTitle(title: "Snippet", subtitle: "Say the name as the whole dictation to paste the text.")
                Spacer()
                Button(role: .destructive) {
                    model.deleteSnippet(snippet.id)
                    selectedID = nil
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("What you say").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                TextField("YouTube script", text: binding(snippet, \.name))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("What gets pasted").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                TextEditor(text: binding(snippet, \.text))
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 260)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke))
            }
            Text("Saved as you type. Pasted word for word: no AI, no swear filter.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func binding(_ snippet: Snippet, _ key: WritableKeyPath<Snippet, String>) -> Binding<String> {
        Binding(
            get: { model.snippets.first { $0.id == snippet.id }?[keyPath: key] ?? "" },
            set: { value in
                guard var s = model.snippets.first(where: { $0.id == snippet.id }) else { return }
                s[keyPath: key] = value
                model.updateSnippet(s)
            }
        )
    }
}

// MARK: - Dictionary

/// Words BrainDump should always hear and spell your way.
struct DictionaryView: View {
    @ObservedObject var model: SettingsModel
    @State private var newWord = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(title: "Dictionary",
                             subtitle: "Names, brands and jargon BrainDump should always spell your way, like JuiceFly or Melo.")
                HStack {
                    TextField("Add a word or name", text: $newWord)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 14))
                        .onSubmit(add)
                    Button("Add", action: add)
                        .buttonStyle(GradientButtonStyle())
                        .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .frame(maxWidth: 480)
                if model.vocabulary.isEmpty {
                    Text("No words yet. Add the ones the speech model keeps getting wrong.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                        ForEach(model.vocabulary, id: \.self) { word in
                            HStack(spacing: 6) {
                                Text(word).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Spacer(minLength: 4)
                                Button { model.removeWord(word) } label: {
                                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("Remove \(word)")
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(Theme.card))
                            .overlay(Capsule().stroke(Theme.stroke))
                        }
                    }
                }
                Text("These also help the speech model hear the word right in the first place.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24).padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func add() {
        model.addWord(newWord)
        newWord = ""
    }
}

// MARK: - Apps

/// Which style each app gets when "Switch style by app" is on.
struct AppStylesView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    SectionTitle(title: "Style by app",
                                 subtitle: "BrainDump picks the style for the app you're talking into. Other apps use the style picked in the menu.")
                    Spacer()
                    Toggle("", isOn: Binding(get: { model.styleByApp }, set: { model.setStyleByApp($0) }))
                        .toggleStyle(.switch).tint(Theme.switchOn).labelsHidden()
                }
                VStack(spacing: 0) {
                    ForEach(rules, id: \.bundleID) { rule in
                        row(rule)
                        Divider().opacity(0.5)
                    }
                    addApp
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke))
                .opacity(model.styleByApp ? 1 : 0.45)
                .disabled(!model.styleByApp)
            }
            .padding(.horizontal, 24).padding(.vertical, 18)
        }
    }

    private var rules: [(bundleID: String, name: String, style: String)] {
        AppStyles.rules(overrides: model.appStyles)
    }

    private func row(_ rule: (bundleID: String, name: String, style: String)) -> some View {
        let builtIn = AppStyles.builtIn.contains { $0.bundleID == rule.bundleID }
        return HStack(spacing: 10) {
            appIcon(rule.bundleID)
            Text(rule.name).font(.system(size: 13, weight: .medium))
            Spacer()
            Picker("", selection: Binding(get: { rule.style }, set: { model.setAppStyle(rule.bundleID, style: $0) })) {
                Text("Menu style").tag(AppStyles.useDefault)
                ForEach(FormatStyle.all) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .fixedSize()
            if !builtIn {
                Button { model.setAppStyle(rule.bundleID, style: nil) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove \(rule.name)")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var addApp: some View {
        let listed = Set(rules.map(\.bundleID))
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier.map { (id: $0, name: app.localizedName ?? $0) } }
            .filter { !listed.contains($0.id) && $0.id != Bundle.main.bundleIdentifier }
            .sorted { $0.name < $1.name }
        return Menu {
            if running.isEmpty { Text("Open the app first, then add it here") }
            ForEach(running, id: \.id) { app in
                Button(app.name) { model.setAppStyle(app.id, style: model.styleID) }
            }
        } label: {
            Label("Add an app", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func appIcon(_ bundleID: String) -> some View {
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
        return Group {
            if let icon {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: 22, height: 22)
    }
}
