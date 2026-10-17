import SwiftUI

struct AnswerSettingsConfiguration: View {
    let model: ChatGPTModel?
    let showSystemPrompt: () -> Void
    let save: (AnswerSettings) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AnswerSettings

    init(
        settings: AnswerSettings, model: ChatGPTModel?,
        showSystemPrompt: @escaping () -> Void,
        save: @escaping (AnswerSettings) -> Void
    ) {
        self.model = model
        self.showSystemPrompt = showSystemPrompt
        self.save = save
        _draft = State(initialValue: settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            Text("Answer settings").font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: SettingsLayout.spacing) {
                Picker("Answer verbosity", selection: $draft.verbosity) {
                    ForEach(AnswerVerbosity.allCases, id: \.self) {
                        Text($0.label).tag($0)
                    }
                }
                .disabled(model?.supportsVerbosity != true)
                if model?.supportsVerbosity != true {
                    Text(
                        model == nil
                            ? "Select a model to check verbosity support."
                            : "This model does not support verbosity. Your choice is kept for supported models."
                    ).font(.callout).foregroundStyle(Color(nsColor: SettingsColors.secondaryText))
                        .fixedSize(horizontal: false, vertical: true)
                }
                LabeledContent("Preferred coding language") {
                    TextField("e.g. Java or Python 3.12", text: $draft.codingLanguage)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Preferred coding language")
                }
                Text("Used when the task leaves the coding language open.")
                    .font(.callout).foregroundStyle(Color(nsColor: SettingsColors.secondaryText))
                    .fixedSize(horizontal: false, vertical: true)
                editor("Interview context", text: $draft.interviewContext)
                editor("Custom instructions", text: $draft.customInstructions)
            }
            Text(
                "Saved on this Mac and sent to OpenAI with each answer request. Changes apply to the next request. Conflicting instructions may reduce answer quality."
            ).font(.callout).foregroundStyle(Color(nsColor: SettingsColors.secondaryText))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: SettingsLayout.spacing) {
                Button("Show system prompt", action: showSystemPrompt)
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    save(draft)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(SettingsLayout.windowPadding).frame(width: SettingsLayout.sheetWidth)
    }

    private func editor(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: SettingsLayout.compactSpacing) {
            Text(title)
            TextEditor(text: text)
                .font(.body).scrollContentBackground(.hidden)
                .padding(SettingsLayout.textInset).frame(height: 110)
                .settingsFieldBackground()
                .accessibilityLabel(title)
        }
    }
}
