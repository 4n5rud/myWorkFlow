---
tags: [지침서, 도커, Kiri, 로컬 개발, 시험, 공통]
생성: 2026-11-17
출처: 사용자 결정(2026-11-17, "도커가 너무 무거워서 로컬 빌드와 로컬 테스트는 경량인 Kiri로. 저장소에 올라가는 인프라 세팅은 도커나 그 프로젝트 세팅을 따른다")
적용: 이 Mac에서 컨테이너를 띄우거나 빌드하는 모든 세션과 서브에이전트
---

# 로컬 컨테이너는 Kiri

> 이 Mac에서 로컬로 띄우는 컨테이너(DB, Redis, 스토리지, 로컬 빌드, 시험)는 Docker Desktop이 아니라 **Kiri**에서 돌린다. Kiri는 Docker와 같은 명령을 받는 가벼운 컨테이너 실행기다. 저장소에 올라가는 인프라 설정은 바꾸지 않는다.

## 1. 무엇을 어디서 쓰나

| 일 | 쓰는 것 | 이유 |
|---|---|---|
| 로컬 DB, Redis, MinIO 띄우기, 로컬 빌드, 로컬 시험(Testcontainers 포함) | **Kiri** (`docker`, `docker compose` 명령 그대로) | 가볍고 빠르다. 이 Mac의 `docker` 명령은 이미 Kiri를 가리킨다 |
| 저장소에 올라가는 인프라 설정(Dockerfile, compose 파일, CI, 쿠버네티스, 배포 스크립트) | **Docker 표준과 그 프로젝트가 정한 방식** | 팀원, CI, 서버는 Kiri를 쓰지 않는다. 나 혼자만 도는 설정을 올리면 다른 사람 환경이 깨진다 |

- **저장소에 Kiri 전용 내용을 넣지 않는다.** `kiri` 명령, `*.kiri.localhost` 도메인, `~/.kiri` 경로, Kiri 소켓 경로를 compose 파일, 스크립트, README, CI에 적지 않는다. 문서에는 "로컬 컨테이너 실행기(Docker Desktop, Kiri 등)"처럼 쓴다.
- compose 파일과 Dockerfile은 Docker 표준 문법만 쓴다. Kiri에서만 되는 우회가 필요해지면 저장소를 고치지 말고 사용자에게 알린다.

## 2. 설치 예시

- `docker` 명령의 기본 대상(컨텍스트)은 `kiri`다(`docker context ls`에서 `kiri *`). 엔진 소켓: `~/.kiri/run/docker.sock`.
- **Docker Desktop은 꺼져 있고, 자동 시작도 껐다.** 켜지 않는다. 켜야 할 일이 생기면 사용자에게 먼저 묻는다(무겁고, 같은 포트를 두고 Kiri와 부딪친다).
- 로컬 DB 데이터는 Kiri 볼륨에 있다.
- Testcontainers는 `~/.testcontainers.properties`의 `docker.host`로 Kiri 소켓을 찾는다. 기본 경로 `/var/run/docker.sock`을 찾는 도구가 Kiri를 못 찾으면 사용자에게 `sudo ln -sf ~/.kiri/run/docker.sock /var/run/docker.sock` 실행을 부탁한다(관리자 권한).

## 3. 쓰는 법

평소처럼 쓴다. 명령을 바꿀 필요가 없다.

```bash
docker compose up -d db redis     # 프로젝트 compose 그대로
docker ps
docker logs -f <컨테이너>
```

- 컨테이너 이름과 포트는 그 프로젝트 compose가 정한 그대로다. Kiri로 옮기면서 이름과 포트를 바꾸지 않았다.
- 여러 프로젝트가 같은 포트(5432, 6379, 9000)를 쓰면 부딪친다. 띄우기 전에 `docker ps`로 같은 포트를 쓰는 컨테이너가 있는지 보고, 다른 프로젝트 것이면 멈추지 말고 사용자에게 알린다.
- 로컬 데이터가 필요한 작업 전에는 DB에 테이블과 데이터가 있는지 먼저 본다. 비어 있으면 마이그레이션과 시드를 돌리거나 백업해 둔 덤프를 쓸지 사용자에게 묻는다.

## 4. 막혔을 때

| 증상 | 먼저 볼 것 |
|---|---|
| `Cannot connect to the Docker daemon` | `docker context ls`가 `kiri`인지, Kiri 앱이 켜져 있는지. `kiri diag logs --errors` |
| 시험 도구가 도커를 못 찾음 | 2장의 Testcontainers 설정과 `/var/run/docker.sock` 연결 |
| 컨테이너는 떴는데 앱이 안 뜸 | `docker logs`. Kiri 문제가 아니라 앱 코드나 설정 문제인 경우가 많다(예: 감시 모드 컨테이너가 저장소 코드의 컴파일 오류로 멈춤) |
| Kiri에서만 동작이 다름 | Docker Desktop을 다시 켜서 우회하지 말고, 증상과 `kiri diag report` 결과를 사용자에게 보고한다. Kiri는 아직 0.2판이다 |

## 5. 하지 않는 것

- Docker Desktop을 사용자 확인 없이 켜기
- 저장소의 compose, Dockerfile, CI를 Kiri에 맞춰 고치기
- 다른 프로젝트의 컨테이너를 멈추거나 지우기(포트가 부딪쳐도 사용자에게 먼저 알림)
- `kiri share`로 로컬 포트를 인터넷에 열기(사용자 지시가 있을 때만)
