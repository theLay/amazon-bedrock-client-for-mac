//
//  MessageData.swift
//  Amazon Bedrock Client for Mac
//
//  Created by Na, Sanghwa on 2023/10/06.
//

import Foundation
import SwiftUI

/**
 * Tool information structure supporting complex JSON input
 */
struct ToolInfo: Codable, Equatable {
    let id: String
    let name: String
    let input: JSONValue

    enum CodingKeys: String, CodingKey {
        case id, name, input
    }

    static func == (lhs: ToolInfo, rhs: ToolInfo) -> Bool {
        return lhs.id == rhs.id &&
               lhs.name == rhs.name &&
               lhs.input == rhs.input
    }
}

/**
 * Result entry for a single tool execution within a parallel batch.
 */
struct ToolResultEntry: Codable, Equatable {
    let toolUseId: String
    let toolName: String
    let result: String
    let status: String  // "success", "error", "running"

    static func == (lhs: ToolResultEntry, rhs: ToolResultEntry) -> Bool {
        return lhs.toolUseId == rhs.toolUseId &&
               lhs.toolName == rhs.toolName &&
               lhs.result == rhs.result &&
               lhs.status == rhs.status
    }
}

/**
 * JSON value representation supporting nested structures
 */
enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null
    
    // Custom decoding
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if container.decodeNil() {
            self = .null
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode JSON value"
            )
        }
    }
    
    // Custom encoding
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
    
    // Helper to create from Any
    static func from(_ value: Any) -> JSONValue {
        switch value {
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if number.isBool {
                return .bool(number.boolValue)
            } else {
                return .number(number.doubleValue)
            }
        case let dict as [String: Any]:
            var result = [String: JSONValue]()
            for (key, value) in dict {
                result[key] = JSONValue.from(value)
            }
            return .object(result)
        case let array as [Any]:
            return .array(array.map(JSONValue.from))
        default:
            return .null
        }
    }
    
    // Helper to convert to dictionary for tool execution
    var asDictionary: [String: Any]? {
        if case .object(let dict) = self {
            var result = [String: Any]()
            for (key, value) in dict {
                result[key] = value.asAny
            }
            return result
        }
        return nil
    }
    
    // Helper to convert to Any
    var asAny: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .null: return NSNull()
        case .array(let values):
            return values.map { $0.asAny }
        case .object(let dict):
            var result = [String: Any]()
            for (key, value) in dict {
                result[key] = value.asAny
            }
            return result
        }
    }
}

// Extension to NSNumber to help distinguish between number and boolean
private extension NSNumber {
    var isBool: Bool {
        return CFBooleanGetTypeID() == CFGetTypeID(self as CFTypeRef)
    }
}

/**
 * Represents a message in the chat conversation.
 * Includes support for text content, thinking steps, tool usage, and image/document attachments.
 */
struct MessageData: Identifiable, Equatable, Codable {
    var id = UUID()
    var text: String // Changed to var to allow modification
    var thinking: String?
    var thinkingSummary: String?  // Summary of thinking process for display
    var signature: String?
    var user: String
    var isError: Bool = false
    let sentTime: Date
    var imageBase64Strings: [String]?
    var imageFormats: [String]?
    var documentBase64Strings: [String]?
    var documentFormats: [String]?
    var documentNames: [String]?
    var pastedTexts: [PastedTextInfo]?  // Pasted text attachments (sent as text block, not document)
    var toolUses: [ToolInfo]?  // Information about tool usage(s) in this message (supports parallel)
    var toolResults: [ToolResultEntry]?  // Results from tool execution(s)
    var videoUrl: URL?  // Local URL for generated video playback
    var videoS3Uri: String?  // S3 URI for video (for reference)

    init(
        id: UUID = UUID(),
        text: String,
        thinking: String? = nil,
        thinkingSummary: String? = nil,
        signature: String? = nil,
        user: String,
        isError: Bool = false,
        sentTime: Date,
        imageBase64Strings: [String]? = nil,
        imageFormats: [String]? = nil,
        documentBase64Strings: [String]? = nil,
        documentFormats: [String]? = nil,
        documentNames: [String]? = nil,
        pastedTexts: [PastedTextInfo]? = nil,
        toolUses: [ToolInfo]? = nil,
        toolResults: [ToolResultEntry]? = nil,
        videoUrl: URL? = nil,
        videoS3Uri: String? = nil
    ) {
        self.id = id
        self.text = text
        self.thinking = thinking
        self.thinkingSummary = thinkingSummary
        self.signature = signature
        self.user = user
        self.isError = isError
        self.sentTime = sentTime
        self.imageBase64Strings = imageBase64Strings
        self.imageFormats = imageFormats
        self.documentBase64Strings = documentBase64Strings
        self.documentFormats = documentFormats
        self.documentNames = documentNames
        self.pastedTexts = pastedTexts
        self.toolUses = toolUses
        self.toolResults = toolResults
        self.videoUrl = videoUrl
        self.videoS3Uri = videoS3Uri
    }

    // Convenience: first tool use (backward compat for single-tool code paths)
    var toolUse: ToolInfo? {
        get { toolUses?.first }
        set {
            if let v = newValue {
                if toolUses != nil, !toolUses!.isEmpty {
                    toolUses![0] = v
                } else {
                    toolUses = [v]
                }
            } else {
                toolUses = nil
            }
        }
    }

    // Convenience: first tool result text (backward compat)
    var toolResult: String? {
        get { toolResults?.first?.result }
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case text
        case thinking
        case thinkingSummary = "thinking_summary"
        case signature
        case user
        case isError = "is_error"
        case sentTime = "sent_time"
        case imageBase64Strings = "image_base64_strings"
        case imageFormats = "image_formats"
        case documentBase64Strings = "document_base64_strings"
        case documentFormats = "document_formats"
        case documentNames = "document_names"
        case pastedTexts = "pasted_texts"
        case toolUses = "tool_uses"
        case toolResults = "tool_results"
        case videoUrl = "video_url"
        case videoS3Uri = "video_s3_uri"
        // Legacy keys for backward compatibility
        case legacyToolUse = "tool_use"
        case legacyToolResult = "tool_result"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try container.decode(String.self, forKey: .text)
        thinking = try container.decodeIfPresent(String.self, forKey: .thinking)
        thinkingSummary = try container.decodeIfPresent(String.self, forKey: .thinkingSummary)
        signature = try container.decodeIfPresent(String.self, forKey: .signature)
        user = try container.decode(String.self, forKey: .user)
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        sentTime = try container.decode(Date.self, forKey: .sentTime)
        imageBase64Strings = try container.decodeIfPresent([String].self, forKey: .imageBase64Strings)
        imageFormats = try container.decodeIfPresent([String].self, forKey: .imageFormats)
        documentBase64Strings = try container.decodeIfPresent([String].self, forKey: .documentBase64Strings)
        documentFormats = try container.decodeIfPresent([String].self, forKey: .documentFormats)
        documentNames = try container.decodeIfPresent([String].self, forKey: .documentNames)
        pastedTexts = try container.decodeIfPresent([PastedTextInfo].self, forKey: .pastedTexts)
        videoUrl = try container.decodeIfPresent(URL.self, forKey: .videoUrl)
        videoS3Uri = try container.decodeIfPresent(String.self, forKey: .videoS3Uri)

        // Decode toolUses: try new array format first, fall back to legacy single ToolInfo
        if let uses = try container.decodeIfPresent([ToolInfo].self, forKey: .toolUses) {
            toolUses = uses
        } else if let single = try container.decodeIfPresent(ToolInfo.self, forKey: .legacyToolUse) {
            toolUses = [single]
        } else {
            toolUses = nil
        }

        // Decode toolResults: try new array format first, fall back to legacy single String
        if let results = try container.decodeIfPresent([ToolResultEntry].self, forKey: .toolResults) {
            toolResults = results
        } else if let singleResult = try container.decodeIfPresent(String.self, forKey: .legacyToolResult),
                  let firstTool = toolUses?.first {
            toolResults = [ToolResultEntry(
                toolUseId: firstTool.id,
                toolName: firstTool.name,
                result: singleResult,
                status: "success"
            )]
        } else {
            toolResults = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(thinking, forKey: .thinking)
        try container.encodeIfPresent(thinkingSummary, forKey: .thinkingSummary)
        try container.encodeIfPresent(signature, forKey: .signature)
        try container.encode(user, forKey: .user)
        try container.encode(isError, forKey: .isError)
        try container.encode(sentTime, forKey: .sentTime)
        try container.encodeIfPresent(imageBase64Strings, forKey: .imageBase64Strings)
        try container.encodeIfPresent(imageFormats, forKey: .imageFormats)
        try container.encodeIfPresent(documentBase64Strings, forKey: .documentBase64Strings)
        try container.encodeIfPresent(documentFormats, forKey: .documentFormats)
        try container.encodeIfPresent(documentNames, forKey: .documentNames)
        try container.encodeIfPresent(pastedTexts, forKey: .pastedTexts)
        try container.encodeIfPresent(toolUses, forKey: .toolUses)
        try container.encodeIfPresent(toolResults, forKey: .toolResults)
        try container.encodeIfPresent(videoUrl, forKey: .videoUrl)
        try container.encodeIfPresent(videoS3Uri, forKey: .videoS3Uri)
    }

    static func == (lhs: MessageData, rhs: MessageData) -> Bool {
        return lhs.id == rhs.id &&
               lhs.text == rhs.text &&
               lhs.thinking == rhs.thinking &&
               lhs.thinkingSummary == rhs.thinkingSummary &&
               lhs.toolUses == rhs.toolUses &&
               lhs.toolResults == rhs.toolResults &&
               lhs.user == rhs.user &&
               lhs.isError == rhs.isError &&
               lhs.sentTime == rhs.sentTime &&
               lhs.documentBase64Strings == rhs.documentBase64Strings &&
               lhs.documentFormats == rhs.documentFormats &&
               lhs.documentNames == rhs.documentNames &&
               lhs.pastedTexts == rhs.pastedTexts &&
               lhs.videoUrl == rhs.videoUrl &&
               lhs.videoS3Uri == rhs.videoS3Uri
    }
}

/// Pasted text information for UI display
struct PastedTextInfo: Codable, Equatable, Identifiable {
    var id = UUID()
    let filename: String
    let content: String
    
    var preview: String {
        let truncated = String(content.prefix(150))
        let cleaned = truncated
            .split(separator: "\n", omittingEmptySubsequences: false)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.count > 100 ? String(cleaned.prefix(97)) + "..." : cleaned
    }
}
