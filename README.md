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
├── utils.py                     # 공통 유틸 (날짜 파싱, 숫자 파싱, 축제명 정규화)
├── loaders/
│   ├── api_loader.py              # 공공데이터 API 호출 -> festivals에 UPSERT
│   ├── excel_schemas.py             # 연도별로 다른 엑셀 서식을 각각 파싱하는 파서 모음
│   └── excel_loader.py              # data/ 폴더 스캔, 연도별 파서로 라우팅 -> festival_visitor_excel에 UPSERT
├── matcher.py                         # 축제명 정규화 매칭 -> festivals에 방문객수 컬럼 UPDATE
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
   pip install psycopg2-binary requests openpyxl
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
