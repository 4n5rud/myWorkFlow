# claude-work-harness

Claude Code로 여러 프로젝트를 동시에 운영할 때 쓰는 개인 업무 하네스다. 다른 컴퓨터나 새 계정에 설치 스크립트 한 번으로 옮길 수 있다.

특정 프로젝트의 내용은 들어 있지 않다. 개인 경로, 읽기 전용 저장소, 보고서 머리글처럼 사람마다 다른 값은 모두 `harness.conf` 하나에서 정한다.

## 무엇이 들어 있나

| 층 | 위치 (설치 후) | 하는 일 |
|---|---|---|
| 전역 지침 | `~/.claude/CLAUDE.md` 안의 표시 줄 사이 | 모든 세션과 서브에이전트에 늘 실리는 규칙. 보고하는 법, 한국어 문장 기준, 커밋 메시지 |
| 지침서 | `GUIDES_DIR` (예: 옵시디언 보관함) | 상황별 상세 규칙 00~10. 필요할 때만 골라 읽힌다 |
| 스킬 | `~/.claude/skills/` | `4n5rud-guides`(지침서 길잡이), `/4n5rud-weekly-report`(주간업무보고 만들기), `/4n5rud-todo`(남은 일을 번호로 설명), `/4n5rud-new-project`(새 프로젝트 공통 틀 갖추기), `/4n5rud-plan-doc`(기능 기획서를 공통 양식으로 쓰기), `/4n5rud-qa`(화면을 점검하고 전, 후 사진을 넣은 QA 보고서 쓰기) |
| 훅 | `~/.claude/hooks/` | 규칙을 장치로 강제한다. 자세한 내용은 지침서 `10 자동 장치.md` |
| 예약 작업 | launchd `claude-work-harness.daily` | 매일 작업 폴더 정리, 설정 저장, 요약 알림 |
| 설정 기록 | `~/.claude/bin/claude-config` | `~/.claude`의 설정을 git 이력으로 남기고 되돌린다 |

### 훅이 지키는 것

- 읽기 전용 저장소(`READONLY_REPOS`)는 고치거나 커밋하지 못하게 막는다. 읽기는 허용한다.
- 커밋 금지 저장소(`NO_COMMIT_REPOS`)는 파일 수정은 허용하고, 커밋, 푸시, 태그, 머지, PR만 막는다. 그 저장소의 작업 폴더(워크트리)에서도 막는다.
- 두 저장소의 커밋, 머지, 푸시는 git 전역 훅도 막는다. 명령을 어떤 모양으로 쓰든, 사용자가 터미널에서 직접 하든 막힌다.
- 훅 스크립트, git 전역 훅, `settings.json`, `harness.conf`, `~/.gitconfig`, 비밀값 허용 목록은 Claude가 고치지 못한다. 읽기는 허용한다.
- 작업 브랜치(기능, 수정, 핫픽스)는 커밋과 푸시가 자유롭다. dev, main, prod, staging 푸시와 머지는 매번 확인 창을 띄운다.
- **비밀값(키, 토큰, 비밀번호, 인증서)은 어떤 경우에도 커밋과 푸시를 막는다.** git 전역 훅으로 켜서 Claude가 아닌 사용자의 터미널이나 다른 도구에서 한 커밋과 푸시에도 적용된다. 푸시할 때는 원격에 없는 커밋의 이력 전체를 검사한다. 저장소의 원래 훅(Git LFS 등)은 이어서 실행된다.
- AI 서명, 로컬 전용 목업 데이터와 설정이 커밋, 푸시, 빌드에 들어가지 못하게 막는다.
- 커밋 제목이 커밋 메시지 규칙과 다르면 알려 준다(막지는 않는다).
- 문서에 "전달함, 회신 대기"처럼 보냈다는 표현을 쓰려 하면, 사용자가 보냈다고 확인했는지 다시 보라고 알린다. 세션을 시작할 때 발송 확인이 안 된 문서가 있으면 사용자에게 물어보라고 알린다.
- 사용자가 저장소 밖 파일(다운로드, 임시 폴더 등)을 넘기면 `_수신함/`으로 정리하라고 알린다. 새로 추가하는 줄의 개인 절대 경로와 키, 인증 파일이 커밋에 섞이면 막는다.
- 세션을 시작할 때 원격보다 뒤처졌는지 알리고, 대화가 압축되면 인계 문서 갱신을 알린다.
- 세션을 시작할 때 그 프로젝트의 할 일 목록(문서 저장소의 `_할일/할 일.md`)에 남은 일을 알리고, 사용자가 "완료"라고 하면 체크해서 `끝낸 일.md`로 옮기라고 알린다.
- 서브에이전트에게도 전역 지침과 지침서 길잡이를 넣어 준다. Claude Code는 서브에이전트에게 `CLAUDE.md`와 사용자 스킬을 주지 않기 때문이다.
- 합쳐지고 다 끝난 작업 폴더(git 워크트리)를 정해진 조건에서만 지운다.

## 설치

필요한 것: macOS 또는 Linux, `bash`, `git`, `jq`, `perl`, `shasum` 또는 `sha1sum`, Claude Code. 주간보고 PDF를 만들려면 Google Chrome. 매일 예약 작업과 알림은 macOS(launchd)에서만 자동 등록된다.

주간보고는 노트 보관함의 주간 폴더(`work/<프로젝트>/<YYYY-MM-DD> 주간 (MM.DD~MM.DD)/`의 주간목표와 날짜별 노트)를 근거로 읽는다. 이 폴더를 만드는 스킬은 이 묶음에 들어 있지 않다.

```bash
git clone <이 저장소> ~/claude-work-harness
cd ~/claude-work-harness
bash install.sh          # 처음 실행하면 ~/.claude/harness.conf 를 만들고 멈춘다
# ~/.claude/harness.conf 에서 경로와 이름을 고친다
bash install.sh          # 실제 설치
```

- 기존 `~/.claude/settings.json`의 다른 훅과 설정은 그대로 두고, 이 묶음의 훅만 넣는다.
- 기존 `~/.claude/CLAUDE.md`가 있으면 맨 아래에 표시 줄로 감싼 묶음 부분을 덧붙인다. 다시 설치하면 그 부분만 바뀐다. 통째로 바꾸려면 `bash install.sh --replace-claude-md`.
- 지침서 폴더가 없거나 비어 있으면 `guides/`를 복사해 넣는다. 이미 있으면 건드리지 않는다.
- 바꾸기 전 파일은 `~/.claude/harness-backup/<시각>/`에 남는다.
- 설치가 끝나면 훅 시험 아홉 묶음이 돌고 묶음마다 결과 한 줄이 나온다. 모두 통과해야 한다. 실패한 묶음은 전체 출력을 보여 주고 설치 스크립트가 실패로 끝난다.
- 설치한 파일 목록은 `~/.claude/harness/installed-files.txt`에 남는다. 다음 설치 때 원본에서 사라진 옛 파일을 지우고, 제거 스크립트도 이 목록대로 지운다.
- 이미 열려 있던 Claude Code 세션은 새로 열어야 전역 지침이 적용된다.

시험 설치: `CLAUDE_HOME=/tmp/harness-test bash install.sh` 로 실제 `~/.claude`를 건드리지 않고 설치 과정만 확인할 수 있다.

### 설치 뒤에 할 일

1. `~/.claude/harness/projects.md`에 주간보고 대상 프로젝트와 저장소 폴더를 적는다.
2. 주간보고 자동 실행을 원하면 아래 명령으로 등록한다(Orca를 쓰는 경우).

### 주간보고 자동 실행 (선택)

Orca 자동화로 매주 금요일 오전 9시에 돈다. `<작업 폴더 id>`는 `orca worktree list --json`에서 `WORK_DIR`에 해당하는 항목의 id다.

```bash
orca automations create --name "주간보고 전체 (매주 금 09:00)" \
  --trigger weekly --day 5 --time 09:00 --timezone Asia/Seoul --provider claude \
  --workspace "id:<작업 폴더 id>" --workspace-mode existing --fresh-session \
  --missed-run-grace-minutes 720 --enabled \
  --prompt "/4n5rud-weekly-report 전체
매주 금요일 자동 실행이다. 커밋과 푸시는 하지 않고, 다 만들면 프로젝트별 결과를 보고한다."
```

Orca를 쓰지 않으면 `cron`이나 다른 예약 도구로 `claude -p "/4n5rud-weekly-report 전체"`를 돌려도 된다.

## 쓰는 법

| 하고 싶은 것 | 방법 |
|---|---|
| 지침서를 확실히 읽게 하기 | 메시지 앞에 `/4n5rud-guides` |
| 주간보고 만들기 | `/4n5rud-weekly-report 전체` 또는 `/4n5rud-weekly-report <프로젝트>` |
| 설정 이력 보기, 저장 | `~/.claude/bin/claude-config log --oneline`, `claude-config save "메시지"` |
| 훅을 고친 뒤 확인 | `bash ~/.claude/hooks/tests/run.sh`, `commit-lint.sh`, `received-files.sh` (모두 `tests/` 안) |
| 장치를 끄는 법 | 지침서 `10 자동 장치.md` 6장 |

## 제거

```bash
bash uninstall.sh
```

훅, 스킬, 예약 작업, 전역 지침의 묶음 부분을 지운다. `harness.conf`, 프로젝트 목록, 지침서, 로그, 설정 기록은 남긴다.

## 이 묶음을 고칠 때

- **원본은 이 저장소다.** `~/.claude` 안의 파일을 직접 고쳤다면 이 저장소에도 같은 변경을 옮기고 시험을 돌린다. 그렇지 않으면 다음 설치 때 덮어써진다.
- **지침서 원본은 이 저장소의 `guides/`다(2026-11-16 바뀜).** 세션은 여기서 읽고 고치고, 고친 것은 커밋한다. 노트 보관함(옵시디언)의 지침서는 사본이며, `bash sync-guides.sh`가 원본에서 한쪽으로 복사한다(설치와 매일 예약 작업 때 자동). 사본에서 고친 파일은 덮어쓰지 않고 알리므로, 그 내용을 원본에 옮겨 커밋한 뒤 다시 돌린다. 스크립트는 특정 프로젝트 이름과 개인 절대 경로가 섞였는지도 알린다. 예전의 `export-guides.sh`(보관함을 원본으로 두던 방식)는 쓰지 않는다. 바꾼 이유: 노트 보관함 폴더를 macOS 개인정보 보호가 자주 막아 세션이 지침서를 못 읽었다.
- 특정 프로젝트, 고객, 개인 경로는 넣지 않는다. 사람마다 다른 값은 `harness.conf`나 `projects.md`로 뺀다.
- 셸 변수 이름은 영어로 둔다. 한글 변수 이름은 문법 검사로 안 잡히고 실행할 때 깨진다.

## 정석과의 차이

훅은 명령의 글자 모양을 보고 판단하므로, 별칭이나 다른 프로그램을 거친 명령은 못 잡을 수 있다. 보호 브랜치를 가장 확실하게 지키는 방법은 원격 서버(GitHub, GitLab)의 브랜치 보호 설정이다. 팀 영향이 없다면 그쪽을 함께 켜기를 권한다.

## 출처와 라이선스

- `guides/17 기술 문서 쓰기.md`는 [토스 테크니컬 라이팅 가이드](https://github.com/toss/technical-writing)(Viva Republica)를 바탕으로 고친 글이라 [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/deed.ko)을 따른다.
- 그 밖의 파일은 따로 라이선스를 정하지 않았다.
