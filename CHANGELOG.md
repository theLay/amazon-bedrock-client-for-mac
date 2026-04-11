# Changelog

All notable changes to this project are documented here.

## [Unreleased] (fork: theLay)

### New Features
- **Parallel MCP tool execution** — When the model requests multiple tools in a single response, they are now executed concurrently with real-time per-tool status display (running / success / error) in the chat UI ([PR #2](https://github.com/theLay/amazon-bedrock-client-for-mac/pull/2))
- **Claude Sonnet 4.6 & Opus 4.6 model support** — Added model detection, inference configs, and capability flags for the latest Anthropic models

### Bug Fixes
- **Image format preservation** — Fixed PNG images being incorrectly sent as JPEG through the message pipeline, causing Bedrock API errors
- **MCP tool content handling** — Updated `Tool.Content` switch cases to match MCP library API changes
- **Tool call hallucination prevention** — When MCP is disabled, the system prompt now instructs the model not to simulate or fabricate tool calls
- **ToolResultEntry equality** — Fixed missing `toolName` comparison in equality check
- **toolUse setter crash** — Fixed potential crash when setting `toolUse` on an empty array

### Improvements
- **Build number format** — Changed from commit SHA to build date (YYYYMMDD) for clearer version identification
- **Post-build review checklist** — Added to CLAUDE.md for consistent code quality checks after feature implementation
- **Project documentation** — Added CLAUDE.md with architecture overview, build instructions, and new model onboarding guide
