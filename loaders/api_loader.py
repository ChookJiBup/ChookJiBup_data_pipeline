import json
import logging
from datetime import datetime, timezone

import requests
import psycopg2.extras

from config import API_CONFIG
from db import get_conn
from utils import to_num, parse_date_string, compute_progress_status

log = logging.getLogger(__name__)


def fetch_all():
    items = []
    page_no = 1

    while True:
        params = {
            "serviceKey": API_CONFIG["service_key"],
            "pageNo": page_no,
            "numOfRows": API_CONFIG["num_of_rows"],
            "type": "json",
        }
        resp = requests.get(API_CONFIG["base_url"], params=params, timeout=30)
        resp.raise_for_status()
        data = resp.json()

        if "cmmMsgHeader" in data:
            err = data["cmmMsgHeader"]
            raise RuntimeError(
                f"API 인증/요청 오류: {err.get('returnAuthMsg') or err.get('errMsg')} "
                f"(config.py의 API_CONFIG['service_key']를 확인하세요 - Decoding 키 사용)"
            )

        body = data.get("response", {}).get("body", {})
        result_code = data.get("response", {}).get("header", {}).get("resultCode")
        if result_code not in (None, "00", "0"):
            result_msg = data.get("response", {}).get("header", {}).get("resultMsg")
            raise RuntimeError(f"API 오류 응답: [{result_code}] {result_msg}")

        page_items = body.get("items")
        if not page_items:
            break

        if isinstance(page_items, dict):
            item_list = page_items.get("item", [])
        else:
            item_list = page_items
        if isinstance(item_list, dict):
            item_list = [item_list]
        if not item_list:
            break

        items.extend(item_list)
        total_count = int(body.get("totalCount", 0))
        log.info(f"API page {page_no} 조회 - 누적 {len(items)} / 전체 {total_count}")

        if len(items) >= total_count:
            break
        page_no += 1

    return items


def save(items):
    """festivals 테이블에 UPSERT 합니다.

    이전에는 매 실행마다 TRUNCATE ... CASCADE 로 festival_api_raw를 통째로 비우고
    다시 채웠는데, 이제 festivals.festival_id를 festival_wishlist / festival_review /
    festival_dashboard 등 다른 앱 테이블들이 FK로 참조하고 있어서 그렇게 하면
    사용자 찜/리뷰/대시보드가 실행할 때마다 전부 날아갑니다. 그래서 UPSERT로 바꿨습니다.

    data.go.kr API는 축제별 안정적인 고유 ID를 내려주지 않기 때문에,
    schema.sql의 ux_festivals_api_natural_key (festival_name + start_date + road_address,
    source_type='api'인 행만 대상) 를 대체 키로 삼아 ON CONFLICT 매칭합니다.
    ⚠️ 주소 표기나 날짜가 API 쪽에서 살짝 바뀌면 같은 축제가 새 행으로 다시 들어갈 수 있습니다 —
    매칭이 잘 안 되는 사례가 보이면 이 자연키를 재검토해야 합니다.

    source_type='manual' (관리자가 직접 등록한 축제)는 이 UPSERT 대상이 아니라서 건드리지 않습니다.

    progress_status(예정/진행중/종료)도 이 시점에 바로 계산해서 채웁니다 — start_date/end_date를
    파싱해서 오늘 날짜와 비교하는 로직은 festival_status_updater.py와 동일한 규칙을 utils.py의
    compute_progress_status()로 공유합니다. 이후로는 festival_status_updater.py가 매일 새벽
    6시(또는 파이프라인 재실행 시)마다 다시 갱신합니다.
    """
    run_started_at = datetime.now(timezone.utc)  # 이번 실행에서 "API에 여전히 존재함"으로 찍을 시각
    today = run_started_at.date()  # 이번 실행 내내 동일한 기준일을 써서 행마다 다른 날짜로 계산되지 않게 함

    conn = get_conn()
    cur = conn.cursor()
    try:
        # natural key(festival_name, start_date, road_address) 기준으로 먼저 파이썬에서 중복 제거합니다.
        # ON CONFLICT ... DO UPDATE는 "같은 INSERT 문 안에서" 같은 행을 두 번 건드리는 걸 허용하지
        # 않는데(CardinalityViolation), data.go.kr API가 페이지들 사이에 완전히 같은 축제를
        # 중복으로 내려주는 경우가 있어서 이 단계가 꼭 필요합니다. 뒤에 나온 항목이 최신이라고
        # 가정하고 나중 값으로 덮어씁니다.
        deduped = {}
        skipped = 0
        for it in items:
            festival_name = it.get("festivalName") or it.get("fstvlNm")
            if not festival_name:
                skipped += 1
                continue

            start_date = it.get("festivalStartDate") or it.get("fstvlStartDate")
            end_date = it.get("festivalEndDate") or it.get("fstvlEndDate")
            road_address = it.get("roadNmAddr") or it.get("rdnmadr")
            natural_key = (festival_name, start_date or "1900-01-01", road_address or "")

            # progress_status는 최초 적재 시점부터 바로 값이 들어가도록 여기서 미리 계산해둔다.
            # (그 뒤로는 festival_status_updater.py가 매일 새벽 6시/파이프라인 실행마다 다시 갱신한다.)
            progress_status = compute_progress_status(
                parse_date_string(start_date),
                parse_date_string(end_date),
                today,
            )

            deduped[natural_key] = (
                festival_name,
                it.get("opar") or it.get("eventPlace"),
                start_date,
                end_date,
                it.get("festivalContent") or it.get("fstvlCo"),
                it.get("mnnstNm"),
                it.get("auspcInsttNm"),
                it.get("suprtInsttNm"),
                it.get("phoneNumber") or it.get("phoneNum"),
                it.get("homepageUrl") or it.get("rdnmadr"),
                it.get("relateInfo"),
                road_address,
                it.get("lnmAddr"),
                to_num(it.get("latitude") or it.get("la")),
                to_num(it.get("longitude") or it.get("lo")),
                it.get("referenceDate") or it.get("baseYmd"),
                json.dumps(it, ensure_ascii=False),
                run_started_at,
                progress_status,
                run_started_at,
            )

        rows = list(deduped.values())
        duplicate_count = len(items) - skipped - len(rows)

        if skipped:
            log.warning(f"festival_name이 없는 API 항목 {skipped}건은 건너뜁니다.")
        if duplicate_count > 0:
            log.warning(
                f"API 응답 내에서 자연키(festival_name+start_date+road_address)가 겹치는 "
                f"항목 {duplicate_count}건은 중복 제거하고 마지막 값으로만 적재합니다."
            )

        result = psycopg2.extras.execute_values(
            cur,
            """
            INSERT INTO festivals (
                festival_name, event_place, start_date, end_date, content,
                supervisor_org, host_org, sponsor_org, phone_number, homepage_url,
                related_info, road_address, jibun_address, latitude, longitude,
                api_reference_date, raw_payload, api_last_seen_at,
                progress_status, progress_status_updated_at
            ) VALUES %s
            ON CONFLICT (festival_name, (COALESCE(start_date, DATE '1900-01-01')), (COALESCE(road_address, '')))
                WHERE source_type = 'api'
            DO UPDATE SET
                event_place                 = EXCLUDED.event_place,
                end_date                    = EXCLUDED.end_date,
                content                     = EXCLUDED.content,
                supervisor_org              = EXCLUDED.supervisor_org,
                host_org                    = EXCLUDED.host_org,
                sponsor_org                 = EXCLUDED.sponsor_org,
                phone_number                = EXCLUDED.phone_number,
                homepage_url                = EXCLUDED.homepage_url,
                related_info                = EXCLUDED.related_info,
                jibun_address               = EXCLUDED.jibun_address,
                latitude                    = EXCLUDED.latitude,
                longitude                   = EXCLUDED.longitude,
                api_reference_date          = EXCLUDED.api_reference_date,
                raw_payload                 = EXCLUDED.raw_payload,
                api_last_seen_at            = EXCLUDED.api_last_seen_at,
                progress_status             = EXCLUDED.progress_status,
                progress_status_updated_at  = EXCLUDED.progress_status_updated_at,
                updated_at                  = now()
            RETURNING (xmax = 0) AS inserted
            """,
            rows,
            fetch=True,
        )
        inserted = sum(1 for (is_new,) in result if is_new)
        updated = len(result) - inserted
        conn.commit()
        log.info(
            f"festivals UPSERT 완료: 총 {len(rows)}건 (신규 {inserted}건 / 갱신 {updated}건, 건너뜀 {skipped}건)"
        )
        log.info(
            "이번 실행에서 API에 나타나지 않은 기존 festivals(source_type='api') 행은 삭제하지 않고 "
            "api_last_seen_at을 갱신하지 않은 채로 남겨둡니다. 오래된 축제를 정리하려면 "
            "api_last_seen_at 기준으로 별도 배치를 만들어 처리하세요 (자동 삭제는 하지 않습니다 — "
            "찜/리뷰 등 연결된 데이터가 함께 지워질 수 있어서 위험합니다)."
        )
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()
        conn.close()


def run():
    log.info("[API Loader] 시작")
    items = fetch_all()
    save(items)
    log.info("[API Loader] 완료")
