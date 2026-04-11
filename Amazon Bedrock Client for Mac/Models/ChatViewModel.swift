//
//  ChatViewModel.swift
//  Amazon Bedrock Client for Mac
//
//  Created by Na, Sanghwa on 6/28/24.
//

import SwiftUI
import Combine
import AWSBedrockRuntime
import Logging
import Smithy

// MARK: - Required Type Definitions for Bedrock API integration

enum MessageRole: String, Codable {
    case user = "user"
    case assistant = "assistant"
}

enum MessageContent: Codable {
    case text(String)
    case image(ImageContent)
    case document(DocumentContent)
    case thinking(ThinkingContent)
    case toolresult(ToolResultContent)
    case tooluse(ToolUseContent)
    
    // For encoding/decoding
    private enum CodingKeys: String, CodingKey {
        case type, text, image, document, thinking, toolresult, tooluse
    }
    
    struct ImageContent: Codable {
        let format: ImageFormat
        let base64Data: String
    }
    
    struct DocumentContent: Codable {
        let format: DocumentFormat
        let base64Data: String
        let name: String
    }
    
    struct ThinkingContent: Codable {
        let text: String
        let signature: String
    }
    
    struct ToolResultContent: Codable {
        let toolUseId: String
        let result: String
        let status: String
    }
    
    struct ToolUseContent: Codable {
        let toolUseId: String
        let name: String
        let input: JSONValue
    }
    
    enum DocumentFormat: String, Codable {
        case pdf = "pdf"
        case csv = "csv"
        case doc = "doc"
        case docx = "docx"
        case xls = "xls"
        case xlsx = "xlsx"
        case html = "html"
        case txt = "txt"
        case md = "md"
        
        static func fromExtension(_ ext: String) -> DocumentFormat {
            let lowercased = ext.lowercased()
            switch lowercased {
            case "pdf": return .pdf
            case "csv": return .csv
            case "doc": return .doc
            case "docx": return .docx
            case "xls": return .xls
            case "xlsx": return .xlsx
            case "html": return .html
            case "txt": return .txt
            case "md": return .md
            default: return .pdf // Default to PDF if unsupported
            }
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let imageContent):
            try container.encode("image", forKey: .type)
            try container.encode(imageContent, forKey: .image)
        case .document(let documentContent):
            try container.encode("document", forKey: .type)
            try container.encode(documentContent, forKey: .document)
        case .thinking(let thinkingContent):
            try container.encode("thinking", forKey: .type)
            try container.encode(thinkingContent, forKey: .thinking)
        case .toolresult(let toolResultContent):
            try container.encode("toolresult", forKey: .type)
            try container.encode(toolResultContent, forKey: .toolresult)
        case .tooluse(let toolUseContent):
            try container.encode("tooluse", forKey: .type)
            try container.encode(toolUseContent, forKey: .tooluse)
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        
        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case "image":
            let imageContent = try container.decode(ImageContent.self, forKey: .image)
            self = .image(imageContent)
        case "document":
            let documentContent = try container.decode(DocumentContent.self, forKey: .document)
            self = .document(documentContent)
        case "thinking":
            let thinkingContent = try container.decode(ThinkingContent.self, forKey: .thinking)
            self = .thinking(thinkingContent)
        case "toolresult":
            let toolResultContent = try container.decode(ToolResultContent.self, forKey: .toolresult)
            self = .toolresult(toolResultContent)
        case "tooluse":
            let toolUseContent = try container.decode(ToolUseContent.self, forKey: .tooluse)
            self = .tooluse(toolUseContent)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown content type: \(type)"
            )
        }
    }
}

struct BedrockMessage: Codable {
    let role: MessageRole
    var content: [MessageContent]
}

struct ToolUseError: Error {
    let message: String
}

// New struct for tool results in a modal
struct ToolResultInfo: Identifiable {
    let id: UUID = UUID()
    let toolUseId: String
    let toolName: String
    let input: JSONValue
    let result: String
    let status: String
    let timestamp: Date = Date()
}

@MainActor
class ChatViewModel: ObservableObject {
    // MARK: - Properties
    let chatId: String
    let chatManager: ChatManager
    let sharedMediaDataSource: SharedMediaDataSource
    @ObservedObject private var settingManager = SettingManager.shared
    @ObservedObject private var mcpManager = MCPManager.shared
    
    @ObservedObject var backendModel: BackendModel
    @Published var chatModel: ChatModel
    @Published var messages: [MessageData] = []
    @Published var userInput: String = ""
    @Published var isMessageBarDisabled: Bool = false
    @Published var isSending: Bool = false
    @Published var isStreamingEnabled: Bool = false
    @Published var selectedPlaceholder: String
    @Published var emptyText: String = ""
    @Published var availableTools: [MCPToolInfo] = []
    
    // New properties for tool results modal
    @Published var toolResults: [ToolResultInfo] = []
    @Published var isToolResultModalVisible: Bool = false
    @Published var selectedToolResult: ToolResultInfo?
    
    private var logger = Logger(label: "ChatViewModel")
    private var cancellables: Set<AnyCancellable> = []
    private var messageTask: Task<Void, Never>?
    
    // Track current message ID being streamed to fix duplicate issue
    private var currentStreamingMessageId: UUID?
    
    // Thinking summary generation state
    private var lastThinkingSummaryLength: Int = 0
    private let thinkingSummaryThreshold: Int = 200  // Generate summary every 200 chars
    private var thinkingCompleted: Bool = false  // Stop summary generation when thinking is done
    
    // Usage handler for displaying token usage information
    var usageHandler: ((String) -> Void)?
    
    // Format usage information for display
    private func formatUsageString(_ usage: UsageInfo) -> String {
        var parts: [String] = []
        
        if let input = usage.inputTokens {
            parts.append("Input: \(input)")
        }
        
        if let output = usage.outputTokens {
            parts.append("Output: \(output)")
        }
        
        if let cacheRead = usage.cacheReadInputTokens, cacheRead > 0 {
            parts.append("Cache Read: \(cacheRead)")
        }
        
        if let cacheWrite = usage.cacheCreationInputTokens, cacheWrite > 0 {
            parts.append("Cache Write: \(cacheWrite)")
        }
        
        return parts.joined(separator: " • ")
    }
    
    // MARK: - Initialization
    
    init(chatId: String, backendModel: BackendModel, chatManager: ChatManager = .shared, sharedMediaDataSource: SharedMediaDataSource) {
        self.chatId = chatId
        self.backendModel = backendModel
        self.chatManager = chatManager
        self.sharedMediaDataSource = sharedMediaDataSource
        
        // Try to get existing chat model, or create a temporary one if not found
        if let model = chatManager.getChatModel(for: chatId) {
            self.chatModel = model
            self.selectedPlaceholder = ""
            setupStreamingEnabled()
            setupBindings()
        } else {
            // Create a temporary model and load asynchronously
            logger.warning("Chat model not found for id: \(chatId), will attempt to load or create")
            self.chatModel = ChatModel(
                id: chatId,
                chatId: chatId,
                name: "Loading...",
                title: "Loading...",
                description: "",
                provider: "bedrock",
                lastMessageDate: Date()
            )
            self.selectedPlaceholder = ""
            
            // Try to load the model asynchronously
            Task {
                await loadChatModel()
            }
        }
    }
    
    // MARK: - Setup Methods
    
    private func setupStreamingEnabled() {
        self.isStreamingEnabled = isTextGenerationModel(chatModel.id)
    }
    
    private func setupBindings() {
        chatManager.$chats
            .map { [weak self] chats in
                chats.first { $0.chatId == self?.chatId }
            }
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .assign(to: \.chatModel, on: self)
            .store(in: &cancellables)
        
        $chatModel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] model in
                guard let self = self else { return }
                self.isStreamingEnabled = self.isTextGenerationModel(model.id)
            }
            .store(in: &cancellables)
    }
    
    private func loadChatModel() async {
        // Try to find existing model for up to 10 attempts
        for attempt in 0..<10 {
            if let model = chatManager.getChatModel(for: chatId) {
                await MainActor.run {
                    self.chatModel = model
                    setupStreamingEnabled()
                    setupBindings()
                }
                logger.info("Successfully loaded chat model for id: \(chatId) after \(attempt + 1) attempts")
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
        }
        
        // If still not found, create a new chat
        logger.warning("Chat model still not found for id: \(chatId) after 10 attempts, creating new chat")
        
        await MainActor.run {
            // Use default values since we can't access BackendModel properties directly
            chatManager.createNewChat(
                modelId: "claude-3-5-sonnet-20241022-v2:0", // Default model
                modelName: "Claude 3.5 Sonnet",
                modelProvider: "anthropic"
            ) { [weak self] newModel in
                guard let self = self else { return }
                
                // Update the chat ID if it was changed during creation
                if newModel.id != self.chatId {
                    logger.info("Chat ID changed from \(self.chatId) to \(newModel.id)")
                }
                
                self.chatModel = newModel
                self.setupStreamingEnabled()
                self.setupBindings()
                logger.info("Successfully created new chat model with id: \(newModel.id)")
            }
        }
    }
    
    // MARK: - Public Methods
    
    func loadInitialData() {
        var loadedMessages = chatManager.getMessages(for: chatId)
        
        // Mark tool result messages with "ToolResult" user so they are hidden in UI
        // Tool result messages have: user == "User", toolUse != nil, toolResult != nil
        for i in 0..<loadedMessages.count {
            if loadedMessages[i].user == "User" &&
               loadedMessages[i].toolUse != nil &&
               loadedMessages[i].toolResult != nil {
                loadedMessages[i].user = "ToolResult"
            }
        }
        
        messages = loadedMessages
    }
    
    func sendMessage() {
        // Allow sending if there's text, images, or documents
        guard !userInput.isEmpty || !sharedMediaDataSource.images.isEmpty || !sharedMediaDataSource.documents.isEmpty else { return }
        
        messageTask?.cancel()
        messageTask = Task { await sendMessageAsync() }
    }
    
    func sendMessage(_ message: String) {
        guard !message.isEmpty else { return }
        
        // Set the message and send it
        userInput = message
        messageTask?.cancel()
        messageTask = Task { await sendMessageAsync() }
    }
    
    func cancelSending() {
        messageTask?.cancel()
        chatManager.setIsLoading(false, for: chatId)
    }
    
    func showToolResultDetails(_ toolResult: ToolResultInfo) {
        selectedToolResult = toolResult
        isToolResultModalVisible = true
    }
    
    // MARK: - Tool Use Tracker

    /**
     * Tracks multiple tool use blocks during streaming.
     * Supports parallel tool execution by tracking each content block independently.
     */
    actor ToolUseTracker {
        static let shared = ToolUseTracker()

        /// Represents a single tool use block being accumulated during streaming.
        struct ToolBlock {
            let toolUseId: String
            let name: String
            var inputString: String = ""
        }

        /// Active tool blocks indexed by content block index
        private var blocks: [Int: ToolBlock] = [:]
        /// Completed tools collected during streaming
        private var completedTools: [ToolInfo] = []
        /// Tracks the most recently started block index (for fallback paths)
        private var currentBlockIndex: Int?

        /// Resets all tracking state for a new conversation turn.
        func reset() {
            blocks.removeAll()
            completedTools.removeAll()
            currentBlockIndex = nil
        }

        /// Registers a new tool use block at the given content block index.
        func startBlock(index: Int, id: String, name: String) {
            blocks[index] = ToolBlock(toolUseId: id, name: name)
        }

        /// Appends streamed input text to the tool block at the given index.
        func appendToBlock(index: Int, text: String) {
            blocks[index]?.inputString += text
        }

        /// Returns the tool block at the given index, if it exists.
        func getBlock(index: Int) -> ToolBlock? {
            return blocks[index]
        }

        /// Returns whether a tool block exists at the given index.
        func hasBlock(index: Int) -> Bool {
            return blocks[index] != nil
        }

        /// Adds a completed tool to the collection for batch retrieval.
        func addCompletedTool(_ tool: ToolInfo) {
            completedTools.append(tool)
        }

        /// Returns all completed tools collected during streaming.
        func getCompletedTools() -> [ToolInfo] {
            return completedTools
        }

        /// Clears the completed tools collection.
        func clearCompletedTools() {
            completedTools.removeAll()
        }

        /// Sets the current block index (used by fallback single-tool paths).
        func setCurrentBlockIndex(_ index: Int) {
            currentBlockIndex = index
        }

        /// Returns the current block index.
        func getCurrentBlockIndex() -> Int? {
            return currentBlockIndex
        }

        /// Returns the tool use ID for the current block.
        func getToolUseId() -> String? {
            guard let idx = currentBlockIndex else { return nil }
            return blocks[idx]?.toolUseId
        }

        /// Returns the tool name for the current block.
        func getToolName() -> String? {
            guard let idx = currentBlockIndex else { return nil }
            return blocks[idx]?.name
        }

        /// Returns the accumulated input string for the current block.
        func getInputString() -> String {
            guard let idx = currentBlockIndex else { return "" }
            return blocks[idx]?.inputString ?? ""
        }
    }
    
    // MARK: - Private Message Handling Methods
    
    private func sendMessageAsync() async {
        chatManager.setIsLoading(true, for: chatId)
        isMessageBarDisabled = true
        
        let tempInput = userInput
        Task {
            await updateChatTitle(with: tempInput)
        }
        
        let userMessage = createUserMessage()
        addMessage(userMessage)
        
        // For image generation models, get images BEFORE clearing
        let attachedImages = await getAttachedImagesBase64()
        
        userInput = ""
        sharedMediaDataSource.clear()
        
        do {
            if backendModel.backend.isImageGenerationModel(chatModel.id) {
                try await handleImageGenerationModel(userMessage, attachedImages: attachedImages)
            } else if backendModel.backend.isEmbeddingModel(chatModel.id) {
                try await handleEmbeddingModel(userMessage)
            } else {
                // Check if streaming is enabled for this model
                let modelConfig = settingManager.getInferenceConfig(for: chatModel.id)
                let shouldUseStreaming = modelConfig.overrideDefault ? modelConfig.enableStreaming : true
                
                if shouldUseStreaming {
                    try await handleTextLLMWithConverseStream(userMessage)
                } else {
                    try await handleTextLLMWithNonStreaming(userMessage)
                }
            }
        } catch let error as ToolUseError {
            let errorMessage = MessageData(
                id: UUID(),
                text: "Tool Use Error: \(error.message)",
                user: "System",
                isError: true,
                sentTime: Date()
            )
            addMessage(errorMessage)
        } catch let error {
            if let nsError = error as NSError?,
               nsError.localizedDescription.contains("ValidationException") &&
                nsError.localizedDescription.contains("maxLength: 512") {
                let errorMessage = MessageData(
                    id: UUID(),
                    text: "Error: Your prompt is too long. Titan Image Generator has a 512 character limit for prompts. Please try again with a shorter prompt.",
                    user: "System",
                    isError: true,
                    sentTime: Date()
                )
                addMessage(errorMessage)
            } else {
                await handleModelError(error)
            }
        }
        
        isMessageBarDisabled = false
        chatManager.setIsLoading(false, for: chatId)
    }
    
    private func createUserMessage() -> MessageData {
        // Process images
        var imageFormats: [String] = []
        let imageBase64Strings = sharedMediaDataSource.images.enumerated().compactMap { index, image -> String? in
            guard index < sharedMediaDataSource.fileExtensions.count else {
                logger.error("Missing extension for image at index \(index)")
                return nil
            }

            let fileExtension = sharedMediaDataSource.fileExtensions[index]
            let result = base64EncodeImage(image, withExtension: fileExtension)
            if result.base64String != nil {
                imageFormats.append(fileExtension)
            }
            return result.base64String
        }
        
        // Process documents with improved error handling
        // Pasted text (has textPreview) is sent as text block, not document block
        // This avoids Bedrock's 5 document limit in conversation history
        var documentBase64Strings: [String] = []
        var documentFormats: [String] = []
        var documentNames: [String] = []
        var pastedTextInfos: [PastedTextInfo] = []  // For UI display
        var pastedTextContents: [String] = []  // For text block in API
        
        for (index, docData) in sharedMediaDataSource.documents.enumerated() {
            // Check if this is pasted text (has textPreview)
            let isPastedText = index < sharedMediaDataSource.textPreviews.count &&
                               sharedMediaDataSource.textPreviews[index] != nil
            
            if isPastedText {
                // Convert pasted text to string and add to text contents
                if let textContent = String(data: docData, encoding: .utf8) {
                    let filename = index < sharedMediaDataSource.documentFilenames.count ?
                        sharedMediaDataSource.documentFilenames[index] : "pasted_text.txt"
                    pastedTextContents.append("[\(filename)]\n\(textContent)")
                    pastedTextInfos.append(PastedTextInfo(filename: filename, content: textContent))
                    logger.info("Added pasted text as text block: \(filename) (\(docData.count) bytes)")
                }
                continue  // Skip adding to document arrays
            }
            
            // Regular document processing
            guard index < sharedMediaDataSource.documentExtensions.count,
                  index < sharedMediaDataSource.documentFilenames.count else {
                logger.error("Missing extension or filename for document at index \(index)")
                continue
            }
            
            let fileExt = sharedMediaDataSource.documentExtensions[index]
            let filename = sharedMediaDataSource.documentFilenames[index]
            
            // Validate file extension is supported
            let supportedExtensions = ["pdf", "csv", "doc", "docx", "xls", "xlsx", "html", "txt", "md"]
            guard supportedExtensions.contains(fileExt.lowercased()) else {
                logger.error("Unsupported document format: \(fileExt)")
                continue
            }
            
            // Validate document data is not empty
            guard !docData.isEmpty else {
                logger.error("Empty document data for \(filename)")
                continue
            }
            
            let base64String = docData.base64EncodedString()
            documentBase64Strings.append(base64String)
            documentFormats.append(fileExt)
            documentNames.append(filename)
            
            logger.info("Added document: \(filename) (\(fileExt), \(docData.count) bytes)")
        }
        
        // Determine the text to send
        // Bedrock API requires a text block when sending images or documents
        // Include pasted text contents in the text block (not as documents)
        var textToSend: String
        
        // Start with user input or default prompt
        if userInput.isEmpty {
            if !documentBase64Strings.isEmpty && !imageBase64Strings.isEmpty {
                textToSend = "Please analyze these documents and images."
            } else if !documentBase64Strings.isEmpty {
                textToSend = "Please analyze this document."
            } else if !imageBase64Strings.isEmpty {
                textToSend = "Please analyze this image."
            } else if !pastedTextContents.isEmpty {
                textToSend = "Please analyze this text."
            } else {
                textToSend = userInput
            }
        } else {
            textToSend = userInput
        }
        
        // Store original text for UI display (pasted texts shown separately as chips)
        // The pasted text content will be appended when converting to Bedrock message format
        return MessageData(
            id: UUID(),
            text: textToSend,  // Original user input only, not including pasted text
            user: "User",
            isError: false,
            sentTime: Date(),
            imageBase64Strings: imageBase64Strings.isEmpty ? nil : imageBase64Strings,
            imageFormats: imageFormats.isEmpty ? nil : imageFormats,
            documentBase64Strings: documentBase64Strings.isEmpty ? nil : documentBase64Strings,
            documentFormats: documentFormats.isEmpty ? nil : documentFormats,
            documentNames: documentNames.isEmpty ? nil : documentNames,
            pastedTexts: pastedTextInfos.isEmpty ? nil : pastedTextInfos
        )
    }
    
    // MARK: - Tool Conversion and Processing
    
    private func convertMCPToolsToBedrockFormat(_ tools: [MCPToolInfo]) -> AWSBedrockRuntime.BedrockRuntimeClientTypes.ToolConfiguration {
        logger.debug("Converting \(tools.count) MCP tools to Bedrock format")
        
        let bedrockTools: [AWSBedrockRuntime.BedrockRuntimeClientTypes.Tool] = tools.compactMap { toolInfo in
            var propertiesDict: [String: Any] = [:]
            var required: [String] = []
            
            if case .object(let schemaDict) = toolInfo.tool.inputSchema {
                if case .object(let propertiesMap)? = schemaDict["properties"] {
                    for (key, value) in propertiesMap {
                        if case .object(let propDetails) = value,
                           case .string(let typeValue)? = propDetails["type"] {
                            propertiesDict[key] = ["type": typeValue]
                            logger.debug("Added property \(key) with type \(typeValue) for tool \(toolInfo.toolName)")
                        }
                    }
                }
                
                if case .array(let requiredArray)? = schemaDict["required"] {
                    for item in requiredArray {
                        if case .string(let fieldName) = item {
                            required.append(fieldName)
                        }
                    }
                }
            }
            
            let schemaDict: [String: Any] = [
                "properties": propertiesDict,
                "required": required,
                "type": "object"
            ]
            
            do {
                let jsonDocument = try Smithy.Document.make(from: schemaDict)
                
                let toolSpec = AWSBedrockRuntime.BedrockRuntimeClientTypes.ToolSpecification(
                    description: toolInfo.tool.description,
                    inputSchema: .json(jsonDocument),
                    name: toolInfo.toolName
                )
                
                return AWSBedrockRuntime.BedrockRuntimeClientTypes.Tool.toolspec(toolSpec)
            } catch {
                logger.error("Failed to create schema document for tool \(toolInfo.toolName): \(error)")
                return nil
            }
        }
        
        return AWSBedrockRuntime.BedrockRuntimeClientTypes.ToolConfiguration(
            toolChoice: .auto(AWSBedrockRuntime.BedrockRuntimeClientTypes.AutoToolChoice()),
            tools: bedrockTools
        )
    }
    
    /**
     * Parses a raw JSON input string into a dictionary.
     *
     * @param inputString The raw JSON string accumulated from streaming chunks
     * @return Parsed dictionary, or a fallback text wrapper if parsing fails
     */
    private func parseToolInput(_ inputString: String) -> [String: Any] {
        if inputString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [:]
        }
        guard let data = inputString.data(using: .utf8) else {
            return ["text": inputString]
        }
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return json
            } else if let jsonArray = try JSONSerialization.jsonObject(with: data) as? [Any] {
                return ["array": jsonArray]
            }
        } catch {}
        return ["text": inputString]
    }

    /**
     * Extracts tool use info from a streaming chunk.
     * Returns a single completed tool if `contentblockstop` fires, or nil.
     * Also collects completed tools in the tracker for batch retrieval at `messagestop`.
     *
     * @param chunk A streaming output chunk from the Bedrock ConverseStream API
     * @return Tuple of (toolUseId, name, input) if a tool block completed, nil otherwise
     */
    private func extractToolUseFromChunk(_ chunk: BedrockRuntimeClientTypes.ConverseStreamOutput) async -> (toolUseId: String, name: String, input: [String: Any])? {
        let tracker = ToolUseTracker.shared

        // --- Block start: register new tool block ---
        if case .contentblockstart(let blockStartEvent) = chunk,
           let start = blockStartEvent.start,
           case .tooluse(let toolUseBlockStart) = start,
           let contentBlockIndex = blockStartEvent.contentBlockIndex {

            guard let toolUseId = toolUseBlockStart.toolUseId,
                  let name = toolUseBlockStart.name else {
                logger.warning("Received incomplete tool use block start")
                return nil
            }

            await tracker.startBlock(index: contentBlockIndex, id: toolUseId, name: name)
            await tracker.setCurrentBlockIndex(contentBlockIndex)
            logger.info("Tool use start detected: \(name) with ID: \(toolUseId)")
            return nil
        }

        // --- Block delta: accumulate input ---
        if case .contentblockdelta(let deltaEvent) = chunk,
           let delta = deltaEvent.delta,
           let blockIndex = deltaEvent.contentBlockIndex {

            if await tracker.hasBlock(index: blockIndex),
               case .tooluse(let toolUseDelta) = delta,
               let inputStr = toolUseDelta.input {
                await tracker.appendToBlock(index: blockIndex, text: inputStr)
            }
            return nil
        }

        // --- Block stop: complete one tool block, collect it ---
        if case .contentblockstop(let stopEvent) = chunk,
           let blockIndex = stopEvent.contentBlockIndex,
           let block = await tracker.getBlock(index: blockIndex) {

            let inputDict = parseToolInput(block.inputString)
            let toolInfo = ToolInfo(id: block.toolUseId, name: block.name, input: JSONValue.from(inputDict))
            await tracker.addCompletedTool(toolInfo)
            logger.info("Tool use block completed for \(block.name). Input: \(inputDict)")
            return (toolUseId: block.toolUseId, name: block.name, input: inputDict)
        }

        // --- Message stop with toolUse reason ---
        if case .messagestop(let stopEvent) = chunk,
           stopEvent.stopReason == .toolUse {
            let completed = await tracker.getCompletedTools()
            if !completed.isEmpty {
                logger.info("messagestop with \(completed.count) tool(s) collected")
                return nil
            }
            // Fallback: try current block
            if let toolUseId = await tracker.getToolUseId(),
               let name = await tracker.getToolName() {
                let inputString = await tracker.getInputString()
                let inputDict = parseToolInput(inputString)
                logger.info("Tool use detected from messageStop: \(name)")
                return (toolUseId: toolUseId, name: name, input: inputDict)
            }
        }

        return nil
    }

    /**
     * Checks if a streaming chunk is a messagestop event with tool use reason.
     *
     * @param chunk A streaming output chunk
     * @return True if the chunk signals the end of a tool-use response
     */
    private func isToolUseStop(_ chunk: BedrockRuntimeClientTypes.ConverseStreamOutput) -> Bool {
        if case .messagestop(let stopEvent) = chunk,
           stopEvent.stopReason == .toolUse {
            return true
        }
        return false
    }
    
    // MARK: - handleTextLLMWithConverseStream
    
    private func handleTextLLMWithConverseStream(_ userMessage: MessageData) async throws {
        // Create message content from user message
        var messageContents: [MessageContent] = []
        
        // Build full text including pasted texts for API transmission
        var fullText = userMessage.text
        if let pastedTexts = userMessage.pastedTexts, !pastedTexts.isEmpty {
            for pastedText in pastedTexts {
                if !fullText.isEmpty {
                    fullText += "\n\n---\n\n"
                }
                fullText += "[\(pastedText.filename)]:\n\(pastedText.content)"
            }
            logger.debug("[API] Added \(pastedTexts.count) pasted text(s) to message")
        }
        
        // Always include a text prompt as required when sending documents/images/pasted texts
        var textToSend = fullText
        if textToSend.isEmpty {
            if userMessage.documentBase64Strings?.isEmpty == false {
                textToSend = "Please analyze this document."
            } else if userMessage.imageBase64Strings?.isEmpty == false {
                textToSend = "Please analyze this image."
            } else if userMessage.pastedTexts?.isEmpty == false {
                textToSend = "Please analyze this text."
            }
        }
        messageContents.append(.text(textToSend))
        
        // Add images if present
        if let imageBase64Strings = userMessage.imageBase64Strings, !imageBase64Strings.isEmpty {
            for (index, base64String) in imageBase64Strings.enumerated() {
                let fileExtension = index < (userMessage.imageFormats?.count ?? 0) ?
                    userMessage.imageFormats![index].lowercased() : "jpeg"

                let format: ImageFormat
                switch fileExtension {
                case "jpg", "jpeg": format = .jpeg
                case "png": format = .png
                case "gif": format = .gif
                case "webp": format = .webp
                default: format = .jpeg
                }

                messageContents.append(.image(MessageContent.ImageContent(
                    format: format,
                    base64Data: base64String
                )))
            }
        }
        
        // Add documents if present
        if let documentBase64Strings = userMessage.documentBase64Strings,
           let documentFormats = userMessage.documentFormats,
           let documentNames = userMessage.documentNames,
           !documentBase64Strings.isEmpty {
            
            for (index, base64String) in documentBase64Strings.enumerated() {
                guard index < documentFormats.count && index < documentNames.count else {
                    continue
                }
                
                let fileExt = documentFormats[index].lowercased()
                let fileName = documentNames[index]
                
                let docFormat = MessageContent.DocumentFormat.fromExtension(fileExt)
                messageContents.append(.document(MessageContent.DocumentContent(
                    format: docFormat,
                    base64Data: base64String,
                    name: fileName
                )))
            }
        }

        // Save current messages first, then get conversation history
        // This ensures the new user message (with pastedTexts) is included
        await saveFromUIMessages()
        let conversationHistory = await getConversationHistory()
        
        // Get system prompt
        let systemPrompt = settingManager.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Get tool configurations if MCP is enabled
        var toolConfig: AWSBedrockRuntime.BedrockRuntimeClientTypes.ToolConfiguration? = nil
        
        // Check if any MCP server is actually connected (subprocess running)
        let hasConnectedServer = mcpManager.connectionStatus.values.contains(.connected)
        
        if mcpManager.mcpEnabled &&
            !mcpManager.toolInfos.isEmpty &&
            hasConnectedServer &&
            backendModel.backend.isStreamingToolUseSupported(chatModel.id) {
            let toolCount = mcpManager.toolInfos.count
            let connectedCount = mcpManager.connectionStatus.values.filter { $0 == .connected }.count
            logger.info("MCP enabled with \(toolCount) tools from \(connectedCount) connected server(s) for model \(chatModel.id).")
            toolConfig = convertMCPToolsToBedrockFormat(mcpManager.toolInfos)
            // MCP connection notification is sent from MCPManager when server connects
        } else if mcpManager.mcpEnabled && !mcpManager.toolInfos.isEmpty && !hasConnectedServer {
            logger.info("MCP enabled but no servers connected yet.")
        } else if mcpManager.mcpEnabled && hasConnectedServer && !backendModel.backend.isStreamingToolUseSupported(chatModel.id) {
            logger.info("MCP enabled, but model \(chatModel.id) does not support streaming tool use. Tools disabled.")
        }
        
        // Reset tool tracker for new conversation
        await ToolUseTracker.shared.reset()
        
        let maxTurns = settingManager.maxToolUseTurns
        let turn_count = 0
        
        // Get Bedrock messages in AWS SDK format
        let bedrockMessages = try conversationHistory.map { try convertToBedrockMessage($0, modelId: chatModel.id) }
        
        // Convert to system prompt format used by AWS SDK
        let systemContentBlock: [AWSBedrockRuntime.BedrockRuntimeClientTypes.SystemContentBlock]? =
        systemPrompt.isEmpty ? nil : [.text(systemPrompt)]
        
        logger.info("Starting converseStream request with model ID: \(chatModel.id)")
        
        // Start the tool cycling process
        try await processToolCycles(bedrockMessages: bedrockMessages, systemContentBlock: systemContentBlock, toolConfig: toolConfig, turnCount: turn_count, maxTurns: maxTurns)
    }
    
    /**
     * Processes tool cycles recursively with parallel tool execution support.
     * Phase 1: Streams all chunks from the model, collecting tool use blocks without executing.
     * Phase 2: Executes all collected tools in parallel, updates UI per-tool, then recurses.
     *
     * @param bedrockMessages The current conversation messages for the API
     * @param systemContentBlock System prompt content blocks
     * @param toolConfig Tool configuration for the API request
     * @param turnCount Current tool cycle turn number
     * @param maxTurns Maximum allowed tool cycle turns
     */
    private func processToolCycles(
        bedrockMessages: [AWSBedrockRuntime.BedrockRuntimeClientTypes.Message],
        systemContentBlock: [AWSBedrockRuntime.BedrockRuntimeClientTypes.SystemContentBlock]?,
        toolConfig: AWSBedrockRuntime.BedrockRuntimeClientTypes.ToolConfiguration?,
        turnCount: Int,
        maxTurns: Int
    ) async throws {
        if turnCount >= maxTurns {
            logger.info("Maximum number of tool use turns (\(maxTurns)) reached")
            return
        }

        var streamedText = ""
        var thinking: String? = nil
        var thinkingSignature: String? = nil
        var isFirstChunk = true
        var toolWasUsed = false

        let messageId = UUID()
        currentStreamingMessageId = messageId
        var collectedToolInfos: [ToolInfo] = []

        lastThinkingSummaryLength = 0
        thinkingCompleted = false

        await ToolUseTracker.shared.reset()

        let backend = await MainActor.run { backendModel.backend }

        // Phase 1: Stream all chunks, collect tool uses without executing
        for try await chunk in try await backend.converseStream(
            withId: chatModel.id,
            messages: bedrockMessages,
            systemContent: systemContentBlock,
            inferenceConfig: nil,
            toolConfig: toolConfig,
            usageHandler: { @Sendable [weak self] usage in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    let formattedUsage = self.formatUsageString(usage)
                    self.usageHandler?(formattedUsage)
                }
            }
        ) {
            // Collect tool use blocks (don't execute yet)
            if let toolUseInfo = await extractToolUseFromChunk(chunk) {
                toolWasUsed = true
                let toolInfo = ToolInfo(
                    id: toolUseInfo.toolUseId,
                    name: toolUseInfo.name,
                    input: JSONValue.from(toolUseInfo.input)
                )

                // Avoid duplicates (contentblockstop may fire before messagestop)
                if !collectedToolInfos.contains(where: { $0.id == toolInfo.id }) {
                    collectedToolInfos.append(toolInfo)
                }

                // Update UI to show tool is pending
                if isFirstChunk {
                    let initialMessage = MessageData(
                        id: messageId,
                        text: streamedText.isEmpty ? "Analyzing your request..." : streamedText,
                        thinking: thinking,
                        signature: thinkingSignature,
                        user: chatModel.name,
                        isError: false,
                        sentTime: Date(),
                        toolUses: collectedToolInfos,
                        toolResults: collectedToolInfos.map {
                            ToolResultEntry(toolUseId: $0.id, toolName: $0.name, result: "", status: "running")
                        }
                    )
                    addMessage(initialMessage)
                    isFirstChunk = false
                } else if let index = self.messages.firstIndex(where: { $0.id == messageId }) {
                    self.messages[index].toolUses = collectedToolInfos
                    self.messages[index].toolResults = collectedToolInfos.map {
                        ToolResultEntry(toolUseId: $0.id, toolName: $0.name, result: "", status: "running")
                    }
                    if self.messages[index].thinking == nil && thinking != nil {
                        self.messages[index].thinking = thinking
                    }
                    if self.messages[index].signature == nil && thinkingSignature != nil {
                        self.messages[index].signature = thinkingSignature
                    }
                }

                continue
            }

            // Check for messagestop with toolUse reason (signals end of all tool blocks)
            if isToolUseStop(chunk) {
                // All tools collected via contentblockstop events above
                continue
            }

            // Process regular text chunk
            if let textChunk = extractTextFromChunk(chunk) {
                streamedText += textChunk
                appendTextToMessage(textChunk, messageId: messageId, shouldCreateNewMessage: isFirstChunk)
                isFirstChunk = false
            }

            // Process thinking chunk
            let thinkingResult = extractThinkingFromChunk(chunk)
            if let thinkingText = thinkingResult.text {
                thinking = (thinking ?? "") + thinkingText
                appendThinkingToMessage(thinkingText, messageId: messageId, shouldCreateNewMessage: isFirstChunk)
                isFirstChunk = false
            }
            if let thinkingSignatureText = thinkingResult.signature {
                thinkingSignature = thinkingSignatureText
            }
        }

        // Phase 2: If tools were collected, execute them in parallel
        if toolWasUsed && !collectedToolInfos.isEmpty {
            logger.info("Executing \(collectedToolInfos.count) tool(s) in parallel for cycle \(turnCount+1)")

            // Execute all tools in parallel using unstructured Tasks
            // Each task calls MCPManager (which is also @MainActor) and returns result
            var tasks: [Int: Task<SendableToolResult, Never>] = [:]

            for (idx, info) in collectedToolInfos.enumerated() {
                let toolId = info.id
                let toolName = info.name
                let toolInput = info.input.asDictionary ?? [:]
                tasks[idx] = Task {
                    await self.executeSendableMCPTool(id: toolId, name: toolName, input: toolInput)
                }
            }

            // Collect results and update UI as each completes
            var executionResults = Array(repeating: SendableToolResult(status: "error", text: "Not executed", error: nil), count: collectedToolInfos.count)

            for (idx, task) in tasks {
                let result = await task.value
                executionResults[idx] = result

                // Update UI with individual tool completion
                let toolId = collectedToolInfos[idx].id
                let toolName = collectedToolInfos[idx].name
                if let msgIndex = self.messages.firstIndex(where: { $0.id == messageId }),
                   var entries = self.messages[msgIndex].toolResults,
                   let entryIdx = entries.firstIndex(where: { $0.toolUseId == toolId }) {
                    entries[entryIdx] = ToolResultEntry(
                        toolUseId: toolId, toolName: toolName,
                        result: result.text, status: result.status
                    )
                    self.messages[msgIndex].toolResults = entries
                }
            }

            // Build result entries
            let resultEntries: [ToolResultEntry] = zip(collectedToolInfos, executionResults).map { info, result in
                ToolResultEntry(toolUseId: info.id, toolName: info.name, result: result.text, status: result.status)
            }

            // Update UI message with final results
            if let index = self.messages.firstIndex(where: { $0.id == messageId }) {
                self.messages[index].toolUses = collectedToolInfos
                self.messages[index].toolResults = resultEntries
            }

            // Add to toolResults collection (for modal)
            for (info, result) in zip(collectedToolInfos, executionResults) {
                toolResults.append(ToolResultInfo(
                    toolUseId: info.id,
                    toolName: info.name,
                    input: info.input,
                    result: result.text,
                    status: result.status
                ))
            }

            // Update storage
            let preservedText = messages.first(where: { $0.id == messageId })?.text ?? streamedText
            chatManager.updateMessageWithToolInfos(
                for: chatId, messageId: messageId, newText: preservedText,
                toolInfos: collectedToolInfos, toolResultEntries: resultEntries,
                thinking: thinking, thinkingSignature: thinkingSignature
            )

            // Build assistant message with all tool_use blocks
            var assistantContent: [MessageContent] = []
            if let existingThinking = thinking, let existingSignature = thinkingSignature {
                assistantContent.append(.thinking(MessageContent.ThinkingContent(
                    text: existingThinking, signature: existingSignature
                )))
            }
            assistantContent.append(.text(
                preservedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Analyzing your request..." : preservedText
            ))
            for info in collectedToolInfos {
                assistantContent.append(.tooluse(MessageContent.ToolUseContent(
                    toolUseId: info.id, name: info.name, input: info.input
                )))
            }
            let assistantMessage = BedrockMessage(role: .assistant, content: assistantContent)

            // Build user message with all tool_result blocks
            var toolResultContents: [MessageContent] = []
            for (info, result) in zip(collectedToolInfos, executionResults) {
                toolResultContents.append(.toolresult(MessageContent.ToolResultContent(
                    toolUseId: info.id, result: result.text, status: result.status
                )))
            }
            let toolResultMessage = BedrockMessage(role: .user, content: toolResultContents)

            logger.debug("Added assistant message with \(collectedToolInfos.count) tool_use block(s)")
            logger.debug("Added user message with \(collectedToolInfos.count) tool_result block(s)")

            let awsAssistantMessage = try convertToBedrockMessage(assistantMessage, modelId: chatModel.id)
            let awsToolResultMessage = try convertToBedrockMessage(toolResultMessage, modelId: chatModel.id)

            var updatedMessages = bedrockMessages
            updatedMessages.append(awsAssistantMessage)
            updatedMessages.append(awsToolResultMessage)

            // Add hidden tool result message for API history
            let toolResultMsg = MessageData(
                id: UUID(),
                text: "",
                user: "ToolResult",
                isError: false,
                sentTime: Date(),
                toolUses: collectedToolInfos,
                toolResults: resultEntries
            )
            messages.append(toolResultMsg)

            await saveFromUIMessages()

            // Recursively continue with next turn
            try await processToolCycles(
                bedrockMessages: updatedMessages,
                systemContentBlock: systemContentBlock,
                toolConfig: toolConfig,
                turnCount: turnCount + 1,
                maxTurns: maxTurns
            )
            currentStreamingMessageId = nil
            return
        }

        // No tools used — finalize text response
        let assistantText = streamedText.trimmingCharacters(in: .whitespacesAndNewlines)

        if isFirstChunk {
            let assistantMessage = MessageData(
                id: messageId,
                text: assistantText,
                thinking: thinking,
                signature: thinkingSignature,
                user: chatModel.name,
                isError: false,
                sentTime: Date()
            )
            addMessage(assistantMessage)
        } else {
            updateMessageText(messageId: messageId, newText: assistantText)
            if let thinking = thinking {
                updateMessageThinking(messageId: messageId, newThinking: thinking, signature: thinkingSignature)
            }
        }

        if let thinkingContent = thinking, !thinkingContent.isEmpty, !thinkingCompleted {
            Task {
                await generateThinkingSummary(for: messageId, thinking: thinkingContent)
            }
        }

        lastThinkingSummaryLength = 0
        thinkingCompleted = false

        await saveFromUIMessages()
        currentStreamingMessageId = nil
    }
    
    // Sendable tool result struct
    struct SendableToolResult: Sendable {
        let status: String
        let text: String
        let error: String?
    }
    
    // Fixed Sendable MCP tool execution
    private func executeSendableMCPTool(id: String, name: String, input: [String: Any]) async -> SendableToolResult {
        var resultStatus = "error"
        var resultText = "Tool execution failed"
        var resultError: String? = nil
        
        do {
            let mcpToolResult = await mcpManager.executeBedrockTool(id: id, name: name, input: input)
            
            if let status = mcpToolResult["status"] as? String {
                resultStatus = status
                
                if status == "success" {
                    // Handle multi-modal content
                    if let content = mcpToolResult["content"] as? [[String: Any]] {
                        var textResults: [String] = []
                        
                        for contentItem in content {
                            if let type = contentItem["type"] as? String {
                                switch type {
                                case "text":
                                    if let text = contentItem["text"] as? String {
                                        textResults.append(text)
                                    }
                                case "image":
                                    if let description = contentItem["description"] as? String {
                                        textResults.append("🖼️ \(description)")
                                    } else {
                                        textResults.append("🖼️ Generated image")
                                    }
                                case "audio":
                                    if let description = contentItem["description"] as? String {
                                        textResults.append("🔊 \(description)")
                                    } else {
                                        textResults.append("🔊 Generated audio")
                                    }
                                case "resource":
                                    if let text = contentItem["text"] as? String {
                                        textResults.append(text)
                                    } else if let description = contentItem["description"] as? String {
                                        textResults.append("📄 \(description)")
                                    }
                                default:
                                    if let description = contentItem["description"] as? String {
                                        textResults.append(description)
                                    }
                                }
                            }
                        }
                        
                        resultText = textResults.isEmpty ? "Tool execution completed" : textResults.joined(separator: "\n")
                    } else {
                        resultText = "Tool execution completed"
                    }
                } else {
                    if let error = mcpToolResult["error"] as? String {
                        resultError = error
                        resultText = "Tool execution failed: \(error)"
                    } else if let content = mcpToolResult["content"] as? [[String: Any]],
                             let firstContent = content.first,
                             let text = firstContent["text"] as? String {
                        resultText = text
                    }
                }
            }
        }
        
        return SendableToolResult(status: resultStatus, text: resultText, error: resultError)
    }

    // Helper method to append text during streaming
    private func appendTextToMessage(_ text: String, messageId: UUID, shouldCreateNewMessage: Bool = false) {
        // Stop thinking summary generation when text starts
        stopThinkingSummaryGeneration()
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if shouldCreateNewMessage {
                let newMessage = MessageData(
                    id: messageId,
                    text: text,
                    user: self.chatModel.name,
                    isError: false,
                    sentTime: Date()
                )
                self.messages.append(newMessage)
            } else {
                if let index = self.messages.firstIndex(where: { $0.id == messageId }) {
                    self.messages[index].text += text
                }
            }
            
            self.objectWillChange.send()
        }
    }
    
    private func appendThinkingToMessage(_ thinking: String, messageId: UUID, shouldCreateNewMessage: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            var currentThinking: String = ""
            
            if shouldCreateNewMessage {
                let newMessage = MessageData(
                    id: messageId,
                    text: "",
                    thinking: thinking,
                    user: self.chatModel.name,
                    isError: false,
                    sentTime: Date()
                )
                self.messages.append(newMessage)
                currentThinking = thinking
            } else {
                if let index = self.messages.firstIndex(where: { $0.id == messageId }) {
                    self.messages[index].thinking = (self.messages[index].thinking ?? "") + thinking
                    currentThinking = self.messages[index].thinking ?? ""
                }
            }
            
            self.objectWillChange.send()
            
            // Trigger real-time summary generation if enough new content
            let thinkingLength = currentThinking.count
            if thinkingLength - self.lastThinkingSummaryLength >= self.thinkingSummaryThreshold {
                self.lastThinkingSummaryLength = thinkingLength
                self.triggerThinkingSummary(for: messageId, thinking: currentThinking)
            }
        }
    }
    
    /// Trigger thinking summary generation immediately (runs in parallel)
    private func triggerThinkingSummary(for messageId: UUID, thinking: String) {
        // Skip only if thinking is completed (allow parallel execution)
        guard !thinkingCompleted else { return }
        
        // Start new task immediately (parallel, no cancellation of previous)
        Task { [weak self] in
            guard self?.thinkingCompleted != true else { return }
            await self?.generateThinkingSummary(for: messageId, thinking: thinking)
        }
    }
    
    /// Stop thinking summary generation (called when text starts streaming)
    private func stopThinkingSummaryGeneration() {
        thinkingCompleted = true
    }
    
    private func updateMessageText(messageId: UUID, newText: String) {
        // Update UI
        if let index = self.messages.firstIndex(where: { $0.id == messageId }) {
            self.messages[index].text = newText
        }
        
        // Update storage
        chatManager.updateMessageText(
            for: chatId,
            messageId: messageId,
            newText: newText
        )
    }
    
    private func updateMessageVideoUrl(messageId: UUID, videoUrl: URL, s3Uri: String) {
        if let index = self.messages.firstIndex(where: { $0.id == messageId }) {
            var updatedMessage = self.messages[index]
            updatedMessage.videoUrl = videoUrl
            updatedMessage.videoS3Uri = s3Uri
            self.messages[index] = updatedMessage
            logger.info("Updated message \(messageId) with video URL: \(videoUrl.path)")
        }
    }

    private func updateMessageThinking(messageId: UUID, newThinking: String, signature: String? = nil) {
        // Update UI
        if let index = self.messages.firstIndex(where: { $0.id == messageId }) {
            self.messages[index].thinking = newThinking
            if let sig = signature {
                self.messages[index].signature = sig
            }
        }
        
        // Update storage
        chatManager.updateMessageThinking(
            for: chatId,
            messageId: messageId,
            newThinking: newThinking,
            signature: signature
        )
    }

    private func updateMessageWithToolInfo(messageId: UUID, newText: String? = nil, toolInfo: ToolInfo?, toolResult: String? = nil) {
        guard let toolInfo = toolInfo else { return }
        // Update UI
        if let index = self.messages.firstIndex(where: { $0.id == messageId }) {
            if let text = newText {
                self.messages[index].text = text
            }
            self.messages[index].toolUses = [toolInfo]
            if let result = toolResult {
                self.messages[index].toolResults = [ToolResultEntry(
                    toolUseId: toolInfo.id, toolName: toolInfo.name,
                    result: result, status: "success"
                )]
            }
        }

        // Update storage with thinking/signature preserved
        if let index = self.messages.firstIndex(where: { $0.id == messageId }) {
            let currentText = self.messages[index].text
            let currentThinking = self.messages[index].thinking
            let currentSignature = self.messages[index].signature

            chatManager.updateMessageWithToolInfo(
                for: chatId,
                messageId: messageId,
                newText: currentText,
                toolInfo: toolInfo,
                toolResult: toolResult,
                thinking: currentThinking,
                thinkingSignature: currentSignature
            )
        }
    }
    
    // MARK: - Conversation History Management
    
    /// Gets conversation history
    private func getConversationHistory() async -> [BedrockMessage] {
        // Build conversation history from local storage
        if let history = chatManager.getConversationHistory(for: chatId) {
            return convertConversationHistoryToBedrockMessages(history)
        }
        
        // Migrate from legacy formats if needed
        if chatManager.getMessages(for: chatId).count > 0 {
            return await migrateAndGetConversationHistory()
        }
        
        // No history exists
        return []
    }
    
    /// Migrates from legacy formats and returns conversation history
    private func migrateAndGetConversationHistory() async -> [BedrockMessage] {
        // Get messages and convert to unified format
        let messages = chatManager.getMessages(for: chatId)
        
        var bedrockMessages: [BedrockMessage] = []
        
        for message in messages {
            // "User" and "ToolResult" are both user role for API
            let role: MessageRole = (message.user == "User" || message.user == "ToolResult") ? .user : .assistant
            
            var contents: [MessageContent] = []
            
            // Add thinking content if present
            // IMPORTANT: Only include thinking block if we have a valid signature from the API
            // Using a fake/generated signature will cause "Invalid signature in thinking block" error
            if let thinking = message.thinking, !thinking.isEmpty,
               let signature = message.signature, !signature.isEmpty {
                contents.append(.thinking(MessageContent.ThinkingContent(
                    text: thinking,
                    signature: signature
                )))
            }
            
            // Add documents FIRST (before text) to support prompt caching
            if let documentBase64Strings = message.documentBase64Strings,
               let documentFormats = message.documentFormats,
               let documentNames = message.documentNames {
                
                for i in 0..<min(documentBase64Strings.count, min(documentFormats.count, documentNames.count)) {
                    let format = MessageContent.DocumentFormat.fromExtension(documentFormats[i])
                    contents.append(.document(MessageContent.DocumentContent(
                        format: format,
                        base64Data: documentBase64Strings[i],
                        name: documentNames[i]
                    )))
                }
            }
            
            // Add images SECOND (before text) to support prompt caching
            if let imageBase64Strings = message.imageBase64Strings {
                for (index, base64String) in imageBase64Strings.enumerated() {
                    let fileExtension = index < (message.imageFormats?.count ?? 0) ?
                        message.imageFormats![index].lowercased() : "jpeg"
                    let format: ImageFormat
                    switch fileExtension {
                    case "jpg", "jpeg": format = .jpeg
                    case "png": format = .png
                    case "gif": format = .gif
                    case "webp": format = .webp
                    default: format = .jpeg
                    }
                    contents.append(.image(MessageContent.ImageContent(
                        format: format,
                        base64Data: base64String
                    )))
                }
            }

            // Handle tool results specially - they should ONLY contain toolresult, no text
            if role == .user, let toolUses = message.toolUses, let toolResultEntries = message.toolResults,
               !toolUses.isEmpty, !toolResultEntries.isEmpty {
                // Tool result message - add all toolresult content blocks
                for entry in toolResultEntries {
                    contents.append(.toolresult(MessageContent.ToolResultContent(
                        toolUseId: entry.toolUseId,
                        result: entry.result,
                        status: entry.status
                    )))
                }
            } else {
                // Regular message - add text content AFTER documents/images
                var fullText = message.text
                if let pastedTexts = message.pastedTexts, !pastedTexts.isEmpty {
                    for pastedText in pastedTexts {
                        if !fullText.isEmpty {
                            fullText += "\n\n---\n\n"
                        }
                        fullText += "[\(pastedText.filename)]:\n\(pastedText.content)"
                    }
                }
                if !fullText.isEmpty {
                    contents.append(.text(fullText))
                }

                // Add all tool_use blocks if present (for assistant messages)
                if let toolUses = message.toolUses, role == .assistant {
                    for toolInfo in toolUses {
                        contents.append(.tooluse(MessageContent.ToolUseContent(
                            toolUseId: toolInfo.id,
                            name: toolInfo.name,
                            input: toolInfo.input
                        )))
                    }
                }
            }
            
            let bedrockMessage = BedrockMessage(role: role, content: contents)
            bedrockMessages.append(bedrockMessage)
        }
        
        // Save newly converted history
        await saveFromUIMessages()
        
        return bedrockMessages
    }
    
    /// Saves conversation history directly from UI messages
    /// This preserves all UI-specific data like pastedTexts without complex text parsing
    private func saveFromUIMessages() async {
        var newConversationHistory = ConversationHistory(chatId: chatId, modelId: chatModel.id, messages: [])
        logger.debug("[SaveHistory] Saving \(messages.count) messages directly from UI state.")
        
        // Convert MessageData directly to Message for storage
        // This preserves pastedTexts and other UI-specific data
        for messageData in messages {
            // "User" and "ToolResult" are both user role for API
            // "ToolResult" is a special marker for tool results that display on assistant side in UI
            let role: Message.Role = (messageData.user == "User" || messageData.user == "ToolResult") ? .user : .assistant
            
            // Convert ToolInfo array to Message.ToolUse array
            var toolUsesList: [Message.ToolUse]? = nil
            if let toolInfos = messageData.toolUses {
                toolUsesList = toolInfos.map { info in
                    var use = Message.ToolUse(toolId: info.id, toolName: info.name, inputs: info.input)
                    if let entry = messageData.toolResults?.first(where: { $0.toolUseId == info.id }) {
                        use.result = entry.result
                    }
                    return use
                }
            }

            let message = Message(
                id: messageData.id,
                text: messageData.text,
                role: role,
                timestamp: messageData.sentTime,
                isError: messageData.isError,
                thinking: messageData.thinking,
                thinkingSummary: messageData.thinkingSummary,
                thinkingSignature: messageData.signature,
                imageBase64Strings: messageData.imageBase64Strings,
                imageFormats: messageData.imageFormats,
                documentBase64Strings: messageData.documentBase64Strings,
                documentFormats: messageData.documentFormats,
                documentNames: messageData.documentNames,
                pastedTexts: messageData.pastedTexts,
                videoUrl: messageData.videoUrl,
                videoS3Uri: messageData.videoS3Uri,
                toolUses: toolUsesList
            )
            
            newConversationHistory.addMessage(message)
        }
        
        logger.info("[SaveHistory] Saved \(newConversationHistory.messages.count) messages.")
        chatManager.saveConversationHistory(newConversationHistory, for: chatId)
    }
    
    /// Converts a ConversationHistory to Bedrock messages
    private func convertConversationHistoryToBedrockMessages(_ history: ConversationHistory) -> [BedrockMessage] {
        var bedrockMessages: [BedrockMessage] = []
        
        for message in history.messages {
            let role: MessageRole = message.role == .user ? .user : .assistant
            
            var contents: [MessageContent] = []
            
            // Add thinking content if present for assistant messages
            // Skip thinking content for OpenAI models as they don't support signature field
            // IMPORTANT: Only include thinking block if we have a valid signature from the API
            // Using a fake/generated signature will cause "Invalid signature in thinking block" error
            if role == .assistant,
               let thinking = message.thinking, !thinking.isEmpty,
               let signature = message.thinkingSignature, !signature.isEmpty,
               !isOpenAIModel(chatModel.id) {
                contents.append(.thinking(.init(text: thinking, signature: signature)))
            }
            
            // Add documents FIRST (before text) to support prompt caching
            // AWS Bedrock requires cache points to follow text blocks, not document/image blocks
            if let documentBase64Strings = message.documentBase64Strings,
               let documentFormats = message.documentFormats,
               let documentNames = message.documentNames {
                
                for i in 0..<min(documentBase64Strings.count, min(documentFormats.count, documentNames.count)) {
                    let format = MessageContent.DocumentFormat.fromExtension(documentFormats[i])
                    contents.append(.document(MessageContent.DocumentContent(
                        format: format,
                        base64Data: documentBase64Strings[i],
                        name: documentNames[i]
                    )))
                }
            }
            
            // Add images SECOND (before text) to support prompt caching
            if let imageBase64Strings = message.imageBase64Strings {
                for (index, base64String) in imageBase64Strings.enumerated() {
                    let fileExtension = index < (message.imageFormats?.count ?? 0) ?
                        message.imageFormats![index].lowercased() : "jpeg"
                    let format: ImageFormat
                    switch fileExtension {
                    case "jpg", "jpeg": format = .jpeg
                    case "png": format = .png
                    case "gif": format = .gif
                    case "webp": format = .webp
                    default: format = .jpeg
                    }
                    contents.append(.image(MessageContent.ImageContent(
                        format: format,
                        base64Data: base64String
                    )))
                }
            }

            // Handle tool results specially - they should ONLY contain toolresult, no text
            if role == .user, let toolUses = message.toolUses, toolUses.contains(where: { $0.result != nil }) {
                for use in toolUses {
                    if let result = use.result {
                        contents.append(.toolresult(.init(
                            toolUseId: use.toolId,
                            result: result,
                            status: "success"
                        )))
                    }
                }
            } else {
                // Regular message - add text content AFTER documents/images
                var fullText = message.text
                if let pastedTexts = message.pastedTexts, !pastedTexts.isEmpty {
                    for pastedText in pastedTexts {
                        if !fullText.isEmpty {
                            fullText += "\n\n---\n\n"
                        }
                        fullText += "[\(pastedText.filename)]:\n\(pastedText.content)"
                    }
                }
                if !fullText.isEmpty {
                    contents.append(.text(fullText))
                }

                // Handle Tool Use for assistant messages (all tool_use blocks)
                if role == .assistant, let toolUses = message.toolUses {
                    for use in toolUses {
                        contents.append(.tooluse(.init(
                            toolUseId: use.toolId,
                            name: use.toolName,
                            input: use.inputs
                        )))
                    }
                }
            }
            
            bedrockMessages.append(BedrockMessage(role: role, content: contents))
        }
        
        return bedrockMessages
    }
    
    // MARK: - Utility Functions
    
    // Extracts text content from a streaming chunk
    private func extractTextFromChunk(_ chunk: BedrockRuntimeClientTypes.ConverseStreamOutput) -> String? {
        if case .contentblockdelta(let deltaEvent) = chunk,
           let delta = deltaEvent.delta {
            if case .text(let textChunk) = delta {
                return textChunk
            }
        }
        return nil
    }
    
    // Extracts thinking content from a streaming chunk
    private func extractThinkingFromChunk(_ chunk: BedrockRuntimeClientTypes.ConverseStreamOutput) -> (text: String?, signature: String?) {
        var text: String? = nil
        var signature: String? = nil
        
        if case .contentblockdelta(let deltaEvent) = chunk,
           let delta = deltaEvent.delta,
           case .reasoningcontent(let reasoningChunk) = delta {
            
            switch reasoningChunk {
            case .text(let textContent):
                text = textContent
            case .signature(let signatureContent):
                signature = signatureContent
            case .redactedcontent, .sdkUnknown:
                break
            }
        }
        
        return (text, signature)
    }
    
    /// Converts a BedrockMessage to AWS SDK format
    private func convertToBedrockMessage(_ message: BedrockMessage, modelId: String = "") throws -> AWSBedrockRuntime.BedrockRuntimeClientTypes.Message {
        var contentBlocks: [AWSBedrockRuntime.BedrockRuntimeClientTypes.ContentBlock] = []
        
        // Process all content blocks in their original order (no reordering!)
        for content in message.content {
            switch content {
            case .text(let text):
                contentBlocks.append(.text(text))
                
            case .thinking(let thinkingContent):
                // Skip reasoning content for user messages
                // Also skip for DeepSeek models due to a server-side validation error
                // Also skip for OpenAI models that don't support signature field
                if message.role == .user || isDeepSeekModel(modelId) || isOpenAIModel(modelId) {
                    continue
                }
                
                // Add thinking content as a reasoning block
                let reasoningTextBlock = AWSBedrockRuntime.BedrockRuntimeClientTypes.ReasoningTextBlock(
                    signature: thinkingContent.signature,
                    text: thinkingContent.text
                )
                contentBlocks.append(.reasoningcontent(.reasoningtext(reasoningTextBlock)))
                
            case .image(let imageContent):
                // Convert to AWS image format
                let awsFormat: AWSBedrockRuntime.BedrockRuntimeClientTypes.ImageFormat
                switch imageContent.format {
                case .jpeg: awsFormat = .jpeg
                case .png: awsFormat = .png
                case .gif: awsFormat = .gif
                case .webp: awsFormat = .png // Fall back to PNG for WebP
                }
                
                guard let imageData = Data(base64Encoded: imageContent.base64Data) else {
                    logger.error("Failed to decode image base64 string")
                    throw NSError(domain: "ChatViewModel", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "Failed to decode base64 image to data"])
                }
                
                contentBlocks.append(.image(AWSBedrockRuntime.BedrockRuntimeClientTypes.ImageBlock(
                    format: awsFormat,
                    source: .bytes(imageData)
                )))
                
            case .document(let documentContent):
                // Convert to AWS document format
                let docFormat: AWSBedrockRuntime.BedrockRuntimeClientTypes.DocumentFormat
                
                switch documentContent.format {
                case .pdf: docFormat = .pdf
                case .csv: docFormat = .csv
                case .doc: docFormat = .doc
                case .docx: docFormat = .docx
                case .xls: docFormat = .xls
                case .xlsx: docFormat = .xlsx
                case .html: docFormat = .html
                case .txt: docFormat = .txt
                case .md: docFormat = .md
                }
                
                guard let documentData = Data(base64Encoded: documentContent.base64Data) else {
                    logger.error("Failed to decode document base64 string")
                    throw NSError(domain: "ChatViewModel", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "Failed to decode base64 document to data"])
                }
                
                contentBlocks.append(.document(AWSBedrockRuntime.BedrockRuntimeClientTypes.DocumentBlock(
                    format: docFormat,
                    name: documentContent.name,
                    source: .bytes(documentData)
                )))
                
            case .toolresult(let toolResultContent):
                // Convert to AWS tool result format
                let toolResultBlock = AWSBedrockRuntime.BedrockRuntimeClientTypes.ToolResultBlock(
                    content: [.text(toolResultContent.result)],
                    status: toolResultContent.status == "success" ? .success : .error,
                    toolUseId: toolResultContent.toolUseId
                )
                
                contentBlocks.append(.toolresult(toolResultBlock))
                
            case .tooluse(let toolUseContent):
                // Convert to AWS tool use format
                do {
                    // Convert JSONValue input to Smithy Document
                    let swiftInputObject = toolUseContent.input.asAny
                    let inputDocument = try Smithy.Document.make(from: swiftInputObject)
                    
                    let toolUseBlock = AWSBedrockRuntime.BedrockRuntimeClientTypes.ToolUseBlock(
                        input: inputDocument,
                        name: toolUseContent.name,
                        toolUseId: toolUseContent.toolUseId
                    )
                    
                    contentBlocks.append(.tooluse(toolUseBlock))
                    logger.debug("Successfully converted toolUse block for '\(toolUseContent.name)' with input: \(inputDocument)")
                    
                } catch {
                    logger.error("Failed to convert tool use input (\(toolUseContent.input)) to Smithy Document: \(error). Skipping this toolUse block in the request.")
                }
            }
        }
        
        // IMPORTANT: Do NOT reorder content blocks!
        // The order must be preserved to maintain proper tool_use/tool_result pairing
        // Removing all the previous reordering logic that was causing ValidationException
        
        return AWSBedrockRuntime.BedrockRuntimeClientTypes.Message(
            content: contentBlocks,
            role: convertToAWSRole(message.role)
        )
    }
    
    /// Converts MessageRole to AWS SDK role
    private func convertToAWSRole(_ role: MessageRole) -> AWSBedrockRuntime.BedrockRuntimeClientTypes.ConversationRole {
        switch role {
        case .user: return .user
        case .assistant: return .assistant
        }
    }
    
    // MARK: - Image Generation Model Handling
    
    /// Determines if the model ID represents a text generation model that can support streaming
    private func isTextGenerationModel(_ modelId: String) -> Bool {
        let id = modelId.lowercased()
        
        // Special case: check for non-text generation models first
        if id.contains("embed") ||
            id.contains("image") ||
            id.contains("video") ||
            id.contains("stable-") ||
            id.contains("-canvas") ||
            id.contains("titan-embed") ||
            id.contains("titan-e1t") {
            return false
        } else {
            // Text generation models - be more specific with nova to exclude nova-canvas
            let isNova = id.contains("nova") && !id.contains("canvas")
            
            return id.contains("mistral") ||
            id.contains("claude") ||
            id.contains("llama") ||
            isNova ||
            id.contains("titan") ||
            id.contains("deepseek") ||
            id.contains("command") ||
            id.contains("jurassic") ||
            id.contains("jamba") ||
            id.contains("openai")
        }
    }
    
    private func isDeepSeekModel(_ modelId: String) -> Bool {
        return modelId.lowercased().contains("deepseek")
    }
    
    private func isOpenAIModel(_ modelId: String) -> Bool {
        let modelType = backendModel.backend.getModelType(modelId)
        return modelType == .openaiGptOss120b || modelType == .openaiGptOss20b || modelType == .openaiGptOssSafeguard
    }
    
    /// Handles image generation models that don't use converseStream
    private func handleImageGenerationModel(_ userMessage: MessageData, attachedImages: [String] = []) async throws {
        let modelId = chatModel.id
        
        if modelId.contains("nova-reel") {
            try await invokeNovaReelModel(prompt: userMessage.text, inputImages: attachedImages)
        } else if modelId.contains("titan-image") {
            try await invokeTitanImageModel(prompt: userMessage.text)
        } else if modelId.contains("nova-canvas") {
            try await invokeNovaCanvasModel(prompt: userMessage.text, inputImages: attachedImages)
        } else if modelId.contains("stable") || modelId.contains("sd3") {
            try await invokeStableDiffusionModel(prompt: userMessage.text, inputImages: attachedImages)
        } else {
            throw NSError(domain: "ChatViewModel", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported image generation model: \(modelId)"
            ])
        }
    }
    
    /// Invokes Nova Reel video generation model (async - saves to S3)
    private func invokeNovaReelModel(prompt: String, inputImages: [String] = []) async throws {
        let backend = await MainActor.run { backendModel.backend }
        let savedConfig = settingManager.novaReelConfig
        
        // Set loading state for sidebar indicator
        await MainActor.run {
            chatManager.setIsLoading(true, for: chatId)
        }
        
        // Validate S3 bucket
        guard !savedConfig.s3OutputBucket.isEmpty else {
            throw NSError(
                domain: "NovaReel",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "S3 output bucket is required. Please configure it in the Nova Reel settings."]
            )
        }
        
        let validation = NovaReelService.validateS3Uri(savedConfig.s3OutputBucket)
        guard validation.isValid else {
            throw NSError(
                domain: "NovaReel",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: validation.message ?? "Invalid S3 URI"]
            )
        }
        
        let taskType = NovaReelTaskType(rawValue: savedConfig.taskType) ?? .textToVideo
        let videoService = VideoGenerationService(
            bedrockRuntimeClient: backend.bedrockRuntimeClient,
            credentialResolver: backend.awsCredentialIdentityResolver,
            region: backend.region
        )
        
        // Generate unique S3 output path
        let s3OutputPath = NovaReelService.generateS3OutputPath(bucket: savedConfig.s3OutputBucket)
        
        let invocationArn: String
        let durationSeconds: Int
        
        switch taskType {
        case .textToVideo:
            durationSeconds = 6
            invocationArn = try await videoService.startTextToVideo(
                prompt: prompt,
                firstFrameImage: inputImages.first,
                imageFormat: "png",
                seed: savedConfig.seed,
                s3OutputUri: s3OutputPath
            )
            
        case .multiShotAutomated:
            durationSeconds = savedConfig.durationSeconds
            invocationArn = try await videoService.startMultiShotAutomated(
                prompt: prompt,
                durationSeconds: durationSeconds,
                seed: savedConfig.seed,
                s3OutputUri: s3OutputPath
            )
            
        case .multiShotManual:
            let shots = savedConfig.shots.isEmpty ? [prompt] : savedConfig.shots
            durationSeconds = shots.count * 6
            invocationArn = try await videoService.startMultiShotManual(
                shots: shots,
                seed: savedConfig.seed,
                s3OutputUri: s3OutputPath
            )
        }
        
        // Create initial response message
        let estimatedTime = NovaReelService.estimatedTime(durationSeconds: durationSeconds)
        // Nova Reel creates: {s3OutputPath}{invocationId}/output.mp4 (s3OutputPath has trailing slash)
        let invocationId = NovaReelService.extractInvocationId(from: invocationArn) ?? "unknown"
        let videoUri = "\(s3OutputPath)\(invocationId)/output.mp4"
        let messageId = UUID()
        let initialText = """
        **Video Generation Started**
        
        **Task:** \(taskType.displayName)
        **Duration:** \(durationSeconds) seconds
        **Estimated Time:** \(estimatedTime)
        **Output:** `\(videoUri)`
        
        **Job ARN:**
        `\(invocationArn)`
        
        Status: Generating video... Please wait.
        """
        
        let assistantMessage = MessageData(
            id: messageId,
            text: initialText,
            user: chatModel.name,
            isError: false,
            sentTime: Date()
        )
        addMessage(assistantMessage)
        
        // Start polling for completion
        Task {
            await pollVideoGenerationStatus(
                videoService: videoService,
                invocationArn: invocationArn,
                s3OutputPath: s3OutputPath,
                messageId: messageId,
                taskType: taskType,
                durationSeconds: durationSeconds
            )
        }
    }
    
    /// Poll video generation status and update message when complete
    private func pollVideoGenerationStatus(
        videoService: VideoGenerationService,
        invocationArn: String,
        s3OutputPath: String,
        messageId: UUID,
        taskType: NovaReelTaskType,
        durationSeconds: Int
    ) async {
        let maxAttempts = 200  // ~17 minutes max (5s intervals)
        var attempts = 0
        
        while attempts < maxAttempts {
            attempts += 1
            
            do {
                let jobInfo = try await videoService.getJobStatus(invocationArn: invocationArn)
                
                // Nova Reel creates: {s3OutputPath}{invocationId}/output.mp4 (s3OutputPath has trailing slash)
                let invocationId = NovaReelService.extractInvocationId(from: invocationArn) ?? "unknown"
                let videoUri = "\(s3OutputPath)\(invocationId)/output.mp4"
                
                switch jobInfo.jobStatus {
                case .completed:
                    // Try to download video from S3
                    var localVideoUrl: URL?
                    do {
                        localVideoUrl = try await videoService.downloadVideoFromS3(s3Uri: videoUri)
                    } catch {
                        logger.warning("Failed to download video: \(error.localizedDescription)")
                    }
                    
                    // If video downloaded successfully, clear text (video player will show)
                    let completedText: String
                    if localVideoUrl != nil {
                        completedText = ""
                    } else {
                        completedText = """
                        **Video Generation Complete**
                        
                        **Task:** \(taskType.displayName)
                        **Duration:** \(durationSeconds) seconds
                        **Output:** `\(videoUri)`
                        
                        Status: Complete - Video is ready in S3.
                        """
                    }
                    
                    await MainActor.run {
                        // Set video URL first, then update text
                        if let videoUrl = localVideoUrl {
                            updateMessageVideoUrl(messageId: messageId, videoUrl: videoUrl, s3Uri: videoUri)
                        }
                        updateMessageText(messageId: messageId, newText: completedText)
                        chatManager.setIsLoading(false, for: chatId)
                    }
                    await saveFromUIMessages()
                    return
                    
                case .failed:
                    let failedText = """
                    **Video Generation Failed**
                    
                    **Task:** \(taskType.displayName)
                    **Output:** `\(videoUri)`
                    
                    **Job ARN:**
                    `\(invocationArn)`
                    
                    Status: Failed - \(jobInfo.failureMessage ?? "Unknown error")
                    """
                    
                    await MainActor.run {
                        updateMessageText(messageId: messageId, newText: failedText)
                        chatManager.setIsLoading(false, for: chatId)
                    }
                    await saveFromUIMessages()
                    return
                    
                case .inProgress:
                    // Update progress message periodically
                    if attempts % 6 == 0 {  // Every 30 seconds
                        let elapsed = attempts * 5
                        let progressText = """
                        **Video Generation In Progress**
                        
                        **Task:** \(taskType.displayName)
                        **Duration:** \(durationSeconds) seconds
                        **Output:** `\(videoUri)`
                        
                        **Job ARN:**
                        `\(invocationArn)`
                        
                        Status: Generating... (\(elapsed)s elapsed)
                        """
                        
                        await MainActor.run {
                            updateMessageText(messageId: messageId, newText: progressText)
                        }
                    }
                }
            } catch {
                // Log error but continue polling
                print("Error polling video status: \(error.localizedDescription)")
            }
            
            // Wait 5 seconds before next poll
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        
        // Timeout
        let invocationId = NovaReelService.extractInvocationId(from: invocationArn) ?? "unknown"
        let videoUri = "\(s3OutputPath)\(invocationId)/output.mp4"
        let timeoutText = """
        **Video Generation Timeout**
        
        **Task:** \(taskType.displayName)
        **Duration:** \(durationSeconds) seconds
        **Output:** `\(videoUri)`
        
        **Job ARN:**
        `\(invocationArn)`
        
        Status: Timeout - Check the AWS Console for current status.
        """
        
        await MainActor.run {
            updateMessageText(messageId: messageId, newText: timeoutText)
            chatManager.setIsLoading(false, for: chatId)
        }
        await saveFromUIMessages()
    }
    
    /// Handles embedding models by directly parsing JSON responses
    private func handleEmbeddingModel(_ userMessage: MessageData) async throws {
        // Capture backend locally to avoid data races
        let backend = await MainActor.run { backendModel.backend }
        
        // Invoke embedding model to get raw data response
        let responseData = try await backend.invokeEmbeddingModel(
            withId: chatModel.id,
            text: userMessage.text
        )
        
        let modelId = chatModel.id.lowercased()
        var responseText = ""
        
        // Parse JSON data directly
        if let json = try? JSONSerialization.jsonObject(with: responseData, options: []) {
            if modelId.contains("titan-embed") || modelId.contains("titan-e1t") {
                if let jsonDict = json as? [String: Any],
                   let embedding = jsonDict["embedding"] as? [Double] {
                    responseText = embedding.map { "\($0)" }.joined(separator: ",")
                } else {
                    responseText = "Failed to extract Titan embedding data"
                }
            } else if modelId.contains("cohere") {
                if let jsonDict = json as? [String: Any],
                   let embeddings = jsonDict["embeddings"] as? [[Double]],
                   let firstEmbedding = embeddings.first {
                    responseText = firstEmbedding.map { "\($0)" }.joined(separator: ",")
                } else {
                    responseText = "Failed to extract Cohere embedding data"
                }
            } else {
                if let jsonData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    responseText = jsonString
                } else {
                    responseText = "Unknown embedding format"
                }
            }
        } else {
            responseText = String(data: responseData, encoding: .utf8) ?? "Unable to decode response"
        }
        
        // Create response message
        let assistantMessage = MessageData(
            id: UUID(),
            text: responseText,
            user: chatModel.name,
            isError: false,
            sentTime: Date()
        )
        
        // Add message to chat
        addMessage(assistantMessage)
        
        // Save conversation history from UI messages
        await saveFromUIMessages()
    }
    
    /// Invokes Titan Image model
    private func invokeTitanImageModel(prompt: String) async throws {
        let backend = await MainActor.run { backendModel.backend }
        let data = try await backend.invokeImageModel(
            withId: chatModel.id,
            prompt: prompt,
            modelType: .titanImage
        )
        
        try processImageModelResponse(data)
    }
    
    /// Invokes Nova Canvas image model with full feature support
    /// Supports: TEXT_IMAGE, COLOR_GUIDED_GENERATION, IMAGE_VARIATION, INPAINTING, OUTPAINTING, BACKGROUND_REMOVAL
    private func invokeNovaCanvasModel(prompt: String, inputImages: [String] = []) async throws {
        let backend = await MainActor.run { backendModel.backend }
        
        // Get saved config from settings
        let savedConfig = settingManager.novaCanvasConfig
        let configuredTaskType = NovaCanvasTaskType(rawValue: savedConfig.taskType) ?? .textToImage
        
        // Parse the prompt to detect task type override and extract parameters
        let (parsedTaskType, cleanPrompt, parameters) = NovaCanvasService.parsePrompt(prompt)
        
        // Use parsed task type if prompt contains explicit commands, otherwise use configured
        let taskType = parsedTaskType != .textToImage ? parsedTaskType : configuredTaskType
        
        // Extract negative prompt if present (format: "prompt --no negative terms")
        let (finalPrompt, negativePrompt) = NovaCanvasService.extractNegativePrompt(from: cleanPrompt)
        
        // Use saved negative prompt if user didn't specify one
        let effectiveNegativePrompt = negativePrompt ?? (savedConfig.negativePrompt.isEmpty ? nil : savedConfig.negativePrompt)
        
        // Validate requirements for tasks that need input images
        if taskType.requiresInputImage && inputImages.isEmpty {
            throw NSError(
                domain: "NovaCanvas",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "This task requires an input image. Please attach an image to use \(taskType.displayName)."]
            )
        }
        
        // Extract colors if present in parameters
        let colors = parameters["colors"] as? [String] ?? []
        
        // Get mask prompt from user input or saved config
        let userMaskPrompt = extractMaskPrompt(from: prompt)
        let effectiveMaskPrompt = userMaskPrompt ?? (savedConfig.maskPrompt.isEmpty ? nil : savedConfig.maskPrompt)
        
        // Build config from saved settings
        let config = NovaCanvasImageGenerationConfig(
            width: savedConfig.width,
            height: savedConfig.height,
            quality: savedConfig.quality,
            cfgScale: savedConfig.cfgScale,
            seed: savedConfig.seed,  // 0 = random, otherwise fixed seed
            numberOfImages: savedConfig.numberOfImages
        )
        
        // Build request based on task type
        var request: NovaCanvasRequest
        if taskType == .textToImage {
            // Use style for text-to-image
            let style = NovaCanvasStyle(rawValue: savedConfig.style)
            request = .textToImage(
                prompt: finalPrompt,
                negativePrompt: effectiveNegativePrompt,
                style: style,
                conditionImage: inputImages.first,
                config: config
            )
        } else {
            request = NovaCanvasService.buildRequest(
                taskType: taskType,
                prompt: finalPrompt,
                negativePrompt: effectiveNegativePrompt,
                inputImages: inputImages,
                maskPrompt: effectiveMaskPrompt,
                colors: colors,
                config: config
            )
        }
        
        // Invoke Nova Canvas
        let data = try await backend.invokeNovaCanvas(request: request)
        
        try processImageModelResponse(data)
    }
    
    /// Extract mask prompt from user input (format: "[mask: description]")
    private func extractMaskPrompt(from prompt: String) -> String? {
        let pattern = "\\[mask:\\s*([^\\]]+)\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)),
              let range = Range(match.range(at: 1), in: prompt) else {
            return nil
        }
        return String(prompt[range]).trimmingCharacters(in: .whitespaces)
    }
    
    /// Get attached images from current context as base64 strings
    private func getAttachedImagesBase64() async -> [String] {
        var base64Images: [String] = []
        
        for (index, image) in sharedMediaDataSource.images.enumerated() {
            let fileExtension = index < sharedMediaDataSource.imageExtensions.count ?
                sharedMediaDataSource.imageExtensions[index] : "jpg"
            
            let result = base64EncodeImage(image, withExtension: fileExtension)
            if let base64 = result.base64String {
                base64Images.append(base64)
            }
        }
        
        return base64Images
    }
    
    /// Invokes Stability AI image models (Stable Image Ultra, SD3 Large, Stable Image Core)
    /// Also handles Stability AI Image Services (Upscale, Edit, Control)
    /// Note: Only SD3 Large supports image-to-image mode. Ultra and Core are text-to-image only.
    private func invokeStableDiffusionModel(prompt: String, inputImages: [String] = []) async throws {
        let backend = await MainActor.run { backendModel.backend }
        let modelId = chatModel.id
        
        // Check if this is a Stability AI Image Service
        if let service = StabilityAIImageService.allCases.first(where: { modelId.contains($0.modelId) || $0.modelId == modelId }) {
            try await invokeStabilityAIImageService(service: service, prompt: prompt, inputImages: inputImages)
            return
        }
        
        // Get saved config to check task type
        let savedConfig = settingManager.stabilityAIConfig
        let taskType = StabilityAITaskType(rawValue: savedConfig.taskType) ?? .textToImage
        
        // Check if model supports image-to-image
        // Only SD3 Large (sd3-5-large) supports image-to-image mode
        // Stable Image Ultra and Core do NOT support image-to-image
        let supportsImageToImage = modelId.contains("sd3-5-large") || modelId.contains("sd3-large")
        
        // Determine if we should use image-to-image mode
        let useImageToImage = taskType == .imageToImage && !inputImages.isEmpty && supportsImageToImage
        
        // Warn user if they selected image-to-image but model doesn't support it
        if taskType == .imageToImage && !inputImages.isEmpty && !supportsImageToImage {
            // Fall back to text-to-image with a warning in the response
            let modelName = modelId.contains("ultra") ? "Stable Image Ultra" :
                           modelId.contains("core") ? "Stable Image Core" : "this model"
            throw NSError(
                domain: "StabilityAI",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "\(modelName) does not support image-to-image mode. Please use SD3 Large for image-to-image, or switch to Text to Image mode."]
            )
        }
        
        if useImageToImage {
            // Validate that we have an input image for image-to-image
            guard let inputImage = inputImages.first else {
                throw NSError(
                    domain: "StabilityAI",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Image-to-image mode requires an input image. Please attach an image."]
                )
            }
            
            // Use ImageGenerationService for image-to-image
            let imageService = ImageGenerationService(bedrockRuntimeClient: backend.bedrockRuntimeClient)
            let data = try await imageService.invokeStabilityAIImageToImage(
                modelId: modelId,
                prompt: prompt,
                inputImage: inputImage
            )
            try processImageModelResponse(data)
        } else {
            // Text-to-image mode
            let data = try await backend.invokeImageModel(
                withId: modelId,
                prompt: prompt,
                modelType: .stableDiffusion
            )
            try processImageModelResponse(data)
        }
    }
    
    /// Invokes Stability AI Image Services (Upscale, Edit, Control)
    private func invokeStabilityAIImageService(service: StabilityAIImageService, prompt: String, inputImages: [String]) async throws {
        let backend = await MainActor.run { backendModel.backend }
        
        // Validate input image requirement
        if service.requiresImage && inputImages.isEmpty {
            throw NSError(
                domain: "StabilityAI",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "\(service.displayName) requires an input image. Please attach an image."]
            )
        }
        
        // For style transfer, we need two images
        var styleImage: String? = nil
        if service == .styleTransfer {
            if inputImages.count < 2 {
                throw NSError(
                    domain: "StabilityAI",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Style Transfer requires two images: init_image (first) and style_image (second). Please attach both images."]
                )
            }
            styleImage = inputImages[1]
        }
        
        let imageService = ImageGenerationService(bedrockRuntimeClient: backend.bedrockRuntimeClient)
        let data = try await imageService.invokeStabilityAIService(
            service: service,
            prompt: prompt,
            inputImage: inputImages.first ?? "",
            maskImage: nil,  // TODO: Support mask image input
            styleImage: styleImage
        )
        
        try processImageModelResponse(data)
    }
    
    /// Process and display image data from image generation models
    /// Uses efficient file-based storage to avoid bloating conversation history
    private func processImageModelResponse(_ data: Data) throws {
        // Save image to file storage and get reference ID (img_xxx format)
        // This avoids storing large base64 strings in conversation history JSON
        let imageReference = ImageStorageManager.shared.saveImage(data)
        
        // Use the file reference directly in imageBase64Strings
        // The NSImage extension and LazyImageView handle loading from file references
        // This prevents double-saving in convertImagesToReferences (it skips img_ prefixed strings)
        let imageMessage = MessageData(
            id: UUID(),
            text: "",  // No markdown needed - image is in imageBase64Strings
            user: chatModel.name,
            isError: false,
            sentTime: Date(),
            imageBase64Strings: [imageReference]  // Use file reference directly
        )
        addMessage(imageMessage)
        
        // Update history with reference (not full base64)
        var history = chatManager.getHistory(for: chatId)
        history += "\nAssistant: [Generated Image: \(imageReference)]\n"
        chatManager.setHistory(history, for: chatId)
    }
    
    // MARK: - Basic Message Operations
    
    func addMessage(_ message: MessageData) {
        // Check if we're updating an existing message (for streaming)
        if let id = currentStreamingMessageId,
           message.id == id,
           let index = messages.firstIndex(where: { $0.id == id }) {
            // Update existing message
            messages[index] = message
        } else {
            // Add as new message
            messages.append(message)
        }
        
        // Convert MessageData to Message struct
        let convertedMessage = Message(
            id: message.id,
            text: message.text,
            role: message.user == "User" ? .user : .assistant,
            timestamp: message.sentTime,
            isError: message.isError,
            thinking: message.thinking,
            thinkingSignature: message.signature,
            // Convert base64 images to file references for efficient storage
            imageBase64Strings: convertImagesToReferences(message.imageBase64Strings),
            imageFormats: message.imageFormats,
            documentBase64Strings: message.documentBase64Strings,
            documentFormats: message.documentFormats,
            documentNames: message.documentNames,
            toolUses: message.toolUses?.map { info in
                var use = Message.ToolUse(toolId: info.id, toolName: info.name, inputs: info.input)
                if let entry = message.toolResults?.first(where: { $0.toolUseId == info.id }) {
                    use.result = entry.result
                }
                return use
            }
        )
        
        // Add to chat manager
        chatManager.addMessage(convertedMessage, to: chatId)
    }
    
    /// Convert base64 image strings to file references for efficient storage
    /// This prevents conversation history JSON from becoming too large
    private func convertImagesToReferences(_ base64Strings: [String]?) -> [String]? {
        guard let strings = base64Strings, !strings.isEmpty else { return nil }
        
        return strings.map { base64 in
            // Skip if already a file reference
            if ImageStorageManager.isFileReference(base64) {
                return base64
            }
            
            // Convert base64 to file and return reference
            guard let data = Data(base64Encoded: base64) else {
                return base64  // Keep original if decode fails
            }
            
            return ImageStorageManager.shared.saveImage(data)
        }
    }
    
    private func handleModelError(_ error: Error) async {
        logger.error("Error invoking the model: \(error)")
        let errorMessage = MessageData(
            id: UUID(),
            text: "Error invoking the model: \(error)",
            user: "System",
            isError: true,
            sentTime: Date()
        )
        addMessage(errorMessage)
    }
    
    /// Encodes an image to Base64.
    func base64EncodeImage(_ image: NSImage, withExtension fileExtension: String) -> (base64String: String?, mediaType: String?) {
        guard let tiffRepresentation = image.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffRepresentation) else {
            return (nil, nil)
        }
        
        let imageData: Data?
        let mediaType: String
        
        switch fileExtension.lowercased() {
        case "jpg", "jpeg":
            imageData = bitmapImage.representation(using: .jpeg, properties: [:])
            mediaType = "image/jpeg"
        case "png":
            imageData = bitmapImage.representation(using: .png, properties: [:])
            mediaType = "image/png"
        case "webp":
            imageData = nil
            mediaType = "image/webp"
        case "gif":
            imageData = nil
            mediaType = "image/gif"
        default:
            return (nil, nil)
        }
        
        guard let data = imageData else {
            return (nil, nil)
        }
        
        return (data.base64EncodedString(), mediaType)
    }
    
    /// Updates the chat title with a summary of the input.
    func updateChatTitle(with input: String) async {
        // Skip auto title generation if chat was manually renamed
        if chatModel.isManuallyRenamed {
            return
        }
        let summaryPrompt = """
        Summarize user input <input>\(input)</input> as short as possible. Just in few words without punctuation. It should not be more than 5 words. Do as best as you can. please do summary this without punctuation:
        """
        
        // Create message for converseStream
        let userMsg = BedrockMessage(
            role: .user,
            content: [.text(summaryPrompt)]
        )
        
        // Select model for title generation with fallback
        let preferredModelId = "global.anthropic.claude-haiku-4-5-20251001-v1:0"
        let fallbackModelId = "us.amazon.nova-pro-v1:0"
        
        // Check if preferred model is available, otherwise use fallback
        let availableModelIds = SettingManager.shared.availableModels.map { $0.id }
        let titleModelId = availableModelIds.contains(preferredModelId) ? preferredModelId : fallbackModelId
        
        do {
            // Convert to AWS SDK format
            let awsMessage = try convertToBedrockMessage(userMsg)
            
            // Use converseStream API to get the title
            var title = ""
            
            let systemContentBlocks: [BedrockRuntimeClientTypes.SystemContentBlock]? = nil
            let backend = await MainActor.run { backendModel.backend }
            
            for try await chunk in try await backend.converseStream(
                withId: titleModelId,
                messages: [awsMessage],
                systemContent: systemContentBlocks,
                inferenceConfig: nil,
                usageHandler: { @Sendable usage in
                    // Title generation usage info
                    print("Title generation usage - Input: \(usage.inputTokens ?? 0), Output: \(usage.outputTokens ?? 0)")
                }
            ) {
                if let textChunk = extractTextFromChunk(chunk) {
                    title += textChunk
                }
            }
            
            // Update chat title with the generated summary
            if !title.isEmpty {
                chatManager.updateChatTitle(
                    for: chatModel.chatId,
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        } catch {
            logger.error("Error updating chat title: \(error)")
        }
    }
    
    // MARK: - Thinking Summary Generation
    
    /// Generate a brief summary of the thinking process using a lightweight model
    private func generateThinkingSummary(for messageId: UUID, thinking: String) async {
        // Skip if thinking is already completed
        guard !thinkingCompleted else { return }
        
        // Truncate thinking if too long (keep first 1500 chars for faster summary)
        let truncatedThinking = thinking.count > 1500 ? String(thinking.prefix(1500)) + "..." : thinking
        
        let summaryPrompt = """
        Summarize this AI thinking in max 10 words. Be concise:
        
        <thinking>
        \(truncatedThinking)
        </thinking>
        """
        
        // Create message for converseStream
        let userMsg = BedrockMessage(
            role: .user,
            content: [.text(summaryPrompt)]
        )
        
        // Select model for summary generation with fallback
        let preferredModelId = "global.anthropic.claude-haiku-4-5-20251001-v1:0"
        let fallbackModelId = "us.amazon.nova-pro-v1:0"
        
        // Check if preferred model is available, otherwise use fallback
        let availableModelIds = await MainActor.run { SettingManager.shared.availableModels.map { $0.id } }
        let summaryModelId = availableModelIds.contains(preferredModelId) ? preferredModelId : fallbackModelId
        
        do {
            // Convert to AWS SDK format
            let awsMessage = try convertToBedrockMessage(userMsg)
            
            // Use converseStream API to get the summary
            var summary = ""
            
            let systemContentBlocks: [BedrockRuntimeClientTypes.SystemContentBlock]? = nil
            let backend = await MainActor.run { backendModel.backend }
            
            for try await chunk in try await backend.converseStream(
                withId: summaryModelId,
                messages: [awsMessage],
                systemContent: systemContentBlocks,
                inferenceConfig: BedrockRuntimeClientTypes.InferenceConfiguration(
                    maxTokens: 50,
                    temperature: 0.3
                ),
                usageHandler: { @Sendable _ in }
            ) {
                if let textChunk = extractTextFromChunk(chunk) {
                    summary += textChunk
                }
            }
            
            // Update message with thinking summary (only if thinking not completed)
            if !summary.isEmpty && !thinkingCompleted {
                let cleanedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run { [weak self] in
                    guard let self = self, !self.thinkingCompleted else { return }
                    if let index = self.messages.firstIndex(where: { $0.id == messageId }) {
                        self.messages[index].thinkingSummary = cleanedSummary
                        self.objectWillChange.send()
                    }
                }
                logger.info("Generated thinking summary: \(cleanedSummary)")
            }
        } catch {
            logger.error("Error generating thinking summary: \(error)")
        }
    }
    
    // MARK: - Non-Streaming Text LLM Handling
    
    private func handleTextLLMWithNonStreaming(_ userMessage: MessageData) async throws {
        // Create message content from user message (similar to streaming version)
        var messageContents: [MessageContent] = []
        
        // Always include a text prompt as required when sending documents
        let textToSend = userMessage.text.isEmpty &&
        (userMessage.documentBase64Strings?.isEmpty == false) ?
        "Please analyze this document." : userMessage.text
        messageContents.append(.text(textToSend))
        
        // Add images if present
        if let imageBase64Strings = userMessage.imageBase64Strings, !imageBase64Strings.isEmpty {
            for (index, base64String) in imageBase64Strings.enumerated() {
                let fileExtension = index < (userMessage.imageFormats?.count ?? 0) ?
                    userMessage.imageFormats![index].lowercased() : "jpeg"

                let format: ImageFormat
                switch fileExtension {
                case "jpg", "jpeg": format = .jpeg
                case "png": format = .png
                case "gif": format = .gif
                case "webp": format = .webp
                default: format = .jpeg
                }

                messageContents.append(.image(MessageContent.ImageContent(
                    format: format,
                    base64Data: base64String
                )))
            }
        }
        
        // Add documents if present
        if let documentBase64Strings = userMessage.documentBase64Strings,
           let documentFormats = userMessage.documentFormats,
           let documentNames = userMessage.documentNames,
           !documentBase64Strings.isEmpty {
            
            for (index, base64String) in documentBase64Strings.enumerated() {
                guard index < documentFormats.count && index < documentNames.count else {
                    continue
                }
                
                let fileExt = documentFormats[index].lowercased()
                let fileName = documentNames[index]
                
                let docFormat = MessageContent.DocumentFormat.fromExtension(fileExt)
                messageContents.append(.document(MessageContent.DocumentContent(
                    format: docFormat,
                    base64Data: base64String,
                    name: fileName
                )))
            }
        }

        // Save current messages first, then get conversation history
        await saveFromUIMessages()
        let conversationHistory = await getConversationHistory()
        
        // Get system prompt
        let systemPrompt = settingManager.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Get tool configurations if MCP is enabled (but disable for non-streaming for now)
        let toolConfig: AWSBedrockRuntime.BedrockRuntimeClientTypes.ToolConfiguration? = nil
        
        // Get Bedrock messages in AWS SDK format
        let bedrockMessages = try conversationHistory.map { try convertToBedrockMessage($0, modelId: chatModel.id) }
        
        // Convert to system prompt format used by AWS SDK
        let systemContentBlock: [AWSBedrockRuntime.BedrockRuntimeClientTypes.SystemContentBlock]? =
        systemPrompt.isEmpty ? nil : [.text(systemPrompt)]
        
        logger.info("Starting non-streaming converse request with model ID: \(chatModel.id)")
        
        // Capture backend locally to avoid data races
        let backend = await MainActor.run { backendModel.backend }
        
        // Use the non-streaming Converse API
        let request = AWSBedrockRuntime.ConverseInput(
            inferenceConfig: nil,
            messages: bedrockMessages,
            modelId: chatModel.id,
            system: backend.isSystemPromptSupported(chatModel.id) ? systemContentBlock : nil,
            toolConfig: toolConfig
        )
        
        let response = try await backend.bedrockRuntimeClient.converse(input: request)
        
        // Process the response
        var responseText = ""
        var thinking: String? = nil
        var thinkingSignature: String? = nil
        
        if let output = response.output {
            switch output {
            case .message(let message):
                for content in message.content ?? [] {
                    switch content {
                    case .text(let text):
                        responseText += text
                    case .reasoningcontent(let reasoning):
                        switch reasoning {
                        case .reasoningtext(let reasoningText):
                            thinking = (thinking ?? "") + (reasoningText.text ?? "")
                            if thinkingSignature == nil {
                                thinkingSignature = reasoningText.signature
                            }
                        default:
                            break
                        }
                    default:
                        break
                    }
                }
            case .sdkUnknown(let unknownValue):
                logger.warning("Unknown output type received: \(unknownValue)")
            }
        }
        
        // Create assistant message
        let assistantMessage = MessageData(
            id: UUID(),
            text: responseText,
            thinking: thinking,
            signature: thinkingSignature,
            user: chatModel.name,
            isError: false,
            sentTime: Date()
        )
        addMessage(assistantMessage)
        
        // Save conversation history from UI messages
        // This preserves all tool_use/tool_result information correctly
        await saveFromUIMessages()
    }
}
