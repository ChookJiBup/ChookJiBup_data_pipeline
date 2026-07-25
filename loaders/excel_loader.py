import os
import re
import logging

import psycopg2.extras

from config import DATA_DIR
from db import get_conn
from loaders import excel_schemas

log = logging.getLogger(__name__)

SCHEMA_PARSERS = {
    2025: excel_schemas.parse_2025,
    2026: excel_schemas.parse_2026,
}

COLUMNS = [
    "source_file", "plan_year", "row_no", "sido_name", "sigungu_name",
    "festival_name", "festival_type", "event_place_name", "event_place_type",
    "place_sido", "place_sigungu", "place_eupmyeondong",
    "start_date", "end_date", "period_raw_text",
    "total_days", "hold_cycle", "hold_method", "first_held_year",
    "budget_total_mil", "budget_gov_mil", "budget_local_mil", "budget_etc_mil",
    "gov_support_dept", "visitor_year", "visitor_total", "visitor_domestic",
    "visitor_foreign", "visitor_measure_method", "org_name", "org_type",
    "manager_dept", "manager_name", "manager_contact", "note",
]


def find_plan_year(filename: str):
    m = re.search(r"(20\d{2})", filename)
    return int(m.group(1)) if m else None


def list_excel_files(data_dir=DATA_DIR):
    if not os.path.isdir(data_dir):
        return []
    return sorted(f for f in os.listdir(data_dir) if f.lower().endswith(".xlsx"))


def parse_plan(path: str, plan_year: int):
    parser = SCHEMA_PARSERS.get(plan_year)
    if parser is None:
        raise ValueError(
            f"plan_year={plan_year}에 대한 파서가 등록되어 있지 않습니다. "
            f"loaders/excel_schemas.py에 parse_{plan_year} 함수를 추가하고 "
            f"SCHEMA_PARSERS에 등록해주세요."
        )

    rows_out = parser(path, plan_year)
    visitor_year = plan_year - 1 
    for r in rows_out:
        r["visitor_year"] = visitor_year

    log.info(
        f"엑셀 파싱: {os.path.basename(path)} -> {len(rows_out)}건 "
        f"(plan_year={plan_year}, visitor_year={visitor_year})"
    )
    return rows_out


def save_plan(rows_out, source_file: str, plan_year: int):
    """festival_visitor_excel에 UPSERT 합니다.

    이전에는 "DELETE FROM ... WHERE source_file = %s" 로 파일 단위로 지운 다음
    다시 통째로 INSERT했는데(사실상 delete+insert 방식), 이제 진짜 UPSERT로 바꿨습니다.
    같은 (source_file, row_no) 조합이면 UPDATE, 없으면 INSERT합니다.

    matched_festival_id / match_status / matched_at은 데이터가 바뀌었을 수 있으니
    UPDATE될 때 초기화(NULL / 'NONE')해서, 뒤이어 돌아가는 matcher.py가 항상
    최신 데이터 기준으로 다시 매칭하도록 합니다.

    참고: 예전 DELETE 방식은 "같은 파일에서 이번엔 안 보이는 row_no"까지 자동으로
    지워졌지만, UPSERT는 새로 들어온 행만 갱신/추가하고 안 보이는 기존 행은 그대로
    남습니다. festival_visitor_excel은 다른 테이블이 FK로 참조하지 않는 원본 백업성
    테이블이라 큰 문제는 아니지만, 같은 파일을 행이 빠진 채로 다시 올리는 경우가
    있다면 이 부분도 정리 로직이 필요할 수 있습니다.
    """
    conn = get_conn()
    cur = conn.cursor()
    try:
        values = [
            tuple([source_file, plan_year] + [r[c] for c in COLUMNS[2:]])
            for r in rows_out
        ]

        update_cols = [c for c in COLUMNS if c not in ("source_file", "row_no")]
        update_clause = ", ".join(f"{c} = EXCLUDED.{c}" for c in update_cols)

        if values:
            psycopg2.extras.execute_values(
                cur,
                f"""
                INSERT INTO festival_visitor_excel ({', '.join(COLUMNS)})
                VALUES %s
                ON CONFLICT (source_file, row_no) DO UPDATE SET
                    {update_clause},
                    matched_festival_id = NULL,
                    match_status = 'NONE',
                    matched_at = NULL,
                    loaded_at = now()
                """,
                values,
            )
        conn.commit()
        log.info(f"festival_visitor_excel UPSERT 완료: {len(values)}건 (source_file={source_file})")
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()
        conn.close()


def run(data_dir=DATA_DIR):
    log.info("[Excel Loader] 시작")
    files = list_excel_files(data_dir)
    if not files:
        log.warning(f"{data_dir}에 xlsx 파일이 없습니다.")
        return []

    processed = []
    for fname in files:
        plan_year = find_plan_year(fname)
        if not plan_year:
            log.warning(f"'{fname}' 파일명에서 연도를 찾을 수 없어 건너뜁니다. (파일명에 20xx 형태 연도 필요)")
            continue
        if plan_year not in SCHEMA_PARSERS:
            log.warning(
                f"'{fname}' (plan_year={plan_year})에 대한 파서가 없어 건너뜁니다. "
                f"loaders/excel_schemas.py에 parse_{plan_year} 추가 필요."
            )
            continue

        path = os.path.join(data_dir, fname)
        rows_out = parse_plan(path, plan_year)
        save_plan(rows_out, fname, plan_year)
        processed.append((fname, plan_year))

    log.info(f"[Excel Loader] 완료 - 처리된 파일: {processed}")
    return processed
