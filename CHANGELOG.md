# 변경 이력

이 프로젝트(fork: theLay)의 주요 변경사항을 기록합니다.

## [Unreleased]

### 새 기능
- **MCP 도구 병렬 실행** (2026-04-11) — 모델이 한 응답에서 여러 tool을 요청하면 동시에 실행하고, 각 tool의 실시간 상태(실행중/성공/실패)를 채팅 UI에 표시 ([PR #2](https://github.com/theLay/amazon-bedrock-client-for-mac/pull/2))
- **Claude Sonnet 4.6 & Opus 4.6 모델 지원** (2026-03-14) — 최신 Anthropic 모델의 감지 로직, 추론 설정, 기능 플래그 추가

### 버그 수정
- **이미지 포맷 보존** (2026-03-14) — PNG 이미지가 JPEG로 잘못 전송되어 Bedrock API 에러가 발생하던 문제 수정
- **MCP Tool.Content 처리** (2026-03-14) — MCP 라이브러리 API 변경에 맞춰 switch 케이스 업데이트
- **Tool 호출 할루시네이션 방지** (2026-04-11) — MCP 비활성 시 모델이 가짜 tool 호출을 텍스트로 생성하지 않도록 시스템 프롬프트에 안내 추가
- **ToolResultEntry 동등성 비교** (2026-04-11) — equality 체크에서 `toolName` 비교가 누락된 문제 수정
- **toolUse setter 크래시** (2026-04-11) — 빈 배열에 대한 setter 접근 시 크래시 가능성 수정

### 개선
- **빌드 번호 형식 변경** (2026-03-16) — commit SHA 대신 빌드 날짜(YYYYMMDD) 사용으로 버전 식별 개선
- **빌드 후 리뷰 체크리스트** (2026-04-11) — 기능 구현 후 버그, 컨벤션, 네이밍을 점검하는 체크리스트를 CLAUDE.md에 추가
- **프로젝트 문서화** (2026-03-14) — CLAUDE.md에 아키텍처 개요, 빌드 방법, 새 모델 온보딩 가이드 작성
