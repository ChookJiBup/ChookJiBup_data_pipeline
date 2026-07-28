# festmap_pipeline

전국 문화축제 공공데이터 API + 지역축제 개최계획 엑셀(연도별)을 매칭해서,
**`festivals` 테이블(FestMap 서비스 전체 스키마의 허브 테이블)에 연도별 방문객수 컬럼을 직접 추가**하는 파이프라인.

이 저장소는 데이터만 채우는 게 아니라 **FestMap 서비스 전체 스키마(users/admins/festivals/
festival_wishlist/festival_dashboard/festival_roadmap/booth_info/festival_operator_invite 등
18개 테이블)를 관리(생성)하는 책임도 같이 가집니다.** 실행할 때마다 스키마가 없으면 만들고,
있으면 그냥 넘어갑니다(아래 "스키마 적용" 참고).

## 최종 결과물

`festivals` 테이블이 축제 데이터의 허브입니다. 기본 API 컬럼(축제명, 장소, 좌표, 홈페이지 등)에
엑셀 매칭 결과로 아래 같은 컬럼들이 자동으로 붙습니다.

| 컬럼 | 의미 |
|---|---|
| `visitor_2024_total` / `_domestic` / `_foreign` | 2025년 엑셀(방문객수 기준연도=2024)과 매칭된 방문객수 |
| `visitor_2025_total` / `_domestic` / `_foreign` | 2026년 엑셀(방문객수 기준연도=2025)과 매칭된 방문객수 |

나중에 2027년 엑셀이 추가되면 `visitor_2026_*` 컬럼이 **자동으로 추가**됩니다 (수동 ALTER 불필요).

```sql
SELECT festival_name, visitor_2024_total, visitor_2025_total
FROM festivals
WHERE visitor_2025_total IS NOT NULL
ORDER BY visitor_2025_total DESC;
```

## 폴더 구조

```
festmap_pipeline/
├── config.py             # DB / API / 엑셀 설정 (git에는 안 올라감, configexample.py 복사해서 사용)
├── db.py                  # Postgres 커넥션
├── schema.sql               # FestMap 전체 스키마 DDL (18개 테이블, 재실행해도 안전)
├── schema_loader.py           # schema.sql을 그대로 실행하는 모듈 (테이블 없으면 생성, 있으면 스킵)
├── utils.py                     # 공통 유틸 (날짜 파싱, 숫자 파싱, 축제명 정규화, progress_status 계산)
├── loaders/
│   ├── api_loader.py              # 공공데이터 API 호출 -> festivals에 UPSERT
│   ├── excel_schemas.py             # 연도별로 다른 엑셀 서식을 각각 파싱하는 파서 모음
│   └── excel_loader.py              # data/ 폴더 스캔, 연도별 파서로 라우팅 -> festival_visitor_excel에 UPSERT
├── matcher.py                         # 축제명 정규화 매칭 -> festivals에 방문객수 컬럼 UPDATE
├── festival_status_updater.py           # festivals.progress_status(예정/진행중/종료) 재계산
├── run_status_update.py                   # 새벽 6시 cron 전용 진입점 (festival_status_updater만 가볍게 실행)
├── admin_email_verification_cleaner.py      # 만료된(15분 지난) 관리자 이메일 인증 코드 삭제
├── run_verification_cleanup.py                # 15분마다 cron 전용 진입점 (admin_email_verification_cleaner만 가볍게 실행)
├── scheduler.py                             # crontab 없이 쓰는 파이썬 자체 스케줄러 (APScheduler, 선택사항 — 위 두 배치를 다 관리)
├── requirements.txt                           # 의존성 목록
├── main.py                              # 전체 파이프라인 실행 진입점
└── data/                                  # 엑셀 파일을 여기에 넣으세요 (연도별로 여러 개 가능)
    ├── 2025년_지역축제_개최계획_현황_0321_.xlsx
    └── 2026년_지역축제_개최_계획_현황_공개용_.xlsx
```

## 내부 동작 순서 (main.py)

1. **schema_loader** — `schema.sql`을 그대로 실행. 테이블/타입/인덱스/트리거가 없으면 생성하고,
   이미 있으면 에러 없이 스킵합니다 (별도 마이그레이션 도구 없이 "없으면 생성" 방식).
2. **api_loader** — API 호출해서 `festivals`에 **UPSERT** (`source_type='api'`인 행만 대상)
3. **excel_loader** — `data/` 폴더의 엑셀들을 연도별 파서로 각각 파싱해서 `festival_visitor_excel`에
   **UPSERT** (파일별로 구분 저장, 연도 간 합산 없음)
4. **matcher** — 각 엑셀 파일마다 축제명을 `festivals`와 정규화 매칭하고,
   - `festival_visitor_excel.matched_festival_id` / `match_status` / `matched_at`에 매칭 결과 기록
   - 매칭 성공분은 `visitor_{엑셀연도-1}_total/domestic/foreign` 컬럼을 `festivals`에 UPDATE로 채움
     (컬럼이 없으면 자동으로 `ALTER TABLE ... ADD COLUMN`)
5. **festival_status_updater** — 오늘 날짜와 `start_date`/`end_date`를 비교해서
   `festivals.progress_status`(예정/진행중/종료)를 다시 계산해 채웁니다. 아래
   "축제 진행 상태(progress_status) 배치" 섹션 참고.

`festival_visitor_excel`은 엑셀 원본을 그대로 보관하는 백업 성격 테이블이면서
매칭 결과(`matched_festival_id`/`match_status`)도 같이 들고 있습니다 — 예전에는
`festival_name_match`라는 별도 로그 테이블이 있었는데, FestMap 전체 스키마에는 그 테이블이
없어서 컬럼으로 흡수했습니다.

## ⚠️ TRUNCATE에서 UPSERT로 바뀐 이유

예전 버전은 실행할 때마다 `festival_api_raw`를 통째로 `TRUNCATE ... CASCADE`한 뒤 다시
채우는 방식이었습니다. 그때는 이 테이블이 파이프라인 혼자 쓰는 캐시성 테이블이라 괜찮았는데,
지금은 `festivals.festival_id`를 `festival_wishlist`(찜) / `festival_review`(리뷰) /
`festival_dashboard`(대시보드) / `booth_info`(부스) 등 서비스 쪽 테이블들이 FK로 참조합니다.
매번 TRUNCATE하면 이 서비스 데이터가 파이프라인을 돌릴 때마다 전부 사라지기 때문에,
**UPSERT(있으면 갱신, 없으면 삽입) 방식으로 전면 수정했습니다.**

- `api_loader.py`: `festivals`에 `INSERT ... ON CONFLICT (festival_name, start_date, road_address)
  WHERE source_type='api' DO UPDATE`
- `excel_loader.py`: `festival_visitor_excel`에 `INSERT ... ON CONFLICT (source_file, row_no) DO UPDATE`

### ⚠️ 알아두어야 할 한계 (자연키 기반 UPSERT)

data.go.kr API는 축제별로 안정적인 고유 ID를 내려주지 않습니다. 그래서 `festival_name` +
`start_date` + `road_address` 조합을 대체 키(자연키)로 써서 UPSERT하고 있습니다
(`schema.sql`의 `ux_festivals_api_natural_key`, `source_type='api'`인 행에만 적용).

- API 쪽에서 주소 표기나 날짜가 미세하게 바뀌면 같은 축제인데도 새 행으로 다시 들어갈 수 있습니다.
- 이번 실행의 API 응답에 없는 기존 축제는 **삭제하지 않습니다.** (`api_last_seen_at`만 갱신 안 되고
  남아있음) 자동 삭제를 안 하는 이유는, 삭제하면 그 축제에 연결된 찜/리뷰/대시보드까지
  `ON DELETE CASCADE`로 같이 지워지기 때문입니다. 더 이상 유효하지 않은 축제를 정리하고
  싶다면 `api_last_seen_at` 기준으로 별도 배치(예: "30일 이상 안 보인 API 축제는 숨김 처리")를
  직접 만들어서 처리하는 걸 권장합니다.
- `source_type='manual'`(관리자가 직접 등록한 축제)은 이 UPSERT 대상이 아니라서 전혀 건드리지 않습니다.

## 연도별 엑셀 서식이 다릅니다

정부에서 매년 내려주는 개최계획 엑셀은 시트명·컬럼 배치가 해마다 바뀝니다. 그래서 `excel_loader.py`는
**파일명에서 연도를 추출한 뒤, `excel_schemas.py`에 등록된 해당 연도 전용 파서로 라우팅**하는 구조입니다.

현재는 **2025, 2026년 파일만 `SCHEMA_PARSERS`에 등록**해서 사용합니다.
(2024년 파서 `excel_schemas.parse_2024`는 구현은 되어 있지만 현재 미사용 — 필요해지면 `excel_loader.py`의
`SCHEMA_PARSERS`에 `2024: excel_schemas.parse_2024`만 다시 추가하면 바로 씁니다.)

| | 2025 | 2026 |
|---|---|---|
| 시트명 | `조사표` | `조사표` |
| 데이터 시작행 | 8행 | 8행 |
| 개최기간 | 년/월/일 분리 | 년/월/일 분리 |
| 장소 상세(시도/시군구/읍면동) | 있음 | 있음 |
| 개최방식(대면/비대면) | 있음 | 없음 |
| 개최주기 | 있음 | 있음 |
| 방문객 계측방법 | 없음 | 있음 |
| 담당자 성명 | 없음 | 있음 |

### 새 연도 파일이 추가되면

1. `loaders/excel_schemas.py`에 `parse_2027(path, plan_year)` 같은 함수를 새로 추가 (기존 함수 참고)
2. `loaders/excel_loader.py`의 `SCHEMA_PARSERS` 딕셔너리에 `{2027: excel_schemas.parse_2027}` 등록
3. `data/` 폴더에 파일만 넣으면 나머지(파싱, 매칭, `visitor_2026_*` 컬럼 생성)는 자동으로 처리됩니다

## 축제 진행 상태(progress_status) 배치

`festivals.progress_status`는 `festival_progress_status` ENUM 컬럼(`upcoming`/`ongoing`/`completed`)으로,
매번 API 호출 시점에 실시간 계산하는 대신 **DB에 미리 값을 저장**해두고 배치로 갱신하는 방식입니다.

**계산 규칙** (`festival_status_updater.py`):

| 조건 | 값 |
|---|---|
| `start_date` 또는 `end_date`가 NULL | `NULL` (판단 불가) |
| 오늘 < `start_date` | `upcoming` (예정) |
| 오늘 > `end_date` | `completed` (종료) |
| 그 사이 | `ongoing` (진행중) |

값이 실제로 바뀌는 행만 UPDATE합니다(`IS DISTINCT FROM`으로 필터) — 매번 전체를 다시 쓰면
안 바뀐 축제까지 `updated_at`이 갱신돼서, 꼭 필요한 행만 건드리도록 했습니다.

### 언제 실행되나

1. **`loaders/api_loader.py`가 축제를 INSERT/UPDATE하는 바로 그 순간에도 계산** — API에서
   새 축제가 처음 들어오거나 날짜가 바뀐 순간, `progress_status`가 `NULL`로 비어있는 채로
   남았다가 다음 배치를 기다리지 않고 **적재 즉시** 채워집니다. (아래 "api_loader에서도
   바로 계산" 참고)
2. **`main.py`(전체 파이프라인) 마지막 단계로 `festival_status_updater.py` 자동 실행** —
   엑셀 매칭 등 파이프라인의 다른 단계까지 다 끝난 뒤 전체 축제를 대상으로 한 번 더 재계산합니다.
3. **매일 새벽 6시, cron으로 단독 실행** — 파이프라인을 안 돌리는 날에도 "오늘 날짜가
   바뀌어서" 상태가 바뀌어야 하는 축제(예: 어제까지 `ongoing`이었는데 오늘부터 `completed`)를
   놓치지 않기 위함입니다. `run_status_update.py`가 이 전용 진입점입니다.

crontab 등록 예시:
```bash
crontab -e
# 아래 줄 추가 (경로는 실제 설치 위치로 변경)
0 6 * * * cd /path/to/chookjibup_data_pipeline && /usr/bin/python3 run_status_update.py >> logs/status_update.log 2>&1
```
`logs/` 디렉터리가 없으면 먼저 `mkdir logs`로 만들어두세요.

`run_status_update.py`는 실행할 때마다 `schema_loader.run()`도 먼저 호출해서, `progress_status`
컬럼이 아직 없는 상태(예: 이 기능을 처음 배포한 날)에도 안전하게 동작합니다.

### crontab 대신 파이썬 자체 스케줄러(`scheduler.py`)를 쓰고 싶다면

crontab에 접근 권한이 없는 환경(일부 PaaS 등)이거나, 스케줄까지 파이썬 코드 안에서 관리하고
싶으면 `scheduler.py`를 쓰세요. **`run_status_update.py`+crontab 방식과는 둘 중 하나만
쓰면 됩니다** (둘 다 등록하면 같은 작업이 중복 실행됩니다).

| | `run_status_update.py` + crontab | `scheduler.py` |
|---|---|---|
| 실행 방식 | OS가 6시에 짧게 실행하고 끝 | 프로세스가 계속 떠서 자체적으로 대기 |
| 필요한 것 | crontab 등록 권한 | `pip install apscheduler`, 프로세스를 계속 살려둘 방법(systemd/Docker/pm2 등) |
| 기본값 추천 | ✅ (더 단순하고 리소스도 안 씀) | crontab을 못 쓸 때만 |

```bash
pip install apscheduler   # 또는: pip install -r requirements.txt
python3 scheduler.py
```

- 시간대는 코드에 `Asia/Seoul`로 고정해뒀습니다 (서버가 UTC로 떠 있어도 한국시간 새벽 6시에 돕니다).
- 프로세스를 시작하는 즉시 한 번 실행하고, 그 다음부터 매일 새벽 6시에 실행합니다 — 재배포
  직후 다음 새벽 6시까지 값이 안 채워진 채로 기다리지 않도록 하기 위함입니다.
- 서버가 잠깐 꺼져 있다 새벽 6시를 넘겨서 다시 떴어도, 1시간 이내면 놓치지 않고 실행합니다
  (`misfire_grace_time=3600`).
- 이 프로세스가 죽으면 스케줄 자체가 멈추니, systemd 서비스나 Docker(`restart: always`),
  pm2 같은 걸로 "죽으면 다시 띄우기"를 꼭 같이 설정하세요.

실제로 로컬에서 APScheduler의 `CronTrigger(hour=6, minute=0, timezone='Asia/Seoul')`가
"다음 실행 시각"을 정확히 내일 새벽 6시(KST)로 계산하는 것, 그리고 `scheduler.py`를 직접
실행해서 시작 시점 즉시 실행 → 스케줄 등록까지 로그로 확인했습니다.

### api_loader에서도 바로 계산

`api_loader.py`가 `festivals`에 UPSERT할 때, `utils.compute_progress_status()`(`festival_status_updater.py`와
동일한 규칙)로 그 자리에서 `progress_status`/`progress_status_updated_at`까지 같이 채웁니다.
그래서 API를 처음 호출해서 축제가 새로 들어오는 순간부터 이미 값이 채워져 있고, 새벽 6시
배치나 `main.py` 재실행을 기다릴 필요가 없습니다.

- 날짜 문자열은 `utils.parse_date_string()`으로 파싱합니다. `"2025-06-14"`, `"20250614"`,
  `"2025-06-14T00:00:00"`, `"2025-06-14 00:00:00"` 형식을 지원하고, 낯선 형식이면 에러 없이
  `None`으로 처리해서 `progress_status`만 `NULL`로 남기고 나머지 적재는 그대로 진행합니다.
- 실제로 로컬 Postgres에 예정/진행중/종료/날짜없음 4가지 케이스를 API 응답처럼 넣어서
  최초 INSERT 시점에 바로 올바른 값이 들어가는 것, 그리고 같은 축제를 다시 올려서(UPSERT의
  UPDATE 경로) 날짜가 바뀌면 `progress_status`도 같이 바뀌는 것까지 확인했습니다.

### 조회 예시

```sql
-- 지금 진행중인 축제만
SELECT festival_name, start_date, end_date, progress_status
FROM festivals
WHERE progress_status = 'ongoing'
ORDER BY end_date;

-- 상태별 개수
SELECT progress_status, COUNT(*) FROM festivals GROUP BY progress_status;
```

### 실제로 검증한 것

로컬 Postgres에 예정(미래 날짜)/진행중(오늘 포함 기간)/종료(과거 날짜) 축제를 각각 만들어서
`festival_status_updater.py`를 실제로 실행해 세 가지 상태가 정확히 계산되는 것, 재실행 시
바뀐 게 없으면 0건 UPDATE로 끝나는 것, 날짜를 바꾼 뒤 다시 실행하면 상태가 정확히
따라 바뀌는 것(`upcoming` → `ongoing`)까지 전부 확인했습니다.

## 관리자 이메일 인증 코드 (admin_email_verification)

관리자 회원가입/이메일 인증 등에서 쓸 랜덤 인증 코드를 저장하는 테이블입니다.
**이 파이프라인은 코드를 발급하거나 검증하지 않습니다** — 그건 나중에 만들 admin
백엔드의 책임이고, 여기서는 스키마 소유 + "만료된 코드 청소" 배치만 담당합니다.

```sql
CREATE TABLE admin_email_verification (
    verification_id  BIGSERIAL PRIMARY KEY,
    email             VARCHAR(255) NOT NULL,
    code              VARCHAR(10)  NOT NULL,
    purpose           VARCHAR(50)  NOT NULL DEFAULT 'signup',
    created_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    expires_at        TIMESTAMPTZ  NOT NULL DEFAULT now() + INTERVAL '15 minutes',
    verified_at       TIMESTAMPTZ,
    attempt_count     INTEGER      NOT NULL DEFAULT 0
);
```

- `expires_at`은 **행이 만들어지는 순간 자동으로 (지금 + 15분)**으로 채워집니다. admin
  백엔드는 INSERT할 때 이 컬럼을 따로 계산해서 넣을 필요 없이 `email`, `code`만 넣으면 됩니다.
- `admins` 테이블에 FK를 걸지 않았습니다 — 회원가입 전(아직 admin_id가 없는 상태)에도
  인증 코드를 발급해야 하기 때문입니다.
- `purpose`는 지금은 `signup` 하나만 쓰지만, 나중에 비밀번호 재설정 등으로 이 테이블을
  재사용할 걸 대비해서 미리 넣어뒀습니다.
- `attempt_count`는 무차별 대입(코드 여러 번 틀리기) 방지용으로 admin 백엔드가 검증
  실패할 때마다 +1 시켜서 쓰라고 만들어둔 컬럼입니다 (이 파이프라인은 안 건드립니다).
- 인덱스는 `(email, code)` 복합 인덱스(검증 조회용)와 `expires_at`(청소 배치용) 두 개입니다.

### 만료된 코드는 어떻게 지워지나

`festival_status_updater`와 완전히 같은 패턴입니다 — 별도 배치가 주기적으로 돌면서
`expires_at < now()`인 행을 실제로 DELETE합니다. 다만 15분짜리 데이터라 하루 한 번인
축제 상태 배치보다 훨씬 자주 돌아야 해서, **일부러 별도 스케줄로 분리**했습니다.

| | 담당 파일 | 권장 주기 |
|---|---|---|
| 축제 진행 상태 | `run_status_update.py` | 하루 1번 (새벽 6시) |
| 이메일 인증 코드 정리 | `run_verification_cleanup.py` | **15분마다** |

crontab 등록 예시 (기존 새벽 6시 줄에 아래 줄을 추가):
```bash
crontab -e
```
```bash
0 6 * * * cd /path/to/chookjibup_data_pipeline && /usr/bin/python3 run_status_update.py >> logs/status_update.log 2>&1
*/15 * * * * cd /path/to/chookjibup_data_pipeline && /usr/bin/python3 run_verification_cleanup.py >> logs/verification_cleanup.log 2>&1
```

`scheduler.py`(파이썬 자체 스케줄러)를 쓰신다면 이미 두 작업 다 등록돼 있어서 손댈 것 없이
`python3 scheduler.py`만 실행하시면 됩니다 (새벽 6시 작업 + 15분마다 작업 둘 다 자동으로 돕니다).

### 실제로 검증한 것

로컬 Postgres에 유효한 코드 1건 + 만료된 코드 2건(각각 발급 후 20분, 30분 지난 것)을
넣고 `admin_email_verification_cleaner.py`를 실제로 실행해서, **만료된 2건만 정확히
삭제되고 유효한 1건은 그대로 남는 것**까지 확인했습니다. `scheduler.py`에 새로 추가한
15분 주기 작업도 실제로 등록되고 시작 시점에 즉시 한 번 실행되는 것까지 확인했습니다.

## 실행 방법

1. `config.py`에서 `DB_CONFIG`, `API_CONFIG.service_key` 채우기 (`configexample.py` 복사해서 사용)
   ```bash
   cp configexample.py config.py
   ```
   DB는 미리 만들어두기만 하면 됩니다 (`createdb -U postgres festmap`). **스키마는 더 이상 손으로
   `psql -f schema.sql`을 실행할 필요 없이, `main.py`를 돌리면 `schema_loader`가 알아서 적용합니다.**

2. `data/` 폴더에 엑셀 파일 넣기
   - 파일명에 **4자리 연도(20xx)가 반드시 포함**되어야 합니다

3. 실행
   ```bash
   pip install -r requirements.txt
   # (apscheduler는 scheduler.py를 쓸 때만 필요합니다. crontab 방식만 쓴다면
   #  pip install psycopg2-binary requests openpyxl 만 해도 됩니다.)
   python main.py
   ```

몇 번을 다시 실행해도 안전합니다 — 테이블은 이미 있으면 건너뛰고, 축제/엑셀 데이터는
UPSERT라 중복 없이 최신 값으로 갱신됩니다.

## 매칭 결과 확인

```sql
-- 파일별 매칭 성공/실패 건수
SELECT source_file, match_status, COUNT(*)
FROM festival_visitor_excel
GROUP BY source_file, match_status;

-- 최종적으로 확인하고 싶은 건 이거
SELECT festival_name, road_address, visitor_2024_total, visitor_2025_total
FROM festivals
ORDER BY visitor_2025_total DESC NULLS LAST;
```

`NONE`(매칭 실패)이 많으면 `utils.normalize_festival_name`의 정규화 규칙을 강화하는 걸 고려하세요.
(현재는 공백/특수문자 제거까지만 처리 — "2026 OO축제"처럼 연도가 이름 앞에 붙거나 "제19회 OO축제"처럼 회차가 붙는 경우는 매칭되지 않습니다. 실제 파일 기준으로 이런 케이스가 축제의 20~46%나 돼서, 매칭률을 올리려면 이 정규화 로직 보강이 우선순위가 높습니다.)
