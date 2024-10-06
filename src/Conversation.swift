import Foundation

public enum ConversationError: Error {
    case sessionNotFound
}

public final class Conversation: Sendable {
    private let client: RealtimeAPI
    private var errorStreamContinuation: AsyncStream<ServerError>.Continuation
    public let errors: AsyncStream<ServerError>
    private var audioStreamContinuation: AsyncStream<Data>.Continuation
    public let audioStream: AsyncStream<Data>

    @MainActor public private(set) var id: String?
    @MainActor public private(set) var session: Session?
    @MainActor public private(set) var entries: [Item] = []
    @MainActor public private(set) var connected: Bool = false

    private var cancelTask: Task<Void, Never>?

    // Designated initializer
    public init(client: RealtimeAPI) {
        self.client = client

        // Initialize the error stream
        (self.errors, self.errorStreamContinuation) = AsyncStream.makeStream(of: ServerError.self)

        // Initialize the audio stream
        (self.audioStream, self.audioStreamContinuation) = AsyncStream.makeStream(of: Data.self)

        // Start receiving events from the client
        let task = Task.detached { [weak self] in
            guard let self = self else { return }
            do {
                for try await event in self.client.events {
                    await self.handleEvent(event)
                }
            } catch {
                // Handle errors if needed
            }
            await MainActor.run {
                self.connected = false
            }
        }

        Task { @MainActor in
            self.cancelTask = task
            client.onDisconnect = { [weak self] in
                guard let self = self else { return }
                Task { @MainActor in
                    self.connected = false
                }
            }
        }
    }

    // Convenience initializers
    public convenience init(authToken token: String, model: String = "gpt-4o-realtime-preview-2024-10-01") {
        let client = RealtimeAPI(authToken: token, model: model)
        self.init(client: client)
    }

    public convenience init(connectingTo request: URLRequest) {
        let client = RealtimeAPI(connectingTo: request)
        self.init(client: client)
    }

    deinit {
        errorStreamContinuation.finish()
        audioStreamContinuation.finish()
        cancelTask?.cancel()
    }


	    @MainActor public func whenConnected<E>(_ callback: @Sendable () async throws -> E) async throws -> E {
        while true {
            if connected {
                return try await callback()
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    public func updateSession(withChanges callback: (inout Session) -> Void) async throws {
        guard var session = await session else {
            throw ConversationError.sessionNotFound
        }
        callback(&session)
        try await updateSession(session)
    }

    public func updateSession(_ session: Session) async throws {
        var session = session
        session.id = nil
        try await client.send(event: .updateSession(session))
    }

    public func send(event: ClientEvent) async throws {
        try await client.send(event: event)
    }

    public func send(audioDelta audio: Data, commit: Bool = false) async throws {
        try await send(event: .appendInputAudioBuffer(encoding: audio))
        if commit { try await send(event: .commitInputAudioBuffer()) }
    }

    public func send(from role: Item.ItemRole, text: String, response: Response.Config? = nil) async throws {
        try await send(event: .createConversationItem(Item(message: Item.Message(id: UUID().uuidString, from: role, content: [.input_text(text)]))))
        try await send(event: .createResponse(response))
    }

    public func send(result output: Item.FunctionCallOutput) async throws {
        try await send(event: .createConversationItem(Item(with: output)))
    }

@MainActor func handleEvent(_ event: ServerEvent) {
		switch event {
			case let .error(event):
				errorStream.yield(event.error)
			case let .sessionCreated(event):
				connected = true
				session = event.session
			case let .sessionUpdated(event):
				session = event.session
			case let .conversationCreated(event):
				id = event.conversation.id
			case let .conversationItemCreated(event):
				entries.append(event.item)
			case let .conversationItemInputAudioTranscriptionCompleted(event):
				updateEvent(id: event.itemId) { message in
					guard case let .input_audio(audio) = message.content[event.contentIndex] else { return }

					message.content[event.contentIndex] = .input_audio(.init(audio: audio.audio, transcript: event.transcript))
				}
			case let .conversationItemInputAudioTranscriptionFailed(event):
				errorStream.yield(event.error)
			case let .conversationItemDeleted(event):
				entries.removeAll { $0.id == event.itemId }
			case let .responseContentPartAdded(event):
				updateEvent(id: event.itemId) { message in
					message.content.insert(.init(from: event.part), at: event.contentIndex)
				}
			case let .responseContentPartDone(event):
				updateEvent(id: event.itemId) { message in
					message.content[event.contentIndex] = .init(from: event.part)
				}
			case let .responseTextDelta(event):
				updateEvent(id: event.itemId) { message in
					guard case let .text(text) = message.content[event.contentIndex] else { return }

					message.content[event.contentIndex] = .text(text + event.delta)
				}
			case let .responseTextDone(event):
				updateEvent(id: event.itemId) { message in
					message.content[event.contentIndex] = .text(event.text)
				}
			case let .responseAudioTranscriptDelta(event):
				updateEvent(id: event.itemId) { message in
					guard case let .audio(audio) = message.content[event.contentIndex] else { return }

					message.content[event.contentIndex] = .audio(.init(audio: audio.audio, transcript: (audio.transcript ?? "") + event.delta))
				}
			case let .responseAudioTranscriptDone(event):
				updateEvent(id: event.itemId) { message in
					guard case let .audio(audio) = message.content[event.contentIndex] else { return }

					message.content[event.contentIndex] = .audio(.init(audio: audio.audio, transcript: event.transcript))
				}
			case let .responseAudioDelta(event):
				updateEvent(id: event.itemId) { message in
					guard case let .audio(audio) = message.content[event.contentIndex] else { return }

					message.content[event.contentIndex] = .audio(.init(audio: audio.audio + event.delta, transcript: audio.transcript))
				}
			case let .responseFunctionCallArgumentsDelta(event):
				updateEvent(id: event.itemId) { functionCall in
					functionCall.arguments.append(event.delta)
				}
			case let .responseFunctionCallArgumentsDone(event):
				updateEvent(id: event.itemId) { functionCall in
					functionCall.arguments = event.arguments
				}
			case let .responseAudioDelta(event):
		                // Update your entries and yield to audioStreamContinuation
		                audioStreamContinuation.yield(event.delta)

			default:
				return
		}
	}

	@MainActor
	    private func updateEvent(id: String, modifying closure: (inout Item.Message) -> Void) {
	        guard let index = entries.firstIndex(where: { $0.id == id }), case var .message(message) = entries[index] else {
	            return
	        }
	
	        closure(&message)
	
	        entries[index] = .message(message)
	    }

	@MainActor
	func updateEvent(id: String, modifying closure: (inout Item.FunctionCall) -> Void) {
		guard let index = entries.firstIndex(where: { $0.id == id }), case var .functionCall(functionCall) = entries[index] else {
			return
		}

		closure(&functionCall)

		entries[index] = .functionCall(functionCall)
	}

}

