# 변경 이력

이 프로젝트(fork: theLay)의 주요 변경사항을 기록합니다.

> **참고**: 원본 저장소([aws-samples/amazon-bedrock-client-for-mac](https://github.com/aws-samples/amazon-bedrock-client-for-mac))는
> 2025년 12월 v1.4.3 이후 업데이트가 중단된 상태입니다.
> 이 fork는 그 이후 신규로 추가되는 LLM 모델들의 사용을 위해 몇몇 기능들을 추가하고 있습니다.

## [Unreleased]

### 새 기능
- **MCP 도구 병렬 실행** (2026-04-11) — 모델이 한 응답에서 여러 tool을 요청하면 동시에 실행하고, 각 tool의 실시간 상태(실행중/성공/실패)를 채팅 UI에 표시 ([PR #2](https://github.com/theLay/amazon-bedrock-client-for-mac/pull/2))
- **Claude Sonnet 4.6 & Opus 4.6 모델 지원** (2026-03-14) — 최신 Anthropic 모델의 감지 로직, 추론 설정, 기능 플래그 추가

### 버그 수정
- **이미지 포맷 보존** (2026-03-14) — PNG 이미지가 JPEG로 잘못 전송되어 Bedrock API 에러가 발생하던 문제 수정

### 개선
- **유휴 상태 CPU 사용률 대폭 감소** (2026-05-01) — 사이드바의 10초 폴링 타이머(시간당 ~360회 idle wake-up)를 자정 1회 타이머 + scenePhase 감지 방식으로 교체, 유휴 CPU 15.4% → ~1.5%로 개선
- **채팅 메시지 렌더링 최적화** (2026-04-11) — LazyVStack 적용으로 긴 대화 선택 시 로딩 지연 해소, 비동기 파일 I/O로 메인 스레드 블록 방지, 대화 전환 시 처음부터 표시 ([PR #3](https://github.com/theLay/amazon-bedrock-client-for-mac/pull/3))
- **빌드 번호 형식 변경** (2026-03-16) — commit SHA 대신 빌드 날짜(YYYYMMDD) 사용으로 버전 식별 개선
- **프로젝트 문서화** (2026-03-14) — CLAUDE.md에 아키텍처 개요, 빌드 방법, 새 모델 온보딩 가이드 작성
