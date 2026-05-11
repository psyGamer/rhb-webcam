import os
import requests
import hashlib
import time
import subprocess

from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import sqlite3

from dotenv import load_dotenv
load_dotenv()

update_interval = 1.0

url = "https://www.webcam.valtline.it/brusio.jpg"
image_save_dir = os.getenv("WEBCAM_BRUSIO_IMAGE")
thumb_save_dir = os.getenv("WEBCAM_BRUSIO_THUMBNAIL")

last_changed = ""
last_length = None
last_saved = False

tz_gmt = ZoneInfo("GMT")
tz_local = ZoneInfo("Europe/Zurich")

while True:
    database = sqlite3.connect(os.getenv("DATABASE_PROD_PATH"))
    database_cursor = database.cursor()
    
    try:
        res = requests.get(url, stream=True, timeout=10)
        if res.status_code != 200:
            print(f"Failed to fetch image '{url}':")
            print(res.content)
            continue

        if last_changed != res.headers.get("Last-Modified"):
            last_changed = res.headers.get("Last-Modified")
            last_length = res.headers.get("Content-Length")
            last_saved = False
            continue

        if last_saved:
            time.sleep(update_interval)
            continue
        
        if last_length != res.headers.get("Content-Length"):
            last_length = res.headers.get("Content-Length")
            continue

        capture_time = datetime.strptime(last_changed, "%a, %d %b %Y %H:%M:%S %Z").replace(tzinfo=tz_gmt).astimezone(tz_local) - timedelta(seconds=1)
        capture_dir  = capture_time.strftime("%Y-%m-%d")
        capture_name = capture_time.strftime("%Y-%m-%d_%H-%M-%S.jpg")

        print(f"New image for 'Brusio': {capture_name}")
        image_dir = os.path.join(image_save_dir, capture_dir)
        image_path = os.path.join(image_dir, capture_name)

        thumb_dir = os.path.join(thumb_save_dir, capture_dir)
        thumb_path = os.path.join(thumb_dir, capture_name)

        os.makedirs(image_dir, exist_ok=True)
        os.makedirs(thumb_dir, exist_ok=True)
        if not os.path.exists(image_path):
            with open(image_path, "wb") as f:
                f.write(res.content)

            subprocess.Popen([
                "ffmpeg", "-hide_banner", "-loglevel", "error",
                "-i", image_path,
                "-vf", "crop=iw:iw*9/16:0:ih-iw*9/16,scale=-2:144",
                "-q:v", "10",
                "-frames:v", "1",
                "-update", "1",
                thumb_path
            ])
            
            database_cursor.execute(f"INSERT INTO brusio_capture (file) VALUES (\"{capture_name[:-4]}\")")
            database.commit()

        last_saved = True
    except Exception as e:
        print("An error occurred:", e)


