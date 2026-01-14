import Foundation
import FoundationModels

struct BridgeRequest: Decodable {
    let system: String?
    let prompt: String
    let maxTokens: Int?
    let temperature: Double?
    let topP: Double?
    let topK: Int?
}

struct BridgeResponse: Encodable {
    let success: Bool
    let text: String?
    let error: String?
    let availability: String?
}

@main
struct AppleFoundationBridge {
    static func main() async {
        if CommandLine.arguments.contains("--status") {
            await writeStatus()
            return
        }
        await runRequest()
    }

    static func writeStatus() async {
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            let status: String
            switch model.availability {
            case .available:
                status = "available"
            case .unavailable(let reason):
                status = "unavailable:\(reason)"
            }
            let payload = BridgeResponse(success: model.isAvailable, text: nil, error: nil, availability: status)
            emit(payload)
        } else {
            let payload = BridgeResponse(success: false, text: nil, error: "unsupported_os", availability: "unavailable:unsupported_os")
            emit(payload)
        }
    }

    static func runRequest() async {
        guard #available(macOS 26.0, *) else {
            emit(BridgeResponse(success: false, text: nil, error: "unsupported_os", availability: nil))
            return
        }

        let stdinData = FileHandle.standardInput.readDataToEndOfFile()
        guard !stdinData.isEmpty else {
            emit(BridgeResponse(success: false, text: nil, error: "empty_request", availability: nil))
            return
        }

        let decoder = JSONDecoder()
        let request: BridgeRequest
        do {
            request = try decoder.decode(BridgeRequest.self, from: stdinData)
        } catch {
            emit(BridgeResponse(success: false, text: nil, error: "invalid_request", availability: nil))
            return
        }

        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            emit(BridgeResponse(success: false, text: nil, error: "model_unavailable", availability: nil))
            return
        }

        let systemPrefix = (request.system ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let promptBody = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullPrompt = systemPrefix.isEmpty ? promptBody : "\(systemPrefix)\n\n\(promptBody)"

        let sampling: GenerationOptions.SamplingMode?
        if let topP = request.topP, topP > 0 {
            sampling = .random(probabilityThreshold: topP, seed: nil)
        } else if let topK = request.topK, topK > 0 {
            sampling = .random(top: topK, seed: nil)
        } else {
            sampling = nil
        }

        let options = GenerationOptions(
            sampling: sampling,
            temperature: request.temperature,
            maximumResponseTokens: request.maxTokens
        )

        do {
            let session = LanguageModelSession(model: model)
            let response = try await session.respond(to: fullPrompt, options: options)
            emit(BridgeResponse(success: true, text: response.content, error: nil, availability: nil))
        } catch {
            emit(BridgeResponse(success: false, text: nil, error: "generation_failed", availability: nil))
        }
    }

    static func emit(_ response: BridgeResponse) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        if let data = try? encoder.encode(response) {
            FileHandle.standardOutput.write(data)
        }
    }
}
