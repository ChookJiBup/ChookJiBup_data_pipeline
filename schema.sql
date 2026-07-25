-- ============================================================
-- FestMap 서비스 스키마 (ERD 기반)
-- 대상 DB: PostgreSQL 14+
-- 작성 기준: 사용자 제공 ERD 이미지 + 기존 festival 파이프라인(festival_api_raw, festival_excel_plan) 통합
-- ============================================================

-- ------------------------------------------------------------
-- 0. 공통 ENUM / 트리거 함수
-- ------------------------------------------------------------

-- PostgreSQL은 CREATE TYPE에 IF NOT EXISTS를 지원하지 않아서, 재실행해도 에러 없이
-- 넘어가도록 DO 블록 + 예외 처리(duplicate_object)로 감쌌습니다.

-- 혼잡도 등급: 부스 혼잡도 / 축제 혼잡도 / 축제 방문객수, 3곳에서 공통으로 재사용
DO $$ BEGIN
    CREATE TYPE congestion_level AS ENUM ('crowded', 'normal', 'comfortable'); -- 혼잡 / 보통 / 여유
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- 엑셀-축제 매칭 상태 (기존 festival_name_match 로그 테이블을 festival_visitor_excel에 통합)
DO $$ BEGIN
    CREATE TYPE match_status_type AS ENUM ('EXACT', 'NORMALIZED', 'NONE');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- [추가] 축제 데이터 출처: 공공데이터 API로 들어온 것 vs 관리자가 직접 등록한 것
DO $$ BEGIN
    CREATE TYPE festival_source_type AS ENUM ('api', 'manual');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- [추가] 운영자 초대 상태
DO $$ BEGIN
    CREATE TYPE invite_status_type AS ENUM ('pending', 'accepted', 'rejected', 'canceled');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- [추가] 부스 혼잡도 수정자 유형 — 관리자/운영자(둘 다 admins 테이블 소속) 또는 알바생(festival_staff)
DO $$ BEGIN
    CREATE TYPE modifier_type AS ENUM ('admin', 'staff');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- [추가] 로드맵 작성 방식: 팜플렛 이미지를 그대로 업로드 vs 제공 아이콘으로 직접 제작
DO $$ BEGIN
    CREATE TYPE roadmap_type AS ENUM ('uploaded_image', 'icon_builder');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- updated_at 자동 갱신 트리거 함수 (테이블마다 매번 UPDATE 시각을 애플리케이션에서 챙기지 않아도 되도록)
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- ------------------------------------------------------------
-- 1. users (사용자)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS users (
    user_id                 BIGSERIAL PRIMARY KEY,

    kakao_id                BIGINT NOT NULL,                 -- 카카오 고유 ID
    nickname                VARCHAR(100) NOT NULL,           -- 닉네임

    profile_image_url       TEXT,                            -- 프로필 이미지
    thumbnail_image_url     TEXT,                            -- 썸네일 이미지

    email                   VARCHAR(255),                    -- 이메일(선택 동의)
    gender                  VARCHAR(10),                     -- male / female
    birthyear               CHAR(4),                         -- YYYY
    birthday                CHAR(4),                         -- MMDD
    phone_number            VARCHAR(30),                     -- 전화번호

    joined_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),

    is_withdrawn            BOOLEAN NOT NULL DEFAULT false,
    withdrawn_at            TIMESTAMPTZ,

    CONSTRAINT uq_users_kakao_id UNIQUE(kakao_id),
    CONSTRAINT uq_users_email UNIQUE(email)
);
-- ------------------------------------------------------------
-- 2. admins (관리자)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS admins (
    admin_id        BIGSERIAL PRIMARY KEY,
    email           VARCHAR(255) NOT NULL,                  -- 관리자 이메일id
    password_hash   VARCHAR(255) NOT NULL,                  -- 비밀번호
    name            VARCHAR(50)  NOT NULL,                  -- 이름
    birth_date      DATE,                                   -- 생년월일
    department      VARCHAR(100),                           -- 소속 부서 (공무원)
    joined_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),    -- 가입 일자
    is_withdrawn    BOOLEAN      NOT NULL DEFAULT false,    -- 탈퇴 여부
    withdrawn_at    TIMESTAMPTZ,                            -- [추가]
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),    -- [추가]
    CONSTRAINT uq_admins_email UNIQUE (email)
);

DROP TRIGGER IF EXISTS trg_admins_updated_at ON admins;
CREATE TRIGGER trg_admins_updated_at
    BEFORE UPDATE ON admins
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ------------------------------------------------------------
-- 3. festivals (축제 api) — 이전 festival_api_raw 파이프라인의 마스터 테이블
--    다른 모든 테이블이 festival_id를 참조하는 허브 테이블
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS festivals (
    festival_id         BIGSERIAL PRIMARY KEY,
    festival_name        TEXT NOT NULL,                     -- 축제명
    event_place           TEXT,                              -- 개최장소
    start_date              DATE,                             -- 축제시작일자
    end_date                 DATE,                             -- 축제종료일자
    content                   TEXT,                             -- 축제내용
    supervisor_org             TEXT,                             -- 주관기관명
    host_org                     TEXT,                             -- 주최기관명
    sponsor_org                   TEXT,                             -- 후원기관명
    phone_number                   TEXT,                             -- 전화번호
    homepage_url                     TEXT,                             -- 홈페이지주소
    related_info                       TEXT,                             -- 관련정보
    road_address                         TEXT,                             -- 소재지도로명주소
    jibun_address                          TEXT,                             -- 소재지지번주소
    latitude                                 NUMERIC(10,6),                    -- 위도
    longitude                                  NUMERIC(10,6),                    -- 경도
    api_reference_date                           DATE,                             -- API 데이터기준일자
    raw_payload                                    JSONB,                            -- API 원본 응답 백업
    source_type                                      festival_source_type NOT NULL DEFAULT 'api',  -- [추가] api / manual
    created_by_admin_id                                BIGINT REFERENCES admins(admin_id),           -- [추가] manual일 때만 값 존재 (누가 직접 등록했는지)
    api_last_seen_at                                     TIMESTAMPTZ,                          -- [추가] api_loader가 이 축제를 마지막으로 확인한 시각 (아래 참고)
    loaded_at                                              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                                               TIMESTAMPTZ NOT NULL DEFAULT now(),  -- [추가] 파이프라인 재적재 시각
    CONSTRAINT chk_festivals_source_admin CHECK (
        (source_type = 'manual' AND created_by_admin_id IS NOT NULL) OR
        (source_type = 'api'    AND created_by_admin_id IS NULL)
    )
    -- 참고: visitor_YYYY_total/domestic/foreign 컬럼은 여기 정의하지 않습니다.
    --      pipeline(matcher.py)이 festival_visitor_excel 매칭 시점에
    --      ALTER TABLE ... ADD COLUMN IF NOT EXISTS 로 연도별 컬럼을 자동 추가하는 방식을 그대로 유지합니다.
    --
    -- 참고: api_loader.py는 더 이상 TRUNCATE를 하지 않고 UPSERT로 동작합니다.
    --      (festival_wishlist/festival_review 등 다른 테이블이 festival_id를 FK로 참조하기
    --       시작했기 때문에, 매번 TRUNCATE ... CASCADE로 지웠다가 새로 만들면
    --       사용자 찜/리뷰/대시보드가 전부 날아갑니다.)
    --      다만 data.go.kr API가 축제별 고유 ID를 안정적으로 내려주지 않아서,
    --      아래 ux_festivals_api_natural_key(축제명+시작일+주소)를 대체 키로 사용합니다.
    --      API 쪽에서 주소 표기가 살짝 바뀌거나 날짜가 수정되는 경우 같은 축제가
    --      새 행으로 다시 들어갈 수 있다는 한계가 있으니, 매칭 실패가 잦으면
    --      이 자연키를 조정하거나 API 응답에서 더 안정적인 필드가 있는지 확인해야 합니다.
);

-- [추가] api_loader UPSERT용 자연키 (source_type='api'인 행에만 적용).
--       NULL은 유니크 비교에서 항상 "다른 값"으로 취급되므로 COALESCE로 감싸서
--       start_date/road_address가 비어있는 축제끼리도 정상적으로 충돌 판정되게 했습니다.
CREATE UNIQUE INDEX IF NOT EXISTS ux_festivals_api_natural_key
    ON festivals (festival_name, (COALESCE(start_date, DATE '1900-01-01')), (COALESCE(road_address, '')))
    WHERE source_type = 'api';

DROP TRIGGER IF EXISTS trg_festivals_updated_at ON festivals;
CREATE TRIGGER trg_festivals_updated_at
    BEFORE UPDATE ON festivals
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ------------------------------------------------------------
-- 4. festival_wishlist (축제 찜리스트)
--    [수정] 원본 ERD는 festival_id를 PK로 잡아서 "축제 1개당 찜 1건"만 가능한 구조였습니다.
--           실제로는 여러 사용자가 같은 축제를 각자 찜할 수 있어야 하므로
--           자체 surrogate PK(wishlist_id) + (user_id, festival_id) UNIQUE로 변경했습니다.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS festival_wishlist (
    wishlist_id     BIGSERIAL PRIMARY KEY,
    user_id         BIGINT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    festival_id     BIGINT NOT NULL REFERENCES festivals(festival_id) ON DELETE CASCADE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),  -- [추가] 찜한 시각
    CONSTRAINT uq_wishlist_user_festival UNIQUE (user_id, festival_id)
);


-- ------------------------------------------------------------
-- 5. festival_visitor_excel (축제 방문객 엑셀) — 이전 festival_excel_plan
--    [추가] matched_festival_id / match_status / matched_at
--           기존에는 festival_name_match 라는 별도 로그 테이블에서 매칭 결과를 관리했는데,
--           ERD에는 그 테이블이 없어서 매칭 결과를 이 테이블 컬럼으로 직접 흡수했습니다.
--           festivals 테이블과의 실제 연결선(FK)도 이렇게 생깁니다.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS festival_visitor_excel (
    excel_plan_id           BIGSERIAL PRIMARY KEY,
    source_file               TEXT NOT NULL,                 -- 원본 파일명
    plan_year                   INTEGER NOT NULL,              -- 엑셀 기준연도 (파일명의 연도)
    row_no                        INTEGER,                       -- 연번
    sido_name                      TEXT,
    sigungu_name                     TEXT,
    festival_name                      TEXT NOT NULL,             -- 엑셀상의 축제명 (원문 그대로 보존)
    festival_type                        TEXT,
    event_place_name                       TEXT,
    event_place_type                         TEXT,
    place_sido                                 TEXT,
    place_sigungu                                TEXT,
    place_eupmyeondong                             TEXT,
    start_date                                       DATE,
    end_date                                           DATE,
    period_raw_text                                      TEXT,
    total_days                                             INTEGER,
    hold_cycle                                               TEXT,
    hold_method                                                TEXT,
    first_held_year                                              INTEGER,
    budget_total_mil                                               NUMERIC(12,2),
    budget_gov_mil                                                   NUMERIC(12,2),
    budget_local_mil                                                   NUMERIC(12,2),
    budget_etc_mil                                                       NUMERIC(12,2),
    gov_support_dept                                                       TEXT,
    visitor_year                                                             INTEGER,      -- 방문객수 기준연도 (plan_year - 1)
    visitor_total                                                              NUMERIC(14,0),
    visitor_domestic                                                             NUMERIC(14,0),
    visitor_foreign                                                                NUMERIC(14,0),
    visitor_measure_method                                                           TEXT,
    org_name                                                                           TEXT,
    org_type                                                                             TEXT,
    manager_dept                                                                           TEXT,
    manager_name                                                                             TEXT,
    manager_contact                                                                            TEXT,
    note                                                                                         TEXT,
    matched_festival_id     BIGINT REFERENCES festivals(festival_id) ON DELETE SET NULL,  -- [추가]
    match_status               match_status_type NOT NULL DEFAULT 'NONE',                   -- [추가]
    matched_at                    TIMESTAMPTZ,                                                 -- [추가]
    loaded_at                       TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_excel_source_row UNIQUE (source_file, row_no)
);


-- ------------------------------------------------------------
-- 6. festival_dashboard (축제 대시보드) — festival과 1:1
-- ------------------------------------------------------------
-- [수정] roadmap_image_url은 festival_roadmap 테이블로 분리했습니다 (아래 6-1번 참고).
--        대시보드는 "이 축제를 누가 관리하는가"에 집중하고, 로드맵은 별도로 계속 편집되는
--        독립적인 데이터라 성격이 달라 분리하는 게 맞다고 판단했습니다.
CREATE TABLE IF NOT EXISTS festival_dashboard (
    festival_id         BIGINT PRIMARY KEY REFERENCES festivals(festival_id) ON DELETE CASCADE,
    admin_id              BIGINT NOT NULL REFERENCES admins(admin_id),   -- 관리자 id (축제를 등록/신청한 관리자)
    created_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),          -- [추가]
    updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now()           -- [추가]
);

DROP TRIGGER IF EXISTS trg_dashboard_updated_at ON festival_dashboard;
CREATE TRIGGER trg_dashboard_updated_at
    BEFORE UPDATE ON festival_dashboard
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ------------------------------------------------------------
-- 6-1. roadmap_icon_type (로드맵 아이콘 카탈로그) [신규 추가]
--     "우리가 제공하는 부스 아이콘/화장실 아이콘 등"이 플랫폼이 미리 정의해둔
--     고정 세트라서, ENUM보다는 마스터 테이블로 만들었습니다. 아이콘 이미지 URL을
--     들고 있어야 하고 새 아이콘 종류가 계속 추가될 수 있어서 ENUM으로는 대응이 어렵습니다.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS roadmap_icon_type (
    icon_type_id      BIGSERIAL PRIMARY KEY,
    code                 VARCHAR(50) NOT NULL,      -- 'booth' / 'restroom' / 'parking' / 'entrance' 등
    name                    VARCHAR(100) NOT NULL,     -- 화면 표시용 이름 ('화장실', '주차장' ...)
    icon_image_url             TEXT NOT NULL,             -- 아이콘 이미지 에셋 주소
    is_active                     BOOLEAN NOT NULL DEFAULT true,
    created_at                       TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_icon_type_code UNIQUE (code)
);

-- ------------------------------------------------------------
-- 6-2. festival_roadmap (축제 로드맵) [신규 추가, festival과 1:1]
--     로드맵을 만드는 두 가지 방식을 하나의 테이블에서 roadmap_type으로 구분합니다.
--     - uploaded_image: 팜플렛 사진을 그대로 올리는 방식 -> base_image_url만 사용
--     - icon_builder  : 제공 아이콘을 배치해서 직접 제작하는 방식
--                       -> base_image_url은 배경(바닥 도면) 트레이싱용으로 선택적으로 사용,
--                          실제 아이콘 배치는 roadmap_icon_placement에 별도 저장
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS festival_roadmap (
    festival_id          BIGINT PRIMARY KEY REFERENCES festivals(festival_id) ON DELETE CASCADE,
    roadmap_type            roadmap_type NOT NULL DEFAULT 'uploaded_image',
    base_image_url             TEXT,                                   -- 업로드 이미지 or 아이콘 배치용 배경 이미지
    canvas_width                  INTEGER,                                -- icon_builder용 캔버스 가로 크기(px)
    canvas_height                    INTEGER,                                -- icon_builder용 캔버스 세로 크기(px)
    created_by_admin_id                 BIGINT NOT NULL REFERENCES admins(admin_id),  -- 로드맵 작성자(관리자 또는 운영자)
    created_at                             TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                                TIMESTAMPTZ NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_festival_roadmap_updated_at ON festival_roadmap;
CREATE TRIGGER trg_festival_roadmap_updated_at
    BEFORE UPDATE ON festival_roadmap
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ------------------------------------------------------------
-- 7. festival_congestion (축제 혼잡도)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS festival_congestion (
    congestion_id        BIGSERIAL PRIMARY KEY,
    festival_id             BIGINT NOT NULL REFERENCES festivals(festival_id) ON DELETE CASCADE,
    modifier_admin_id         BIGINT REFERENCES admins(admin_id) ON DELETE SET NULL,  -- 수정자 id
                                                                                        -- (관리자 삭제돼도 이력은 남도록 SET NULL)
    congestion_level             congestion_level NOT NULL,                          -- ENUM(혼잡/보통/여유)
    created_at                      TIMESTAMPTZ NOT NULL DEFAULT now(),                 -- [추가]
    updated_at                         TIMESTAMPTZ NOT NULL DEFAULT now()                  -- 수정일자
);

DROP TRIGGER IF EXISTS trg_festival_congestion_updated_at ON festival_congestion;
CREATE TRIGGER trg_festival_congestion_updated_at
    BEFORE UPDATE ON festival_congestion
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ------------------------------------------------------------
-- 8. booth_info (부스 정보)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS booth_info (
    booth_id           BIGSERIAL PRIMARY KEY,
    festival_id           BIGINT NOT NULL REFERENCES festivals(festival_id) ON DELETE CASCADE,
    booth_name              TEXT NOT NULL,                       -- 부스 이름
    booth_content              TEXT,                                -- 부스 내용
    booth_location                TEXT,                                -- 부스 위치
    created_at                       TIMESTAMPTZ NOT NULL DEFAULT now(),   -- 생성일자
    updated_at                          TIMESTAMPTZ NOT NULL DEFAULT now()    -- 수정일자
);

DROP TRIGGER IF EXISTS trg_booth_info_updated_at ON booth_info;
CREATE TRIGGER trg_booth_info_updated_at
    BEFORE UPDATE ON booth_info
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ------------------------------------------------------------
-- 8-1. roadmap_icon_placement (로드맵에 배치된 아이콘들) [신규 추가]
--     icon_builder 모드에서 캔버스 위에 놓인 아이콘 하나하나가 이 테이블의 한 행입니다.
--     related_booth_id를 넣어서, 부스 아이콘을 배치할 때 실제 booth_info 레코드와
--     연결할 수 있게 했습니다 (예: 부스 아이콘 클릭 -> 해당 부스 상세/혼잡도로 이동).
--     화장실/주차장처럼 특정 부스와 무관한 아이콘은 related_booth_id를 NULL로 둡니다.
--     booth_info보다 뒤에 있어야 related_booth_id FK가 성립하므로 여기 위치시켰습니다.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS roadmap_icon_placement (
    placement_id          BIGSERIAL PRIMARY KEY,
    festival_id              BIGINT NOT NULL REFERENCES festival_roadmap(festival_id) ON DELETE CASCADE,
    icon_type_id                BIGINT NOT NULL REFERENCES roadmap_icon_type(icon_type_id),
    related_booth_id               BIGINT REFERENCES booth_info(booth_id) ON DELETE SET NULL,  -- 부스 아이콘일 때만 값 존재
    position_x                        NUMERIC(8,2) NOT NULL,           -- 캔버스 내 x좌표 (또는 %, 앱에서 정의)
    position_y                           NUMERIC(8,2) NOT NULL,           -- 캔버스 내 y좌표
    rotation_deg                            NUMERIC(5,2) NOT NULL DEFAULT 0,
    label                                       TEXT,                            -- 커스텀 라벨 (예: '화장실 A')
    created_by_admin_id                            BIGINT NOT NULL REFERENCES admins(admin_id),
    created_at                                        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                                           TIMESTAMPTZ NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_roadmap_icon_placement_updated_at ON roadmap_icon_placement;
CREATE TRIGGER trg_roadmap_icon_placement_updated_at
    BEFORE UPDATE ON roadmap_icon_placement
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ------------------------------------------------------------
-- 8-2. festival_staff (축제 알바생)
--     booth_congestion이 이 테이블을 참조하기 때문에 booth_congestion보다 앞에 배치했습니다.
--     [추가] festival_id — 원본 ERD엔 알바생이 어느 축제 소속인지 연결할 컬럼이 없었습니다.
--            축제별로 계정을 분리 관리해야 하므로 festivals FK를 추가했습니다.
--     [추가] is_active — 알바 계약 종료 시 계정을 삭제하지 않고 비활성화만 하기 위한 플래그
--            (users/admins의 '탈퇴 여부'와 같은 패턴)
--     created_by_admin_id는 "관리자 또는 운영자가 추가"를 그대로 커버합니다 — 운영자도 결국
--     festival_operator를 통해 배정된 admins 테이블의 한 행이라, FK 타입을 나눌 필요가 없습니다.
--     (그 admin_id가 이 festival의 대시보드 관리자인지 / 운영자 명단에 있는지는 앱 로직에서 검증)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS festival_staff (
    staff_id                 BIGSERIAL PRIMARY KEY,
    festival_id                 BIGINT NOT NULL REFERENCES festivals(festival_id) ON DELETE CASCADE,  -- [추가]
    login_id                       VARCHAR(50) NOT NULL,                     -- 접속 id
    password_hash                     VARCHAR(255) NOT NULL,                    -- 접속 비밀번호
    name                                 VARCHAR(50) NOT NULL,                     -- 이름
    birth_date                              DATE,                                     -- 생년월일
    phone_number                               VARCHAR(20),                              -- 전화번호
    is_active                                     BOOLEAN NOT NULL DEFAULT true,           -- [추가]
    created_by_admin_id                              BIGINT NOT NULL REFERENCES admins(admin_id),  -- 추가한사람 id (관리자 또는 운영자)
    created_at                                          TIMESTAMPTZ NOT NULL DEFAULT now(),     -- 생성일자
    CONSTRAINT uq_staff_login_id UNIQUE (login_id)
);


-- ------------------------------------------------------------
-- 9. booth_congestion (부스 혼잡도)
--     [수정] 수정자가 admins(관리자/운영자) 뿐 아니라 festival_staff(알바생)일 수도 있어서
--     "둘 중 하나를 가리키는" 다형성 구조로 바꿨습니다. modifier_type으로 어느 쪽인지 밝히고,
--     CHECK 제약으로 타입과 실제 채워진 FK 컬럼이 항상 일치하도록 강제합니다.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS booth_congestion (
    congestion_id         BIGSERIAL PRIMARY KEY,
    booth_id                 BIGINT NOT NULL REFERENCES booth_info(booth_id) ON DELETE CASCADE,
    modifier_type               modifier_type NOT NULL,                                  -- [추가] 'admin' | 'staff'
    modifier_admin_id              BIGINT REFERENCES admins(admin_id) ON DELETE SET NULL,      -- modifier_type='admin'일 때만
    modifier_staff_id                 BIGINT REFERENCES festival_staff(staff_id) ON DELETE SET NULL, -- [추가] modifier_type='staff'일 때만
    wait_minutes                         INTEGER CHECK (wait_minutes >= 0),                          -- 혼잡도 시간(몇분)
    congestion_level                        congestion_level NOT NULL,                                 -- ENUM(혼잡/보통/여유)
    created_at                                 TIMESTAMPTZ NOT NULL DEFAULT now(),                        -- [추가]
    updated_at                                    TIMESTAMPTZ NOT NULL DEFAULT now(),                        -- 수정일자
    CONSTRAINT chk_booth_congestion_modifier CHECK (
        (modifier_type = 'admin' AND modifier_admin_id IS NOT NULL AND modifier_staff_id IS NULL) OR
        (modifier_type = 'staff' AND modifier_staff_id IS NOT NULL AND modifier_admin_id IS NULL)
    )
);

DROP TRIGGER IF EXISTS trg_booth_congestion_updated_at ON booth_congestion;
CREATE TRIGGER trg_booth_congestion_updated_at
    BEFORE UPDATE ON booth_congestion
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ------------------------------------------------------------
-- 10. festival_review (축제 리뷰)
--     [추가] rating — 별점 없이 텍스트만 있으면 정량 집계(평균 평점 등)가 불가능해서 추가
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS festival_review (
    review_id       BIGSERIAL PRIMARY KEY,
    user_id           BIGINT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    festival_id         BIGINT NOT NULL REFERENCES festivals(festival_id) ON DELETE CASCADE,
    rating                 SMALLINT CHECK (rating BETWEEN 1 AND 5),  -- [추가] 별점
    content                   TEXT NOT NULL,                            -- 리뷰내용
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),       -- 작성 일자
    updated_at                     TIMESTAMPTZ NOT NULL DEFAULT now()        -- 수정일자
);

DROP TRIGGER IF EXISTS trg_festival_review_updated_at ON festival_review;
CREATE TRIGGER trg_festival_review_updated_at
    BEFORE UPDATE ON festival_review
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ------------------------------------------------------------
-- 11. festival_visitor_count (축제 방문객수) — 일자별 실측/추정 방문객수
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS festival_visitor_count (
    visitor_count_id     BIGSERIAL PRIMARY KEY,
    festival_id             BIGINT NOT NULL REFERENCES festivals(festival_id) ON DELETE CASCADE,
    visit_date                 DATE NOT NULL,                        -- 일자
    visitor_count                 INTEGER CHECK (visitor_count >= 0),   -- 방문객수
    congestion_level                 congestion_level,                    -- ENUM(혼잡/보통/여유)
    created_at                          TIMESTAMPTZ NOT NULL DEFAULT now(),   -- [추가]
    CONSTRAINT uq_visitor_count_festival_date UNIQUE (festival_id, visit_date)  -- [추가] 같은날 중복적재 방지
);


-- ------------------------------------------------------------
-- 12. festival_result (축제 결과표) — festival과 1:1
--     원본 메모가 "일자별 혼잡도 흐름 + 부스 혼잡도 + 리뷰, 예정"으로 스펙 미확정 상태라
--     각 영역을 JSONB로 유연하게 잡았습니다. 최종 집계 포맷이 정해지면
--     정규화된 컬럼/테이블로 다시 나누는 걸 권장합니다.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS festival_result (
    festival_id                 BIGINT PRIMARY KEY REFERENCES festivals(festival_id) ON DELETE CASCADE,
    congestion_flow                JSONB,   -- [추가/구체화] 일자별 축제 혼잡도 흐름
    booth_congestion_summary          JSONB,   -- [추가/구체화] 부스별 혼잡도 요약
    review_summary                       JSONB,   -- [추가/구체화] 사용자 리뷰 요약(평균 별점 등)
    generated_at                            TIMESTAMPTZ NOT NULL DEFAULT now()
);


-- ------------------------------------------------------------
-- 13. festival_operator_invite (축제 운영자 초대) [신규 추가]
--     "운영자는 반드시 관리자 회원가입을 한 사람만 초대 가능" 요구사항 반영.
--     invitee_admin_id가 admins 테이블을 FK로 참조하기 때문에
--     이미 admins에 가입돼 있는 사람만 초대 대상으로 지정할 수 있습니다.
--     수락(accepted)되는 순간 festival_operator에 실제 배정 레코드를 자동 생성합니다(아래 트리거).
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS festival_operator_invite (
    invite_id           BIGSERIAL PRIMARY KEY,
    festival_id            BIGINT NOT NULL REFERENCES festivals(festival_id) ON DELETE CASCADE,
    inviter_admin_id          BIGINT NOT NULL REFERENCES admins(admin_id),   -- 초대한 사람 (해당 축제 관리자/운영자)
    invitee_admin_id            BIGINT NOT NULL REFERENCES admins(admin_id), -- 초대받는 사람 (반드시 기존 관리자 회원)
    status                          invite_status_type NOT NULL DEFAULT 'pending',
    invited_at                        TIMESTAMPTZ NOT NULL DEFAULT now(),
    responded_at                        TIMESTAMPTZ,                          -- 수락/거절 처리 시각
    CONSTRAINT chk_invite_not_self CHECK (inviter_admin_id <> invitee_admin_id)
);

-- 같은 축제에 같은 사람 대상으로 pending 초대가 중복 생성되는 것만 방지 (거절/취소된 건 재초대 가능해야 하므로 부분 유니크 인덱스로 처리)
CREATE UNIQUE INDEX IF NOT EXISTS uq_invite_pending_festival_invitee
    ON festival_operator_invite (festival_id, invitee_admin_id)
    WHERE status = 'pending';


-- ------------------------------------------------------------
-- 14. festival_operator (축제 운영자) — 관리자와 축제의 N:M 매핑 (수락 완료된 최종 명단)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS festival_operator (
    operator_id       BIGSERIAL PRIMARY KEY,
    admin_id             BIGINT NOT NULL REFERENCES admins(admin_id) ON DELETE CASCADE,
    festival_id             BIGINT NOT NULL REFERENCES festivals(festival_id) ON DELETE CASCADE,
    invite_id                BIGINT REFERENCES festival_operator_invite(invite_id),  -- [추가] 어떤 초대를 통해 들어왔는지 추적
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_operator_admin_festival UNIQUE (admin_id, festival_id)  -- [추가] 중복 배정 방지
);

-- 초대가 수락되는 순간 festival_operator에 정식 배정 레코드를 자동 생성하는 트리거
CREATE OR REPLACE FUNCTION promote_invite_to_operator()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status = 'accepted' AND OLD.status IS DISTINCT FROM 'accepted' THEN
        INSERT INTO festival_operator (admin_id, festival_id, invite_id)
        VALUES (NEW.invitee_admin_id, NEW.festival_id, NEW.invite_id)
        ON CONFLICT (admin_id, festival_id) DO NOTHING;
        NEW.responded_at := now();
    ELSIF NEW.status IN ('rejected', 'canceled') AND OLD.status IS DISTINCT FROM NEW.status THEN
        NEW.responded_at := now();
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_promote_invite_to_operator ON festival_operator_invite;
CREATE TRIGGER trg_promote_invite_to_operator
    BEFORE UPDATE ON festival_operator_invite
    FOR EACH ROW EXECUTE FUNCTION promote_invite_to_operator();




-- ============================================================
-- 인덱스
-- PostgreSQL은 PK에는 자동으로 인덱스를 만들지만 FK 컬럼에는 만들어주지 않으므로
-- JOIN/조회에 쓰이는 FK 컬럼들은 전부 명시적으로 인덱스를 추가합니다.
-- ============================================================

-- festivals: 이름 검색 및 엑셀 매칭용
CREATE INDEX IF NOT EXISTS idx_festivals_name ON festivals (festival_name);

-- festival_wishlist
CREATE INDEX IF NOT EXISTS idx_wishlist_festival ON festival_wishlist (festival_id);
-- (user_id는 uq_wishlist_user_festival 복합 유니크의 선두 컬럼이라 이미 인덱스 효과가 있음)

-- festival_visitor_excel
CREATE INDEX IF NOT EXISTS idx_excel_plan_year ON festival_visitor_excel (plan_year);
CREATE INDEX IF NOT EXISTS idx_excel_festival_name ON festival_visitor_excel (festival_name);
CREATE INDEX IF NOT EXISTS idx_excel_matched_festival ON festival_visitor_excel (matched_festival_id);
CREATE INDEX IF NOT EXISTS idx_excel_match_status ON festival_visitor_excel (match_status);

-- festivals
CREATE INDEX IF NOT EXISTS idx_festivals_created_by ON festivals (created_by_admin_id);  -- [추가] source_type='manual' 축제 조회용

-- festival_dashboard
CREATE INDEX IF NOT EXISTS idx_dashboard_admin ON festival_dashboard (admin_id);

-- roadmap_icon_type
CREATE INDEX IF NOT EXISTS idx_icon_type_active ON roadmap_icon_type (is_active);  -- [추가]

-- festival_roadmap
CREATE INDEX IF NOT EXISTS idx_roadmap_created_by ON festival_roadmap (created_by_admin_id);  -- [추가]

-- roadmap_icon_placement
CREATE INDEX IF NOT EXISTS idx_roadmap_placement_festival ON roadmap_icon_placement (festival_id);  -- [추가]
CREATE INDEX IF NOT EXISTS idx_roadmap_placement_icon_type ON roadmap_icon_placement (icon_type_id);  -- [추가]
CREATE INDEX IF NOT EXISTS idx_roadmap_placement_booth ON roadmap_icon_placement (related_booth_id);  -- [추가]

-- festival_congestion
CREATE INDEX IF NOT EXISTS idx_festival_congestion_festival ON festival_congestion (festival_id);
CREATE INDEX IF NOT EXISTS idx_festival_congestion_modifier ON festival_congestion (modifier_admin_id);

-- booth_info
CREATE INDEX IF NOT EXISTS idx_booth_info_festival ON booth_info (festival_id);

-- festival_staff
CREATE INDEX IF NOT EXISTS idx_staff_festival ON festival_staff (festival_id);
CREATE INDEX IF NOT EXISTS idx_staff_created_by ON festival_staff (created_by_admin_id);

-- booth_congestion
CREATE INDEX IF NOT EXISTS idx_booth_congestion_booth ON booth_congestion (booth_id);
CREATE INDEX IF NOT EXISTS idx_booth_congestion_modifier_admin ON booth_congestion (modifier_admin_id);  -- [수정] 컬럼명 변경 반영
CREATE INDEX IF NOT EXISTS idx_booth_congestion_modifier_staff ON booth_congestion (modifier_staff_id);  -- [추가]

-- festival_review
CREATE INDEX IF NOT EXISTS idx_review_festival ON festival_review (festival_id);
CREATE INDEX IF NOT EXISTS idx_review_user ON festival_review (user_id);

-- festival_visitor_count
CREATE INDEX IF NOT EXISTS idx_visitor_count_festival ON festival_visitor_count (festival_id);
-- (festival_id, visit_date)는 uq_visitor_count_festival_date 복합 유니크가 이미 커버

-- festival_operator_invite
CREATE INDEX IF NOT EXISTS idx_invite_festival ON festival_operator_invite (festival_id);  -- [추가]
CREATE INDEX IF NOT EXISTS idx_invite_inviter ON festival_operator_invite (inviter_admin_id);  -- [추가]
CREATE INDEX IF NOT EXISTS idx_invite_invitee ON festival_operator_invite (invitee_admin_id);  -- [추가]

-- festival_operator
CREATE INDEX IF NOT EXISTS idx_operator_festival ON festival_operator (festival_id);
CREATE INDEX IF NOT EXISTS idx_operator_invite ON festival_operator (invite_id);  -- [추가]
-- (admin_id는 uq_operator_admin_festival 복합 유니크의 선두 컬럼이라 이미 인덱스 효과가 있음)

-- JSONB 컬럼은 나중에 내부 키로 검색/필터링할 일이 생기면 GIN 인덱스를 추가하세요.
-- 예) CREATE INDEX IF NOT EXISTS idx_festivals_raw_payload_gin ON festivals USING GIN (raw_payload);
-- 예) CREATE INDEX IF NOT EXISTS idx_festival_result_congestion_flow_gin ON festival_result USING GIN (congestion_flow);
