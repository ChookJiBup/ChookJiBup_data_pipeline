# config.py를 만들 때 이 파일을 복사해서 쓰세요.
# cp configexample.py config.py  (Windows: copy config.example.py config.py)
import os

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(BASE_DIR, "data")

DB_CONFIG = {
    "host": "localhost",
    "port": 5432,
    "dbname": "postgres",
    "user": "postgres",
    "password": "여기에_본인_비밀번호",
}

API_CONFIG = {
    "service_key": "여기에_data.go.kr_서비스키",
    "base_url": "https://api.data.go.kr/openapi/tn_pubr_public_cltur_fstvl_api",
    "num_of_rows": 100,
}

EXCEL_CONFIG = {
    "sheet_name": "조사표",
    "data_start_row": 8,
}