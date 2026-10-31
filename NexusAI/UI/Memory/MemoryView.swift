import SwiftUI
import UniformTypeIdentifiers

struct MemoryView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var memory: MemoryStore
    @ObservedObject var settings: SettingsStore
    /// When embedded in Workspace (which already provides a NavigationStack).
    var embedded = false
    @State private var segment = 0
    @State private var query = ""
    @State private var editing: MemoryItem?
    @State private var adding = false
    @State private var newProject = false
    @State private var exportURL: URL?
    @State private var importing = false
    @State private var message: String?
    @State private var confirmWipe = false

    var body: some View {
        if embedded { content } else { NavigationStack { content } }
    }

    private var content: some View {
            VStack(spacing: 0) {
                Picker("", selection: $segment) {
                    Text("Memories").tag(0)
                    Text("Projects").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()
                if segment == 0 { memoriesList } else { projectsList }
            }
            .navigationTitle(embedded ? "Workspace" : "Memory")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { if segment == 0 { adding = true } else { newProject = true } } label: {
                            Label(segment == 0 ? "Add memory" : "New project", systemImage: "plus")
                        }
                        Button { export() } label: { Label("Export backup…", systemImage: "square.and.arrow.up") }
                        Button { importing = true } label: { Label("Import backup…", systemImage: "square.and.arrow.down") }
                        Button(role: .destructive) { confirmWipe = true } label: { Label("Delete all memories", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(item: $editing) { item in MemoryEditor(memory: memory, item: item) }
            .sheet(isPresented: $adding) {
                MemoryEditor(memory: memory, item: MemoryItem(kind: .fact, content: ""))
            }
            .sheet(isPresented: $newProject) { ProjectEditor(memory: memory, project: Project(name: "")) }
            .sheet(item: Binding(get: { exportURL.map { ShareItem(url: $0) } }, set: { exportURL = $0?.url })) { item in
                ShareSheet(items: [item.url])
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                guard case .success(let url) = result else { return }
                do {
                    let r = try memory.importBackup(from: url)
                    for c in r.conversations { app.conversations.save(c) }
                    message = "Imported \(r.memories) memories, \(r.projects) projects and \(r.conversations.count) conversations."
                } catch { message = error.localizedDescription }
            }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK") {} }
            .confirmationDialog("Delete all memories?", isPresented: $confirmWipe, titleVisibility: .visible) {
                Button("Delete all", role: .destructive) { memory.deleteAll() }
            } message: { Text("This permanently removes everything NEXUS remembers. Conversations are kept.") }
    }

    private func export() {
        do { exportURL = try memory.exportBackup(conversations: app.conversations.all()) }
        catch { message = error.localizedDescription }
    }

    private var filtered: [MemoryItem] {
        let q = query.lowercased()
        return memory.active.filter { q.isEmpty || $0.content.lowercased().contains(q) }
    }

    private var memoriesList: some View {
        List {
            Section {
                Toggle("Use memory in conversations", isOn: $settings.useMemory)
                Toggle("Suggest things to remember", isOn: $settings.suggestMemories)
            } footer: {
                Text("NEXUS never saves anything silently. Say “remember that…” to save, or approve suggestions. Memories are encrypted on this device and only used locally unless you send a message to a cloud model.")
            }
            if !memory.suggestions.isEmpty {
                Section("Suggestions awaiting approval") {
                    ForEach(memory.suggestions) { s in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.content)
                                Text(s.kind.label).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { memory.approve(s) } label: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                                .accessibilityLabel("Approve")
                            Button { memory.delete(s) } label: { Image(systemName: "xmark.circle").foregroundStyle(.secondary) }
                                .accessibilityLabel("Reject")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            ForEach(MemoryItem.Kind.allCases, id: \.self) { kind in
                let items = filtered.filter { $0.kind == kind }
                if !items.isEmpty {
                    Section(kind.label + "s") {
                        ForEach(items) { item in
                            Button { editing = item } label: {
                                HStack(alignment: .top) {
                                    Image(systemName: kind.symbol).foregroundStyle(.secondary).frame(width: 22)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.content).foregroundStyle(.primary)
                                        HStack(spacing: 6) {
                                            if item.pinned { Pill(text: "Pinned", symbol: "pin.fill", tint: .orange) }
                                            if let p = memory.project(item.projectID) { Pill(text: p.name, symbol: "folder") }
                                            if item.useCount > 0 { Text("Used \(item.useCount)×").font(.caption2).foregroundStyle(.tertiary) }
                                        }
                                    }
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) { memory.delete(item) } label: { Label("Delete", systemImage: "trash") }
                                Button {
                                    var i = item; i.pinned.toggle(); memory.save(i)
                                } label: { Label(item.pinned ? "Unpin" : "Pin", systemImage: "pin") }.tint(.orange)
                            }
                        }
                    }
                }
            }
            if memory.active.isEmpty {
                EmptyStateView(symbol: "brain", title: "Nothing remembered yet",
                               message: "Try saying “Remember that I prefer metric units.”").listRowBackground(Color.clear)
            }
        }
        .searchable(text: $query, prompt: "Search memories")
    }

    private var projectsList: some View {
        List {
            if memory.projects.isEmpty {
                EmptyStateView(symbol: "folder", title: "No projects",
                               message: "Projects keep their own context, decisions, tasks, documents and conversations.")
                    .listRowBackground(Color.clear)
            }
            ForEach(memory.projects) { p in
                NavigationLink {
                    ProjectDetailView(memory: memory, projectID: p.id)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(p.name).font(.body.weight(.medium))
                        if !p.summary.isEmpty { Text(p.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        Text("\(p.tasks.filter { !$0.done }.count) open tasks · \(p.decisions.count) decisions").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .onDelete { idx in idx.map { memory.projects[$0] }.forEach(memory.deleteProject) }
        }
    }
}

struct ShareItem: Identifiable { var url: URL; var id: String { url.path } }

struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct MemoryEditor: View {
    @ObservedObject var memory: MemoryStore
    @State var item: MemoryItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Memory") {
                    TextField("What should NEXUS remember?", text: $item.content, axis: .vertical).lineLimit(2...8)
                    Picker("Type", selection: $item.kind) {
                        ForEach(MemoryItem.Kind.allCases, id: \.self) { Label($0.label, systemImage: $0.symbol).tag($0) }
                    }
                    Picker("Project", selection: $item.projectID) {
                        Text("All conversations").tag(UUID?.none)
                        ForEach(memory.projects) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    Toggle("Pinned (always included)", isOn: $item.pinned)
                    VStack(alignment: .leading) {
                        Text("Importance").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $item.importance, in: 0...1)
                    }
                }
                Section {
                    StatRow(label: "Created", value: item.created.formatted(date: .abbreviated, time: .shortened), mono: false)
                    StatRow(label: "Source", value: item.source, mono: false)
                }
            }
            .navigationTitle("Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var i = item
                        i.status = .active
                        memory.save(i)
                        dismiss()
                    }
                    .disabled(item.content.trimmed.isEmpty)
                }
            }
        }
    }
}

struct ProjectEditor: View {
    @ObservedObject var memory: MemoryStore
    @State var project: Project
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Project name", text: $project.name)
                TextField("Summary", text: $project.summary, axis: .vertical).lineLimit(2...6)
            }
            .navigationTitle("New project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { memory.saveProject(project); dismiss() }.disabled(project.name.trimmed.isEmpty)
                }
            }
        }
    }
}

struct ProjectDetailView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var memory: MemoryStore
    let projectID: UUID
    @State private var newTask = ""
    @State private var newDecision = ""

    private var project: Project? { memory.project(projectID) }

    var body: some View {
        if let p = project {
            List {
                Section("Summary") {
                    TextField("What is this project about?", text: binding(\.summary), axis: .vertical).lineLimit(2...8)
                }
                Section("Outstanding tasks") {
                    ForEach(p.tasks) { t in
                        Button {
                            update { proj in if let i = proj.tasks.firstIndex(where: { $0.id == t.id }) { proj.tasks[i].done.toggle() } }
                        } label: {
                            Label(t.title, systemImage: t.done ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(t.done ? .secondary : .primary)
                        }
                    }
                    .onDelete { idx in update { $0.tasks.remove(atOffsets: idx) } }
                    HStack {
                        TextField("Add task", text: $newTask).onSubmit(addTask)
                        Button("Add", action: addTask).disabled(newTask.trimmed.isEmpty)
                    }
                }
                Section("Decisions") {
                    ForEach(Array(p.decisions.enumerated()), id: \.offset) { _, d in Text(d) }
                        .onDelete { idx in update { $0.decisions.remove(atOffsets: idx) } }
                    HStack {
                        TextField("Record a decision", text: $newDecision).onSubmit(addDecision)
                        Button("Add", action: addDecision).disabled(newDecision.trimmed.isEmpty)
                    }
                }
                Section("Notes") {
                    TextField("Technical notes, links, context…", text: binding(\.notes), axis: .vertical).lineLimit(3...12)
                }
                Section("Project memory") {
                    let items = memory.active.filter { $0.projectID == projectID }
                    if items.isEmpty { Text("No project-specific memories.").foregroundStyle(.secondary) }
                    ForEach(items) { Text($0.content) }
                }
                Section("Documents") {
                    let docs = app.documents.documents.filter { $0.projectID == projectID }
                    if docs.isEmpty { Text("Attach documents in a project chat or the Documents workspace.").foregroundStyle(.secondary) }
                    ForEach(docs) { Label($0.title, systemImage: "doc.text") }
                }
                Section {
                    Button {
                        app.chat.newConversation(projectID: projectID)
                        app.selectedTab = 0
                    } label: { Label("New chat in this project", systemImage: "bubble.left.and.text.bubble.right") }
                }
            }
            .navigationTitle(p.name)
        } else {
            EmptyStateView(symbol: "folder", title: "Project deleted", message: "")
        }
    }

    private func binding(_ kp: WritableKeyPath<Project, String>) -> Binding<String> {
        Binding(get: { project?[keyPath: kp] ?? "" }, set: { v in update { $0[keyPath: kp] = v } })
    }

    private func update(_ change: (inout Project) -> Void) {
        guard var p = project else { return }
        change(&p)
        memory.saveProject(p)
    }

    private func addTask() {
        let t = newTask.trimmed
        guard !t.isEmpty else { return }
        update { $0.tasks.append(ProjectTask(title: t)) }
        newTask = ""
    }

    private func addDecision() {
        let d = newDecision.trimmed
        guard !d.isEmpty else { return }
        update { $0.decisions.append(d) }
        newDecision = ""
    }
}
