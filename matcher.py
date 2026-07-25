import logging

from psycopg2 import sql

from db import get_conn
from utils import normalize_festival_name

log = logging.getLogger(__name__)


def visitor_columns(visitor_year: int):
    return (
        f"visitor_{visitor_year}_total",
        f"visitor_{visitor_year}_domestic",
        f"visitor_{visitor_year}_foreign",
    )


def ensure_visitor_columns(cur, visitor_year: int):
    for col in visitor_columns(visitor_year):
        cur.execute(
            sql.SQL("ALTER TABLE festivals ADD COLUMN IF NOT EXISTS {} NUMERIC(14,0)")
            .format(sql.Identifier(col))
        )


def match_source_file(source_file: str, plan_year: int):
    """festival_visitor_excel의 축제명을 festivals와 매칭해서
    festival_visitor_excel.matched_festival_id / match_status / matched_at을 채우고,
    매칭 성공분은 festivals.visitor_{visitor_year}_total/domestic/foreign에도 반영합니다.

    예전엔 매칭 결과를 festival_name_match라는 별도 로그 테이블에 저장했는데,
    지금 스키마는 그 정보를 festival_visitor_excel 컬럼으로 직접 갖고 있어서
    (matched_festival_id / match_status / matched_at) 별도 테이블이 필요 없습니다.
    """
    visitor_year = plan_year - 1
    total_col, dom_col, for_col = visitor_columns(visitor_year)

    conn = get_conn()
    cur = conn.cursor()
    try:
        ensure_visitor_columns(cur, visitor_year)

        cur.execute("SELECT festival_id, festival_name FROM festivals")
        festival_rows = cur.fetchall()
        norm_to_festival = {}
        exact_to_festival = {}
        for festival_id, name in festival_rows:
            norm_to_festival.setdefault(normalize_festival_name(name), []).append(festival_id)
            exact_to_festival.setdefault(name, []).append(festival_id)

        cur.execute(
            """
            SELECT excel_plan_id, festival_name, visitor_total, visitor_domestic, visitor_foreign
            FROM festival_visitor_excel
            WHERE source_file = %s
            """,
            (source_file,),
        )
        excel_rows = cur.fetchall()

        match_update_stmt = """
            UPDATE festival_visitor_excel
            SET matched_festival_id = %s, match_status = %s, matched_at = now()
            WHERE excel_plan_id = %s
        """
        visitor_update_stmt = sql.SQL(
            "UPDATE festivals SET {t} = %s, {d} = %s, {f} = %s WHERE festival_id = %s"
        ).format(t=sql.Identifier(total_col), d=sql.Identifier(dom_col), f=sql.Identifier(for_col))

        exact_cnt = norm_cnt = none_cnt = 0

        for excel_id, ex_name, v_total, v_dom, v_for in excel_rows:
            festival_id = None
            status = "NONE"

            if ex_name in exact_to_festival:
                festival_id = exact_to_festival[ex_name][0]
                status = "EXACT"
                exact_cnt += 1
            else:
                norm_name = normalize_festival_name(ex_name)
                candidates = norm_to_festival.get(norm_name)
                if candidates:
                    festival_id = candidates[0]
                    status = "NORMALIZED"
                    norm_cnt += 1
                else:
                    none_cnt += 1

            cur.execute(match_update_stmt, (festival_id, status, excel_id))
            if festival_id is not None:
                cur.execute(visitor_update_stmt, (v_total, v_dom, v_for, festival_id))

        conn.commit()
        log.info(
            f"[{source_file}] 매칭 - EXACT:{exact_cnt} NORMALIZED:{norm_cnt} NONE:{none_cnt} / 총 {len(excel_rows)}건 "
            f"-> festivals.{total_col}/{dom_col}/{for_col} 채움: {exact_cnt + norm_cnt}건"
        )
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()
        conn.close()


def run(processed_files):
    log.info("[Matcher] 시작")
    for source_file, plan_year in processed_files:
        match_source_file(source_file, plan_year)
    log.info("[Matcher] 완료")
