import Foundation

/// v0.2.0 model selection: thin wrappers over the DSH Remote endpoints
/// (`session/modelCatalog` / `session/selectModel`), mirroring the desktop
/// client. Both are unary calls on the existing `LinkService.unary` transport.
extension LinkService {
    /// `session/modelCatalog` — every currently routable model grouped by
    /// provider, plus the deployment default and isolated provider failures.
    func modelCatalog() async throws -> ModelCatalog {
        let value = try await unary("session/modelCatalog", args: [:])
        return try value.decode(ModelCatalog.self)
    }

    /// `session/selectModel` — installs the Session-local selection.
    ///
    /// The Host applies it from the next request boundary; a step that is already
    /// running keeps the model it started with. Returns the normalized selection.
    func selectModel(sessionId: String, selection: ModelSelection) async throws -> ModelSelection {
        var request: [String: JSONValue] = [
            "sessionId": .string(sessionId),
            "provider": .string(selection.provider),
            "model": .string(selection.model),
        ]
        if let effort = selection.reasoningEffort, !effort.isEmpty {
            request["reasoningEffort"] = .string(effort)
        }
        let value = try await unary("session/selectModel", args: ["request": .object(request)])
        guard let selected = value["selected"], selected.objectValue != nil,
              let decoded = try? selected.decode(ModelSelection.self) else {
            throw LinkError.malformedEnvelope("session/selectModel result without selected")
        }
        return decoded
    }
}
