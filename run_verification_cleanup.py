"""
만료된 관리자 이메일 인증 코드를 주기적으로 지우기 위한 진입점.

인증 코드는 15분짜리라 새벽 6시 배치(run_status_update.py)처럼 하루에 한 번이 아니라
훨씬 자주 돌아야 한다. crontab으로 예를 들어 15분마다 실행하세요.

crontab 예시 (매 15분마다):
    */15 * * * * cd /path/to/chookjibup_data_pipeline && /usr/bin/python3 run_verification_cleanup.py >> logs/verification_cleanup.log 2>&1
"""

import logging

import admin_email_verification_cleaner
import schema_loader

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("run_verification_cleanup")


def main():
    # schema.sql이 이미 적용돼 있어도 재실행 시 안전하므로, cron이 처음 도는 시점에
    # admin_email_verification 테이블이 아직 없을 가능성까지 대비해 매번 먼저 확인한다.
    schema_loader.run()
    admin_email_verification_cleaner.run()
    log.info("인증 코드 정리 배치 종료")


if __name__ == "__main__":
    main()
