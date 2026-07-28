import logging

import schema_loader
from loaders import api_loader, excel_loader
import matcher
import festival_status_updater

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("main")


def main():
    schema_loader.run()  # 스키마(테이블/타입/인덱스/트리거) 없으면 생성, 있으면 스킵
    api_loader.run()
    processed_files = excel_loader.run()
    matcher.run(processed_files)
    festival_status_updater.run()  # 새로 들어온/바뀐 축제까지 포함해서 진행 상태 재계산
    log.info("파이프라인 종료")


if __name__ == "__main__":
    main()
