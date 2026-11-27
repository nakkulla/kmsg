---
scope:
  - Sources/kmsg/KakaoTalk/TranscriptReader.swift
  - Sources/kmsg/Commands/ReadCommand.swift
  - Sources/kmsg/Commands/MCPServerCommand.swift
  - tests/test_read_since_contract.py
  - tests/test_mcp_server_contract.py
  - USAGE.md
  - skills/kmsg/SKILL.md
---

# 안 읽은 경계에서 열린 방의 최신 끝까지 읽기 설계

**날짜:** 2026-11-27
**상태:** 리뷰 반영(codex r1 REVISE → 7건 반영) — 원인은 추정, 구현 첫 단계에서 재현
**Bead:** kmsg-jii
**레포:** `nakkulla/kmsg` (channprj/kmsg fork), 기준 브랜치 `feat/read-since-unread-count`

## 목표

안 읽은 글이 많이 쌓인 방을 kmsg로 읽으면 최신 글(대화 맨 아래)이 빠지는데도 `stop_reason: complete`, `truncated: false`로 답한다. 아침 요약(Cortex)과 Hermes는 이 값을 믿고 "다 읽었다"고 판단한다.

1. 읽기 전에 최신 끝까지 불러와, since 읽기와 최근 N건 읽기가 최신 글을 포함한다.
2. 그래도 최신 끝에 닿지 못하면 결과 메타에 그 사실을 적는다. 끝까지 못 읽었는데 `complete`라고 답하는 일을 없앤다.

## 확인한 사실

방 대화 본문과 작성자는 적지 않는다. 건수와 시각만 적는다.

### Hermes 진단 (2026-11-27 16:52–17:10 KST, kmsg 6c2a9e7)

- 안 읽은 글이 많은 네 방 모두 최신 글에 닿지 못했다. 세 방은 `complete`·`truncated: false`, 한 방은 `deadline`·`truncated: true`였다.
- 네 결과 모두 카카오톡의 읽음 경계 행 "여기까지 읽었습니다"를 포함했고, 그 행 뒤 행은 21~24개뿐이었다. 경계 시각(08:26·08:45·08:47)은 아침 요약이 방을 연 시각과 맞는다.
- 채팅 목록의 마지막 글 미리보기는 어느 결과에도 없었다.

### 2026-11-25 실측 (Cortex-l14s)

- 안 읽은 글이 약 4000개인 방 하나만 0건 또는 몇 주 전 글 2건을 돌려줬다(`pages_loaded: 0`, `complete`, `truncated: false`). 같은 방 최근 10건 읽기의 마지막 글도 기준 시각보다 이전이었다.

### 이 세션 측정 (2026-11-27 17:50–18:00 KST, 카카오톡을 새로 띄운 직후, kmsg 6c2a9e7 release)

- 경계 뒤 행이 적은 네 방은 모두 정상이었다. 마지막 글이 채팅 목록 미리보기와 맞았다.
  - 경계 행 없음: 214건, 쪽 4, `complete`.
  - 경계 뒤 35행: 695건, 쪽 14, `complete`. 경계 시각 17:05(Hermes가 연 시각).
  - 경계 뒤 7행: 97건, 쪽 2, `complete`. 경계 시각 17:25.
  - 경계 뒤 25행: 73건, 쪽 1, `complete`. 경계 시각 17:17.
- kmsg가 방을 열면 경계가 그 시각으로 옮겨진다. 채팅 목록의 안 읽음 숫자는 그대로 남았다(예: 3999).
- 정상 상태에서 처음 열린 표는 약 52행, 세로 스크롤 값은 1.0이다. 스크롤 값을 0.95로 내렸다가 1.0으로 올려도 행 수는 늘지 않았다.
- 실패 조건(경계 뒤 행이 약 50개 이상)은 만들지 못했다. 방을 열 때마다 경계가 옮겨져 조건을 채우려면 글이 다시 쌓여야 한다. 사용자 결정(2026-11-27)에 따라 원인은 추정으로 두고 설계 0에서 재현한다.

## 원인 (추정 — 설계 0에서 확인)

카카오톡은 안 읽은 글이 있는 방을 열 때 화면을 읽음 경계 근처에 두고, 대화 표에는 경계 앞뒤 약 50행만 올린다. 경계 뒤 글이 그보다 많으면 최신 글은 표에 아직 없다. kmsg는 이 상태에서 최신 쪽을 확인하지 않는다(코드 근거는 `검증된 전제`).

2026-11-25의 0건 응답도 같은 원인으로 설명된다. 경계가 몇 주 전이면 처음 열린 표 전체가 since보다 옛 글이고, 위로 페이징할 필요 없이 "since를 넘었다"로 끝난다.

## 검증된 전제

- since 읽기는 열린 위치에서 위(옛 글)로만 페이징한다. 스크롤바를 0으로만 바꾼다 — `Sources/kmsg/KakaoTalk/TranscriptReader.swift:1317`, `:1597`
- 처음 열린 표의 가장 옛 행이 이미 since보다 옛것이면 위쪽 페이징은 스크롤하지 않고 끝난다 — `TranscriptReader.swift:1577-1582`
- 맨 아래로 되돌리는 `scrollToBottom`은 위로 스크롤했을 때만, 행을 다 읽은 뒤 `defer`에서 부른다 — `TranscriptReader.swift:1327-1334`
- 위로 스크롤했으면 행을 맨 위에 둔 채로 읽는다(맨 아래에서 읽으면 오래된 행이 빈 내용으로 오기 때문). 스크롤하지 않았으면(`scrolledBar == nil`) 지금 위치에서 읽고, 입력창보다 아래에 그려진 행을 건너뛴다 — `TranscriptReader.swift:1327-1328`, `:1389`
- 빈 행 수(`emptyOldestRun`)는 맨 아래로 되돌리기 전, 행 분석 중에 센다 — `TranscriptReader.swift:1346-1349`, `:1492-1494`
- 최근 N건 읽기는 대화 표가 있으면 표의 마지막 행부터 거꾸로 분석하고, 요청 건수와 작성자 확인용 행을 얻으면 멈춘다. 입력창 아래 행은 늘 건너뛰고, 스크롤은 하지 않는다. 표 경로 결과가 모자라면 행 검색 경로로 바꾼다 — `TranscriptReader.swift:169-205`, `:1734-1752`
- 완료 판정은 "since보다 옛 행을 봤다" 또는 "대화 시작에 닿았다"만 본다. 최신 끝 여부는 없다 — `TranscriptReader.swift:1476`
- `stop_reason`은 `truncated`가 false일 때만 `complete`다 — `TranscriptReader.swift:1236`, `USAGE.md:567`
- 위쪽 페이징의 행 수 증가 대기 상한은 3초다 — `TranscriptReader.swift:1282`
- `--background-safe`면 since 읽기의 페이징을 끈다. 그때도 이미 올라온 행이 since보다 옛것이면 `complete`가 될 수 있다 — `Sources/kmsg/Commands/ReadCommand.swift:261`, `TranscriptReader.swift:1476-1480`
- MCP `kmsg_read`는 since 모드에서만 자식에게 `--timeout-sec`을 넘기고, 최근 N건 읽기는 자식 프로세스 전체를 8초(deep recovery면 15초) 뒤 끊는다 — `Sources/kmsg/Commands/MCPServerCommand.swift:599-611`
- MCP `kmsg_read`는 since 모드에서만 `oldest_reached`·`truncated`·`pages_loaded`·`stop_reason`을 `meta`로 넘긴다 — `MCPServerCommand.swift:682-690`
- Cortex 아침 요약은 `truncated`가 false가 아니면 모르는 `stop_reason`을 "끝까지 못 읽음"으로 표시한다 — `~/GitHub/Cortex/scripts/kakao_digest.py:643` (읽기 전용 확인)
- 미확인: 카카오톡은 안 읽은 경계에서 방을 열 때 경계 앞뒤 약 50행만 표에 올리고, 최신 행은 아래로 스크롤해야 불러온다 — 실패 조건을 이 세션에서 만들지 못함. 설계 0에서 확인한다.
- 미확인: 실패 상태에서 세로 스크롤 값을 1.0으로 바꾸면(또는 0.95→1.0) 최신 쪽 행이 불러와진다 — 같은 사유. 설계 0에서 확인한다.

## 설계

### 0. 구현 첫 단계: 실패 재현

코드를 바꾸기 전에 실패 상태의 방 하나(방 A)를 처음 열어 한 번 측정한다. 방을 열면 경계가 그 시각으로 옮겨져 조건이 사라지므로, 한 번 열 때 다음을 모두 기록한다. 기록은 건수·시각·스크롤 값만 남긴다.

후보 방: `kmsg chats`에서 안 읽음 숫자가 큰 방부터, 마지막으로 kmsg(아침 요약·Hermes 포함)가 연 뒤 몇 시간 지나 글이 50개 넘게 쌓였을 방을 고른다. 아침 요약(08시대) 뒤 저녁이면 대부분 조건을 채운다. 후보는 최대 두 방까지 연다.

1. 예측을 먼저 적는다: 최근 10건 읽기의 마지막 글이 채팅 목록 미리보기와 다르고, 경계 행 뒤 행이 약 20~25개다.
2. `kmsg read --chat-id <id> --limit 10 --keep-window --layout offscreen --json`으로 열고 결과의 마지막 글을 미리보기와 비교한다.
3. 열린 창에서 표의 행 수, 세로 스크롤 값, 경계 행 위치와 그 뒤 행 수, 마지막 행의 시각 라벨을 읽는다(읽기 전용 AX 측정, 본문은 읽지 않음).
4. 스크롤 값을 1.0으로 바꾸고(이미 0.99 이상이면 0.95로 내렸다가 1.0으로) 행 수·마지막 행 시각·스크롤 값이 바뀌는지, 몇 초 걸리는지 잰다. 바뀌지 않을 때까지, 최대 30초 되풀이한다. 끝나면 마지막 행이 미리보기와 맞는지 본다.
5. 창을 닫는다.

결과에 따른 진행(구현자가 정하고 `스펙 이탈`로 기록한다):

- (가) 2가 미리보기와 다르고 4에서 행이 늘었다: 스크롤로 최신 쪽을 불러올 수 있다. 설계 1~3을 그대로 구현한다. 4에서 30초 안에 미리보기까지 닿지 못했어도 행이 늘었으면 (가)다. 그때는 4에서 잰 한 번의 불러오기 시간과 필요한 횟수로 설계 1의 확인 대기와 상한을 정하고, 상한 안에 못 닿는 방은 메타가 미도달로 알린다.
- (나) 2가 미리보기와 다르고 4에서 행이 전혀 늘지 않았다: 스크롤 값으로는 최신 쪽을 불러올 수 없다. 설계 1의 불러오기 단계(1~3)는 빼고, 의심 조건이 참이면 `newest_reached: false`로 알리는 판정과 설계 2만 구현한다. 다른 불러오기 방법 조사는 후속 Bead로 넘긴다.
- (다) 두 후보 모두 2가 미리보기와 같다(실패가 재현되지 않음): 설계 1~3은 정상 상태에서 해가 없으므로 (가)처럼 구현한다. 실패 상태 수용 기준은 "미확인"으로 보고하고 원인 조사는 후속 Bead로 넘긴다.

### 1. 최신 끝 불러오기와 판정

since 읽기와 최근 N건 읽기 모두, 대화 표를 분석하기 전에 아래 단계를 거친다. 단계는 창 상태를 바꾸므로 최근 N건 읽기의 표 경로와 행 검색 경로 모두에 적용된다.

불러오기 단계:

1. 세로 스크롤 값을 1.0으로 바꾼다. 이미 0.99 이상이면 0.95로 내렸다가 1.0으로 올린다.
2. 행 수나 마지막 행 시각이 바뀔 때까지 기다린다(확인 대기). 상한은 3초이고, 설계 0에서 잰 불러오기 시간의 두 배로 줄일 수 있다(1초 이상).
3. 바뀌었으면 1로 돌아간다. 바뀌지 않으면 멈춘다.
4. 마감(아래)이나 `--max-pages`에 닿거나 스크롤 값을 바꿀 수 없으면 멈춘다. 아래로 불러온 쪽은 `pages_loaded`에 더하지 않는다(그 값은 옛 글 쪽 수로 남는다).

최신 끝 판정(`newest_reached`):

- `true`: 불러오기 단계가 "바뀌지 않음"으로 멈췄고, 그때 스크롤 값이 0.99 이상이며, 그때 기록한 마지막 행 시각 라벨이 결과의 마지막 메시지 시각과 같다. 설계 0이 (가)·(다)로 끝났다는 것, 곧 실패 상태에서 스크롤하면 행이 불러와진다는 사실(또는 반증 없음)이 "바뀌지 않음 = 최신 끝"의 근거다.
- `false`: 마감·쪽 상한·스크롤 실패로 멈췄거나, 위 조건 하나라도 어긋난다. since 읽기에서 위쪽 페이징과 행 분석 뒤 결과의 마지막 메시지 시각이 기록한 시각과 다르면 `false`다.
- `null`: 표나 스크롤바를 읽을 수 없거나 `--background-safe`라 단계를 하지 않았다. 최신 끝을 단정하지 않는다.

since 읽기는 이 단계를 늘 먼저 하고, 그 뒤는 지금과 같다: 위로 페이징하고, 스크롤했으면 맨 위에 둔 채 행을 읽고, 끝나면 맨 아래로 되돌린다.

최근 N건 읽기는 MCP 제한 안에 끝나야 하므로 최신 끝이 의심될 때만 이 단계를 한다. 의심 조건은 분석 건수와 상관없이 처음 열린 표 전체를 보고 정한다: 처음 스크롤 값이 0.99보다 작다, 또는 올라온 행 가운데 경계 행("여기까지 읽었습니다")이 있다(본문 분석 없이 정적 텍스트만 훑는다). 의심 조건이 없으면 단계를 건너뛰고 `true`다. 단계를 했으면 행을 다시 읽는다.

(나)로 끝났으면 불러오기 단계 없이 판정만 한다: 의심 조건이 참이면 `false`, 아니면 `true`, 표·스크롤을 못 읽으면 `null`.

마감: since 읽기는 지금처럼 `--timeout-sec`의 페이징 몫 안에서 한다. 최근 N건 읽기도 `--timeout-sec`을 받게 하고(지금은 since 전용), 시작부터 그 시간 안에 불러오기와 다시 읽기를 끝낸다. 마감에 닿으면 그때까지 읽은 행으로 결과를 내고 `newest_reached: false`로 둔다. 기본값은 6초다. MCP `kmsg_read`는 최근 N건 읽기에도 자식에게 `--timeout-sec`을 넘긴다: 자식 제한 8초면 6, 15초면 13(정리와 JSON 출력 몫 2초).

### 2. 결과 메타

- since 읽기 JSON에 `newest_reached`(bool 또는 `null`)를 더한다.
- `newest_reached`가 `true`가 아닌(`false`·`null`) since 읽기는 `truncated: true`다. 멈춤 이유 우선순위: 지금의 미완료 이유(`deadline`·`page_cap`·`scroll_failed`·`rows_unreadable`·`paging_unavailable`) > `newest_unreached` > `limit` > `complete`. 그래서 `--background-safe` since 읽기는 이제 `complete`가 되지 않는다. "`truncated`가 false일 때만 `complete`" 불변식은 유지한다.
- 최근 N건 읽기 JSON에도 `newest_reached`를 더한다. 최근 N건 읽기에는 `truncated`·`stop_reason`이 없으므로 이 필드 하나로 알린다.
- MCP `kmsg_read`는 since 유무와 관계없이 `newest_reached`를 `meta.newest_reached`로 넘긴다. 도구 설명의 `stop_reason` 목록에 `newest_unreached`를 더한다.
- 결정: Cortex `scripts/kakao_digest.py`는 바꾸지 않는다 — 새 `stop_reason`은 기존 "끝까지 못 읽음" 표시로 처리된다.

### 3. 문서와 시험

- `USAGE.md`, `skills/kmsg/SKILL.md`에 `newest_reached`, `newest_unreached`, 최근 N건 읽기의 `--timeout-sec`을 적는다. 설계 0이 (나)로 끝났으면 불러오기 설명은 빼고 판정만 적는다.
- `tests/test_read_since_contract.py`: 새 JSON 키, `newest_unreached` 멈춤 이유와 우선순위, 불변식 문구를 고정한다.
- `tests/test_mcp_server_contract.py`: `meta.newest_reached` 전달(since 유무 모두), 최근 N건 읽기의 자식 `--timeout-sec`, 도구 설명의 새 값을 고정한다.

## 수용 기준

실측 기준은 모드마다 따로 처음 여는 방에서 확인한다. 한 번 연 방은 경계가 옮겨지므로 다시 쓰려면 글이 다시 쌓여야 한다. 실패 상태의 방을 그 모드에 쓸 수 없으면 그 항목은 "미확인"으로 보고한다.

- `swift build -c release` 성공.
- `python3 -m pytest tests -q` 통과.
- 설계 0의 기록(예측, 측정값, (가)·(나)·(다) 중 어느 것인지)이 Bead notes에 건수·시각·스크롤 값만으로 남는다.
- (가)일 때: 실패 상태의 방을 처음 여는 since 읽기의 마지막 글이 채팅 목록 미리보기와 맞고 `newest_reached: true`, `stop_reason: complete`다(또는 상한 안에 못 닿으면 `truncated: true`, `stop_reason: newest_unreached`). 실패 상태의 다른 방을 처음 여는 `--limit 10` 읽기의 마지막 글이 미리보기와 맞고 `newest_reached: true`다.
- (나)일 때: 실패 상태의 방을 처음 여는 since 읽기가 `truncated: true`, `stop_reason: newest_unreached`이고, 다른 방의 최근 N건 읽기가 `newest_reached: false`다.
- 정상 상태 방에서 since 읽기와 최근 N건 읽기의 마지막 글이 미리보기와 맞고 `newest_reached: true`, since 읽기는 `complete`다. MCP 경로(Hermes 설정: deep recovery)의 최근 15건 읽기가 `PROCESS_TIMEOUT` 없이 끝난다.
- 정상 상태 방의 since 읽기 trace에서 `emptyOldestRun`이 2 이상이 되지 않는다.
- `--background-safe` since 읽기가 `truncated: true`, `newest_reached: null`이다.

## 검토한 대안

- 채팅 목록 미리보기를 마지막 행과 비교해 최신 끝을 판정: 사진·이모티콘·긴 글은 미리보기가 본문과 달라 오판이 잦다. 수동 검증에만 쓴다.
- 안 읽음 숫자와 경계 뒤 행 수 비교: 방을 열어도 목록의 안 읽음 숫자가 줄지 않아 기준이 될 수 없다.
- 메타만 정직하게 고치기: 아침 요약이 안 읽은 방마다 "끝까지 못 읽음"이 되어 쓸모가 없다. 불러오기와 메타를 함께 한다.

## 결정 (ADR 후보)

- since·최근 N건 읽기 결과에 `newest_reached`와 `stop_reason: newest_unreached`를 더한다 — 되돌리기 어렵지 않음(필드 추가라 소비자 변경 없이 되돌릴 수 있음) → ADR 아님

## 범위 밖

- Cortex `scripts/kakao_digest.py` 변경.
- 카카오톡이 방을 열 때 경계를 옮기는 동작(읽음 처리)을 막는 일.
- 채팅 목록 안 읽음 숫자가 열어도 줄지 않는 현상.
