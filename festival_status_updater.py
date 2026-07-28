import logging

from db import get_conn

log = logging.getLogger(__name__)

# 오늘 날짜와 start_date/end_date를 비교해서 progress_status를 다시 계산한다.
# 실제로 값이 바뀌는 행만 UPDATE하도록 IS DISTINCT FROM으로 걸러서,
# 안 바뀐 축제의 updated_at(트리거로 자동 갱신됨)까지 괜히 건드리지 않게 했다.
UPDATE_PROGRESS_STATUS_SQL = """
    WITH computed AS (
        SELECT
            festival_id,
            CASE
                WHEN start_date IS NULL OR end_date IS NULL THEN NULL
                WHEN CURRENT_DATE < start_date THEN 'upcoming'
                WHEN CURRENT_DATE > end_date THEN 'completed'
                ELSE 'ongoing'
            END::festival_progress_status AS new_status
        FROM festivals
    )
    UPDATE festivals f
    SET progress_status = c.new_status,
        progress_status_updated_at = now()
    FROM computed c
    WHERE f.festival_id = c.festival_id
      AND f.progress_status IS DISTINCT FROM c.new_status
"""


def run():
    """festivals.progress_status를 오늘 날짜 기준으로 다시 계산해서 채운다.

    - start_date/end_date 둘 다 있어야 계산 가능. 하나라도 없으면 NULL로 남는다.
    - 오늘 < start_date  -> 'upcoming' (예정)
    - 오늘 > end_date    -> 'completed' (종료)
    - 그 사이            -> 'ongoing' (진행중)

    main.py 전체 파이프라인 마지막 단계로도 실행되고, run_status_update.py로
    새벽 6시 cron에서 단독으로도 실행될 수 있다 (둘 다 재실행해도 안전).
    """
    log.info("[Festival Status Updater] 시작 - 진행 상태(예정/진행중/종료) 재계산")

    conn = get_conn()
    cur = conn.cursor()
    try:
        cur.execute(UPDATE_PROGRESS_STATUS_SQL)
        changed = cur.rowcount
        conn.commit()
        log.info(f"[Festival Status Updater] 완료 - 상태가 바뀐 축제 {changed}건")
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()
        conn.close()
