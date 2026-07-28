"""
OS의 crontab에 의존하지 않고, 이 파이썬 프로세스 자체가 계속 떠서
- 매일 새벽 6시(한국시간, Asia/Seoul)에 festival_status_updater를
- 매 15분마다 admin_email_verification_cleaner를
실행하는 스크립트입니다.

run_status_update.py/run_verification_cleanup.py + crontab 방식과 이 방식 중
하나만 쓰면 됩니다 (둘 다 쓰면 같은 작업이 중복 실행됩니다).

- crontab을 등록할 권한/환경이 없는 경우 (일부 PaaS, 관리형 호스팅 등)
- 파이썬 코드 안에서 스케줄까지 다 관리하고 싶은 경우

에 이 방식을 쓰세요. cron용 스크립트들과 달리 이 프로세스는 실행하면 끝나지 않고
계속 떠 있으면서 내부적으로 다음 실행 시각을 관리합니다 — 그래서 systemd,
Docker(재시작 정책 포함), pm2 같은 걸로 "항상 떠 있게" 관리해줘야 합니다.

설치:
    pip install apscheduler

실행:
    python3 scheduler.py
"""

import logging

from apscheduler.schedulers.blocking import BlockingScheduler
from apscheduler.triggers.cron import CronTrigger
from apscheduler.triggers.interval import IntervalTrigger

import admin_email_verification_cleaner
import festival_status_updater
import schema_loader

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("scheduler")

TIMEZONE = "Asia/Seoul"


def run_status_update_job():
    log.info("[Scheduler] 정기 작업 시작 - 축제 진행 상태 재계산")
    schema_loader.run()
    festival_status_updater.run()
    log.info("[Scheduler] 정기 작업 종료 - 축제 진행 상태 재계산")


def run_verification_cleanup_job():
    log.info("[Scheduler] 정기 작업 시작 - 만료된 이메일 인증 코드 삭제")
    schema_loader.run()
    admin_email_verification_cleaner.run()
    log.info("[Scheduler] 정기 작업 종료 - 만료된 이메일 인증 코드 삭제")


def main():
    scheduler = BlockingScheduler(timezone=TIMEZONE)
    scheduler.add_job(
        run_status_update_job,
        trigger=CronTrigger(hour=6, minute=0, timezone=TIMEZONE),
        id="festival_status_update_daily",
        name="축제 진행 상태 매일 새벽 6시 재계산",
        misfire_grace_time=3600,  # 서버가 잠깐 내려가 있다가 늦게 떠도 1시간 이내면 놓치지 않고 실행
    )
    scheduler.add_job(
        run_verification_cleanup_job,
        trigger=IntervalTrigger(minutes=15),
        id="admin_email_verification_cleanup",
        name="만료된 이메일 인증 코드 15분마다 삭제",
        misfire_grace_time=300,  # 5분 이내 지연은 놓치지 않고 실행 (15분 주기라 grace를 짧게 잡음)
    )

    log.info(f"스케줄러 시작 - 매일 06:00({TIMEZONE})에 축제 상태 재계산, 매 15분마다 인증 코드 정리를 수행합니다.")
    log.info("프로세스 시작 시점에도 두 작업을 한 번씩 즉시 실행합니다.")
    run_status_update_job()
    run_verification_cleanup_job()

    try:
        scheduler.start()  # 여기서 블로킹되어 계속 대기합니다 (Ctrl+C로 종료)
    except (KeyboardInterrupt, SystemExit):
        log.info("스케줄러를 종료합니다.")


if __name__ == "__main__":
    main()
