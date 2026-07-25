import re
from datetime import date
from typing import Optional


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
