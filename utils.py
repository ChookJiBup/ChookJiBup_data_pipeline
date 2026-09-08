import re
from datetime import date, datetime
from typing import Optional
from urllib.parse import urlsplit


def normalize_festival_name(name: Optional[str]) -> str:
    """공백/특수문자 제거 정규화. 매칭용으로만 사용 (원본 festival_name은 그대로 저장)."""
    if not name:
        return ""
    name = re.sub(r"\s+", "", name)                     # 공백 전체 제거
    name = re.sub(r"[^0-9a-zA-Z가-힣]", "", name)         # 한글/영문/숫자 이외 제거 (언더스코어 포함)
    return name.lower()


def parse_date(year, month, day) -> Optional[date]:
    try:
        if not year or not month or not day:
            return None
        return date(int(year), int(month), int(day))
    except (ValueError, TypeError):
        return None


def parse_date_string(value) -> Optional[date]:
    """API가 내려주는 단일 문자열 날짜(예: "2025-06-14", "20250614")를 date로 파싱한다.

    실제 저장 컬럼(festivals.start_date/end_date)은 원본 문자열을 그대로 psycopg2/Postgres에
    넘겨서 Postgres가 알아서 캐스팅하게 두고 있다 (이미 잘 동작 중이라 건드리지 않음).
    이 함수는 오직 progress_status를 파이썬에서 미리 계산하기 위한 용도라, 파싱에
    실패해도(포맷이 낯설어도) 에러 없이 None을 반환해서 progress_status만 NULL로
    남기고 넘어간다.
    """
    if value is None:
        return None
    if isinstance(value, date):
        return value
    s = str(value).strip()
    if not s:
        return None
    for fmt in ("%Y-%m-%d", "%Y%m%d", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S"):
        try:
            return datetime.strptime(s, fmt).date()
        except ValueError:
            continue
    return None


def compute_progress_status(
    start_date: Optional[date],
    end_date: Optional[date],
    today: Optional[date] = None,
) -> Optional[str]:
    """festival_status_updater.py의 SQL 계산 규칙과 동일하다 (파이썬 쪽에서도 같은 규칙 사용).

    - start_date/end_date 둘 중 하나라도 없으면 판단 불가 -> None
    - 오늘 < start_date  -> 'upcoming' (예정)
    - 오늘 > end_date    -> 'completed' (종료)
    - 그 사이            -> 'ongoing' (진행중)
    """
    if today is None:
        today = date.today()
    if start_date is None or end_date is None:
        return None
    if today < start_date:
        return "upcoming"
    if today > end_date:
        return "completed"
    return "ongoing"


def to_num(value):
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return value
    s = str(value).strip()
    if s in ("모름", "해당없음", "-", "", "미집계", "무응답", "미정", "미상"):
        return None
    try:
        return float(s.replace(",", ""))
    except ValueError:
        return None


def to_int(value):
    n = to_num(value)
    if n is None:
        return None
    try:
        return int(n)
    except (ValueError, TypeError):
        return None


def image_url_from_item(item):
    """원본에 공개 HTTP(S) 이미지 주소가 있는 경우에만 적재한다."""
    for key in ("imageUrl", "firstimage", "firstimage2", "thumbnailUrl", "posterUrl"):
        value = item.get(key)
        if not isinstance(value, str):
            continue
        value = value.strip()
        try:
            parsed = urlsplit(value)
        except ValueError:
            continue
        if parsed.scheme in ("http", "https") and parsed.hostname and not parsed.username and not parsed.password:
            return value
    return None
