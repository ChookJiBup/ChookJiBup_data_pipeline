import logging

import schema_loader
from loaders import api_loader, excel_loader
import matcher

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("main")


def main():
    schema_loader.run()  # 스키마(테이블/타입/인덱스/트리거) 없으면 생성, 있으면 스킵
    api_loader.run()
    processed_files = excel_loader.run()
    matcher.run(processed_files)
    log.info("파이프라인 종료")


if __name__ == "__main__":
    main()
