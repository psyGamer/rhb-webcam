import os
import requests
import time

from datetime import datetime
from zoneinfo import ZoneInfo

import sqlite3

from dotenv import load_dotenv
load_dotenv()

feed_api = "https://avisec.com/api/webcam/feed/content/S987773M7"
image_save_dir = os.getenv("WEBCAM_LANDQUART_IMAGE")
thumb_save_dir = os.getenv("WEBCAM_LANDQUART_THUMBNAIL")

update_interval = 300 # 5 minutes
tz = ZoneInfo("Europe/Zurich")

prev_image = None
while True:
    database = sqlite3.connect(os.getenv("DATABASE_PROD_PATH"))
    database_cursor = database.cursor()
    
    try:
        res = requests.get(feed_api, timeout=10)
        if res.status_code != 200:
            print("Failed to fetch feed:")
            print(res.content)
            time.sleep(update_interval)
            continue

        feed_data = res.json()[0]
        image_url = feed_data["image"]

        if image_url == prev_image:
            time.sleep(update_interval)
            continue
    
        capture_time = datetime.fromisoformat(feed_data["time"]).astimezone(tz)
        capture_dir  = capture_time.strftime("%Y-%m-%d")
        capture_name = capture_time.strftime("%Y-%m-%d_%H-%M-%S.jpg")

        print(f"New image for 'Landquart': {capture_name}")
        image_dir = os.path.join(image_save_dir, capture_dir)
        image_path = os.path.join(image_dir, capture_name)

        thumb_dir = os.path.join(thumb_save_dir, capture_dir)
        thumb_path = os.path.join(thumb_dir, capture_name)

        res = requests.get(image_url, timeout=10)
        if res.status_code != 200:
            print(f"Failed to fetch image '{image_url}':")
            print(res.content)
            time.sleep(update_interval)
            continue

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

            database_cursor.execute(f"INSERT INTO landquart_capture (file) VALUES (\"{capture_name[:-4]}\")")
            database.commit()

        prev_image = image_url
        time.sleep(update_interval)
    except Exception as e:
        print("An error occurred:", e)
        time.sleep(update_interval)
