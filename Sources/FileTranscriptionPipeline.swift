import Foundation

enum FileTranscriptionPipeline {
    @MainActor
    static func transcribe(
        audioURL: URL,
        applyPrompt: Bool,
        settings: SettingsStore = .shared
    ) async throws -> String {
        let voiceToText = VoiceToTextFactory.createVoiceToText()
        let text = try await voiceToText.process(filepath: audioURL.path)

        let prompt = settings.currentPrompt
        guard applyPrompt, !prompt.isEmpty else { return text }

        let llm = LLMFactory.createLLM()
        let isReady = try await llm.isReady()
        guard isReady else {
            throw NSError(
                domain: "FileTranscriptionPipeline",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "LLM is not ready. Please download it from Setup Guide."]
            )
        }
        return try await llm.process(prompt: prompt, text: text)
    }
}
