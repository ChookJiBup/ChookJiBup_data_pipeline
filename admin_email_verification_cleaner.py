import logging

from db import get_conn

log = logging.getLogger(__name__)

DELETE_EXPIRED_SQL = """
    DELETE FROM admin_email_verification
    WHERE expires_at < now()
"""


def run():
    """만료된(15분 지난) 이메일 인증 코드를 실제로 지운다.

    admin_email_verification.expires_at은 발급 시점에 이미 (now() + 15분)으로
    박혀 있어서, 여기서는 "지금 시각 기준으로 이미 지난 것"만 골라 지우면 된다.
    인증 자체의 유효성 검사(코드가 맞는지, 만료됐는지)는 이 배치가 아니라
    admin 백엔드(아직 별도 프로젝트) 쪽에서 매 요청마다 expires_at을 확인해서 하고,
    이 배치는 순전히 오래된 행을 DB에서 청소하는 역할만 한다.
    """
    log.info("[Admin Email Verification Cleaner] 시작 - 만료된 인증 코드 삭제")

    conn = get_conn()
    cur = conn.cursor()
    try:
        cur.execute(DELETE_EXPIRED_SQL)
        deleted = cur.rowcount
        conn.commit()
        log.info(f"[Admin Email Verification Cleaner] 완료 - 만료 코드 {deleted}건 삭제")
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()
        conn.close()
