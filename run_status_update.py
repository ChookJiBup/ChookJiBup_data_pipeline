"""
새벽 6시 cron으로 단독 실행하기 위한 진입점.

전체 파이프라인(main.py)을 매번 돌리는 건 API 호출/엑셀 재처리까지 다 해서 무겁기 때문에,
"오늘 날짜 기준으로 진행 상태만 다시 계산"하는 이 스크립트만 가볍게 스케줄링합니다.

crontab 예시 (매일 새벽 6시):
    0 6 * * * cd /path/to/chookjibup_data_pipeline && /usr/bin/python3 run_status_update.py >> logs/status_update.log 2>&1
"""

import logging

import festival_status_updater
import schema_loader

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("run_status_update")


def main():
    # schema.sql이 이미 적용돼 있어도 재실행 시 안전하므로, cron이 처음 도는 시점에
    # progress_status 컬럼이 아직 없을 가능성까지 대비해 매번 먼저 확인한다.
    schema_loader.run()
    festival_status_updater.run()
    log.info("상태 업데이트 배치 종료")


if __name__ == "__main__":
    main()
