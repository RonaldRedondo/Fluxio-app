import SwiftUI

/// Ventana «Metadatos»: ver, buscar, cambiar o quitar los campos; «Quitar todo» los borra de una vez.
@MainActor
final class MetadataModel: ObservableObject {
    let file: FileInfo
    let kind: MetadataKind
    let groups: [MetadataGroup]
    @Published var search = ""
    @Published var edits = MetadataEdits()
    /// Texto de cada campo editable mientras lo escribes.
    @Published var drafts: [String: String] = [:]

    init(file: FileInfo) {
        self.file = file
        kind = MetadataKind.of(file) ?? .image
        groups = MetadataReader.read(file)
        for group in groups { for field in group.fields where field.editable { drafts[field.id] = field.value } }
    }

    var hasChanges: Bool { !collected.isEmpty }

    /// Solo los textos que de verdad cambiaron.
    var collected: MetadataEdits {
        var out = edits
        for group in groups {
            for field in group.fields where field.editable && !edits.removed.contains(field.id) {
                if let text = drafts[field.id], text != field.value { out.changes[field.id] = text }
            }
        }
        return out
    }

    var visibleGroups: [MetadataGroup] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return groups.compactMap { group in
            var g = group
            g.fields = group.fields.filter { field in
                !edits.removed.contains(field.id) && (query.isEmpty || field.label.lowercased().contains(query)
                    || field.key.lowercased().contains(query) || (drafts[field.id] ?? field.value).lowercased().contains(query))
            }
            return g.fields.isEmpty ? nil : g
        }
    }

    func remove(_ field: MetadataField) {
        withAnimation(DesignTokens.Motion.toast) { _ = edits.removed.insert(field.id) }
    }

    func removeAll() {
        withAnimation(DesignTokens.Motion.toast) { edits.removeAll = true }
    }

    func undoRemoveAll() {
        withAnimation(DesignTokens.Motion.toast) { edits = MetadataEdits() }
    }

    func binding(_ id: String) -> Binding<String> {
        Binding(get: { [weak self] in self?.drafts[id] ?? "" }, set: { [weak self] in self?.drafts[id] = $0 })
    }

    /// Aviso del pie según el tipo de archivo.
    var note: String {
        switch kind {
        case .image: return "«Quitar todo» borra también la cámara y la ubicación. La foto no pierde calidad."
        case .pdf: return "Se guarda una copia del PDF; el contenido no cambia."
        case .media: return "Se guarda una copia sin perder calidad. Necesita FFmpeg."
        }
    }
}

struct MetadataEditorView: View {
    @ObservedObject var model: MetadataModel
    var title = "Metadatos"
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private typealias ME = DesignTokens.MetadataEditor

    var body: some View {
        ToolWindowView(title: title, onClose: onCancel) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
                HStack(spacing: DesignTokens.Spacing.m) {
                    Text(model.file.url.lastPathComponent)
                        .textStyle(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        Image(systemName: "magnifyingglass").foregroundStyle(DesignTokens.Colors.textSecondary)
                        TextField("Buscar metadatos", text: $model.search)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, DesignTokens.Spacing.s)
                    .frame(width: ME.searchWidth, height: ME.fieldHeight)
                    .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.input, style: .continuous)
                        .fill(DesignTokens.Colors.recessed))
                    .disabled(model.edits.removeAll)
                }

                if model.edits.removeAll {
                    removedAllNotice
                } else if model.visibleGroups.isEmpty {
                    Text(model.groups.isEmpty ? "Este archivo no lleva metadatos." : "Nada coincide con la búsqueda.")
                        .textStyle(DesignTokens.Typography.body)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
                            ForEach(model.visibleGroups) { group in groupView(group) }
                        }
                        .padding(.trailing, DesignTokens.Spacing.s)
                    }
                }
            }
            .frame(width: ME.contentWidth, height: ME.contentHeight)
        } footer: {
            Text(model.note)
                .textStyle(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .lineLimit(2)
                .frame(maxWidth: ME.noteWidth, alignment: .leading)
            Spacer()
            if model.edits.removeAll {
                Button("Deshacer", action: model.undoRemoveAll).buttonStyle(.fluxioSecondary)
            } else {
                Button { model.removeAll() } label: { Label("Quitar todo", systemImage: "trash") }
                    .buttonStyle(.fluxioSecondary)
                    .disabled(model.groups.isEmpty)
            }
            Button("Guardar copia", action: onConfirm)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.fluxioPrimary)
                .disabled(!model.hasChanges)
        }
    }

    private var removedAllNotice: some View {
        VStack(spacing: DesignTokens.Spacing.s) {
            Image(systemName: "tag.slash").font(.system(size: 28, weight: .medium))
                .foregroundStyle(DesignTokens.Colors.accentGradient)
            Text("Se quitarán todos los metadatos").textStyle(DesignTokens.Typography.headline)
            Text("Pulsa «Guardar copia» para crearla, o «Deshacer».")
                .textStyle(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.blurScale)
    }

    private func groupView(_ group: MetadataGroup) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
            Text(group.title)
                .textStyle(DesignTokens.Typography.eyebrow)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(group.fields) { field in row(field) }
            Rectangle().fill(DesignTokens.Colors.border).frame(height: DesignTokens.Stroke.hairline)
        }
    }

    private func row(_ field: MetadataField) -> some View {
        let changed = field.editable && model.drafts[field.id] != field.value
        return HStack(spacing: DesignTokens.Spacing.m) {
            Text(field.label + ":")
                .textStyle(DesignTokens.Typography.label)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .lineLimit(1)
                .frame(width: ME.labelWidth, alignment: .trailing)
            if field.editable {
                TextField(field.label, text: model.binding(field.id))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, DesignTokens.Spacing.s)
                    .frame(height: ME.fieldHeight)
                    .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.input, style: .continuous)
                        .fill(DesignTokens.Colors.recessed))
                    .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.input, style: .continuous)
                        .strokeBorder(DesignTokens.Colors.accent.opacity(changed ? 0.8 : 0), lineWidth: DesignTokens.Stroke.hairline))
                    .accessibilityLabel(field.label)
            } else {
                Text(field.value)
                    .textStyle(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { model.remove(field) } label: {
                Image(systemName: "minus.circle").font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .foregroundStyle(DesignTokens.Colors.textSecondary)
            .opacity(field.group == "info" || field.group == "general" ? 0 : 1)
            .disabled(field.group == "info" || field.group == "general")
            .help("Quitar este dato")
            .accessibilityLabel("Quitar \(field.label)")
        }
        .transition(.blurScale)
    }
}
