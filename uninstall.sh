#!/usr/bin/env bash
# claude-work-harness 제거. 설정 파일(harness.conf), 프로젝트 목록, 지침서, 로그, 백업은 남긴다.
set -euo pipefail
CH="${CLAUDE_HOME:-$HOME/.claude}"
GUIDES_DIR=""; [[ -f "$CH/harness.conf" ]] && source "$CH/harness.conf"
TS="$(date +%Y%m%d-%H%M%S)"; BK="$CH/harness-backup/uninstall-$TS"; mkdir -p "$BK"

# 1. settings.json 에서 이 묶음의 훅 줄만 뺀다
S="$CH/settings.json"
if [[ -f "$S" ]]; then
  cp "$S" "$BK/settings.json"
  jq --arg guides "$GUIDES_DIR" '
    def mine: ((.hooks // []) | map(.command // "") | any(test("/\\.claude/hooks/(guard|commit-lint|skill-log|session-start|session-end|subagent-start|received-files|sent-claims|todo-done)\\.sh$")));
    .hooks = ((.hooks // {}) | with_entries(.value |= map(select(mine | not))) | with_entries(select(.value | length > 0)))
    # the attribution setting and the guide read permission that install.sh added
    | if .attribution == {"commit":"","pr":"","sessionUrl":false} then del(.attribution) else . end
    | if ($guides != "" and (.permissions.allow | type) == "array") then .permissions.allow -= ["Read(/" + $guides + "/**)"] else . end
  ' "$S" > "$S.tmp" && mv "$S.tmp" "$S"
fi

# 2. CLAUDE.md 에서 묶음 부분만 뺀다
if [[ -f "$CH/CLAUDE.md" ]]; then
  cp "$CH/CLAUDE.md" "$BK/CLAUDE.md"
  perl -0pi -e 's/\n?<!-- claude-work-harness:start -->.*?<!-- claude-work-harness:end -->\n?/\n/s' "$CH/CLAUDE.md"
fi

# 3. 훅, 도구, 스킬, git 전역 훅: 설치 때 남긴 목록대로 지운다. 목록이 없으면(옛 설치) 알려진 이름으로 지운다.
# git 전역 훅은 이 묶음이 켠 경우에만 끈다. 허용 목록은 남긴다.
if [[ -z "${CLAUDE_HOME:-}" && "$(git config --global --get core.hooksPath 2>/dev/null)" == "$CH/git-hooks" ]]; then git config --global --unset core.hooksPath; fi
MANIFEST="$CH/harness/installed-files.txt"
if [[ -f "$MANIFEST" ]]; then
  while IFS= read -r f; do [[ -n "$f" && "$f" != *..* ]] && rm -f "$CH/$f"; done < "$MANIFEST"
  rm -f "$MANIFEST"
else
  for f in guard commit-lint skill-log session-start session-end subagent-start received-files sent-claims todo-done lib-project worktree-gc daily secret-scan personal-scan submodule-check; do rm -f "$CH/hooks/$f.sh"; done
  for f in run commit-lint received-files sent-claims todo secret-scan git-hooks personal-scan submodule-check; do rm -f "$CH/hooks/tests/$f.sh"; done
  rm -f "$CH/bin/claude-config"
fi
rm -rf "$CH/git-hooks" "$CH/skills/4n5rud-guides" "$CH/skills/4n5rud-weekly-report" "$CH/skills/4n5rud-todo" "$CH/skills/4n5rud-new-project" "$CH/skills/4n5rud-plan-doc" "$CH/skills/4n5rud-qa"
rmdir "$CH/hooks/tests" "$CH/hooks" "$CH/bin" 2>/dev/null || true

# 4. 예약 작업
if [[ -z "${CLAUDE_HOME:-}" && "$(uname)" == Darwin ]]; then
  launchctl bootout "gui/$(id -u)/claude-work-harness.daily" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/claude-work-harness.daily.plist"
fi

echo "제거했습니다. 지운 설정의 사본: $BK"
echo "남긴 것: $CH/harness.conf, $CH/harness/, 지침서 폴더, $CH/logs/, 설정 기록 저장소(~/.claude-config.git)"
echo "Orca에 등록한 주간보고 자동 실행은 Orca에서 직접 끄세요."
