# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A native macOS SwiftUI application (Swift 6, macOS 14+) that provides a desktop client for Amazon Bedrock's AI models. Uses the AWS SDK for Swift to call Bedrock's ConverseStream API with support for streaming, multi-modal content, MCP tools, image/video generation, and system-wide quick access via a global hotkey.

## Build

Open and build in Xcode:
```bash
open "Amazon Bedrock Client for Mac.xcodeproj"
```

CLI build (used in CI):
```bash
xcodebuild clean build \
  -project "Amazon Bedrock Client for Mac.xcodeproj" \
  -scheme "Amazon Bedrock Client for Mac" \
  -configuration Release \
  -arch x86_64 -arch arm64 \
  -derivedDataPath DerivedData \
  -skipMacroValidation
```

## Testing

Run the test suite from Xcode (Product → Test) or via CLI:
```bash
xcodebuild test \
  -project "Amazon Bedrock Client for Mac.xcodeproj" \
  -scheme "Amazon Bedrock Client for Mac" \
  -destination "platform=macOS"
```

The test files live under `Amazon Bedrock Client for Mac/Tests/`. The primary test file is `MCPServerTests.swift`, which tests MCP server connectivity and OAuth metadata discovery.

## Architecture

### Layer structure
```
Core/           – App entry point, AppDelegate, CoreData stack, hotkey shortcuts
Managers/       – All business logic and services (singletons + ObservableObjects)
Models/         – Data models (ChatModel, Message, ConversationHistory, AWS-specific models)
Views/          – SwiftUI views
Utils/          – Helpers (Markdown rendering, NSImage extensions, search engine)
```

### Key singletons / managers
- **`SettingManager`** (`Managers/SettingManager.swift`) – Single source of truth for all user preferences, AWS credentials config (region, profile, endpoint). Most managers observe this via Combine.
- **`BackendModel`** (`Managers/BedrockClient.swift`) – Owns the `Backend` object (which wraps `BedrockClient` + `BedrockRuntimeClient`). Recreates the backend when `SettingManager` settings change.
- **`Backend`** (`Managers/BedrockClient.swift`) – Wraps the AWS SDK clients. Credential resolution order: named profile → default profile → `DefaultAWSCredentialIdentityResolverChain`.
- **`ChatManager`** (`Managers/ChatManager.swift`) – Manages all chat sessions and conversation history. Persists via CoreData (`CoreDataStack`).
- **`MCPManager`** (`Managers/MCPManager.swift`) – Manages Model Context Protocol server connections, tool discovery, and execution. Configuration stored in `mcp_config.json`.
- **`AppCoordinator`** (`Managers/AppCoordinator.swift`) – Bridges Quick Access window events to the main chat view.
- **`QuickAccessWindowManager`** / **`HotkeyManager`** – Manage the system-wide Option+Space overlay window.

### Data flow
`MainView` owns `BackendModel` + `ChatManager` as `@StateObject`. `SettingManager.shared` is injected as `@EnvironmentObject`. When AWS settings change, `BackendModel` recreates its `Backend`, which triggers `MainView.onChange(of: backendModel.backend)` → `fetchModels()`.

### Message model
`Message` (in `ChatManager.swift`) is the core data structure. It supports text, thinking/reasoning blocks, images, documents, pasted text, tool use (`ToolUse`), and video output. `ConversationHistory` groups messages per chat session.

### Image / Video generation
Handled by separate services: `ImageGenerationService` (Nova Canvas, Titan Image, Stability AI) and `VideoGenerationService` (Nova Reel, async with S3 output). Models/payloads are in `Models/NovaCanvas*`, `Models/TitanImage*`, `Models/StabilityAI*`, `Models/NovaReel*`.

### Swift concurrency
The project uses Swift 6 strict concurrency. Most manager classes are `@MainActor`. The `Backend` and `Message` types are `@unchecked Sendable`.

## Dependencies

Dependencies are managed as Swift Package Manager packages referenced directly in the Xcode project (no `Package.swift` at root). Key packages:
- **AWS SDK for Swift** – `AWSBedrock`, `AWSBedrockRuntime`, `AWSSSO`, `AWSSSOOIDC`, `AWSSDKIdentity`
- **MCP** – Model Context Protocol Swift client
- **swift-log** – Logging (`import Logging`)

## CI/CD

GitHub Actions workflow (`.github/workflows/macos_build.yml`) builds on macOS 26 / Xcode 26, signs with Developer ID, notarizes, packages as DMG, and on version tags creates a GitHub Release and bumps the Homebrew cask (`didhd/tap/amazon-bedrock-client`). Build number is set from the first 8 chars of the commit SHA.
