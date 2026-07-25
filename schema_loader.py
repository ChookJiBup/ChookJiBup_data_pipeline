import logging
import os

from config import BASE_DIR
from db import get_conn

log = logging.getLogger(__name__)

SCHEMA_PATH = os.path.join(BASE_DIR, "schema.sql")


def run():
    """schema.sql을 그대로 실행해서 테이블/타입/인덱스/트리거를 만듭니다.

    schema.sql 전체가 CREATE TABLE IF NOT EXISTS / CREATE INDEX IF NOT EXISTS /
    DO $$ ... EXCEPTION WHEN duplicate_object ... $$ (타입) /
    DROP TRIGGER IF EXISTS + CREATE TRIGGER (트리거) 형태로 작성돼 있어서,
    이미 스키마가 만들어져 있는 DB에 다시 실행해도 에러 없이 그냥 넘어갑니다.
    즉 매 파이프라인 실행마다 이 함수를 호출해도 안전합니다 (마이그레이션 도구 없이
    "없으면 만들고, 있으면 스킵"을 하고 싶다는 요구사항을 이렇게 충족합니다).
    """
    log.info("[Schema Loader] 시작 - schema.sql 적용")

    with open(SCHEMA_PATH, "r", encoding="utf-8") as f:
        schema_sql = f.read()

    conn = get_conn()
    cur = conn.cursor()
    try:
        cur.execute(schema_sql)
        conn.commit()
        log.info("[Schema Loader] 완료 - 테이블/타입/인덱스/트리거가 없으면 생성, 있으면 스킵")
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()
        conn.close()
