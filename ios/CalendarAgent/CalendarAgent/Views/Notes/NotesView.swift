import SwiftData
import SwiftUI

struct NotesView: View {
  @Environment(\.modelContext) private var modelContext
  @Query(sort: \NoteRecord.createdAt, order: .reverse) private var notes: [NoteRecord]
  @State private var showingEditor = false
  @State private var selectedFocusArea: FocusArea?
  @State private var errorMessage: String?

  private var filteredNotes: [NoteRecord] {
    guard let selectedFocusArea else { return notes }
    return notes.filter { $0.focusArea == selectedFocusArea }
  }

  var body: some View {
    VStack(spacing: 0) {
      focusFilter
      if filteredNotes.isEmpty {
        ContentUnavailableView(
          "No Notes Yet",
          systemImage: "note.text",
          description: Text(
            "Capture a thought here or save an assistant message from \(AppBrand.name)."
          )
        )
      } else {
        List {
          ForEach(filteredNotes) { note in
            NoteRow(note: note)
          }
          .onDelete(perform: delete)
        }
        .scrollContentBackground(.hidden)
      }
    }
    .background(Color.CalendarAgent.background)
    .navigationTitle("Notes")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("New Note", systemImage: "square.and.pencil") {
          showingEditor = true
        }
      }
    }
    .sheet(isPresented: $showingEditor) {
      NoteEditorView { text, focusArea in
        let note = NoteRecord(text: text, focusArea: focusArea)
        modelContext.insert(note)
        do {
          try modelContext.save()
        } catch {
          errorMessage = error.localizedDescription
        }
      }
    }
    .alert(
      "Notes",
      isPresented: Binding(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      )
    ) {
      Button("OK") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "Unknown error")
    }
  }

  private var focusFilter: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        Button("All") { selectedFocusArea = nil }
          .buttonStyle(
            FocusChipStyle(selected: selectedFocusArea == nil)
          )
        ForEach(FocusArea.allCases) { area in
          Button {
            selectedFocusArea = area
          } label: {
            Label(area.title, systemImage: area.icon)
          }
          .buttonStyle(
            FocusChipStyle(selected: selectedFocusArea == area)
          )
        }
      }
      .padding(.horizontal)
      .padding(.vertical, 10)
    }
  }

  private func delete(at offsets: IndexSet) {
    for index in offsets {
      modelContext.delete(filteredNotes[index])
    }
    do {
      try modelContext.save()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

private struct NoteRow: View {
  let note: NoteRecord

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(note.text)
        .font(.body)
        .lineLimit(5)
      HStack {
        if let area = note.focusArea {
          Label(area.title, systemImage: area.icon)
            .foregroundStyle(area.color)
        } else {
          Label("General", systemImage: "circle.grid.2x2")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Text(note.createdAt, format: .dateTime.month().day().hour().minute())
          .foregroundStyle(.secondary)
      }
      .font(.caption)
    }
    .padding(.vertical, 6)
    .listRowBackground(Color.CalendarAgent.surface)
  }
}

private struct FocusChipStyle: ButtonStyle {
  let selected: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.caption.weight(.semibold))
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .foregroundStyle(
        selected ? Color.CalendarAgent.onAccentFill : Color.primary
      )
      .background(
        selected
          ? Color.CalendarAgent.accentFill
          : Color.CalendarAgent.surface
      )
      .clipShape(Capsule())
      .opacity(configuration.isPressed ? 0.7 : 1)
  }
}

private struct NoteEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var text = ""
  @State private var focusArea: FocusArea?
  let onSave: (String, FocusArea?) -> Void

  var body: some View {
    NavigationStack {
      Form {
        Section("Note") {
          TextField("What do you want to remember?", text: $text, axis: .vertical)
            .lineLimit(6...14)
        }
        Section("Focus area") {
          Picker("Area", selection: $focusArea) {
            Text("General").tag(FocusArea?.none)
            ForEach(FocusArea.allCases) { area in
              Text(area.title).tag(FocusArea?.some(area))
            }
          }
        }
      }
      .navigationTitle("New Note")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            onSave(
              text.trimmingCharacters(in: .whitespacesAndNewlines),
              focusArea
            )
            dismiss()
          }
          .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
  }
}
