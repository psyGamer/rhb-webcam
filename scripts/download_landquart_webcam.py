import os
import requests
import time

from datetime import datetime
from zoneinfo import ZoneInfo

from dotenv import load_dotenv

feed_api = "https://avisec.com/api/webcam/feed/content/S987773M7"

update_interval = 300 # 5 minutes
tz = ZoneInfo("Europe/Zurich")

load_dotenv()

prev_image = None
while True:
    try:
        res = requests.get(feed_api)
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
    
        image_time = datetime.fromisoformat(feed_data["time"]).astimezone(tz)
        image_dir  = image_time.strftime("%Y-%m-%d")
        image_name = image_time.strftime("%Y-%m-%d_%H-%M-%S.jpg")

        print(f"New image for 'Landquart': {image_name}")
        dir = os.path.join(os.getenv("WEBCAM_LANDQUART_IMAGE"), image_dir)
        path = os.path.join(dir, image_name)

        res = requests.get(image_url)
        if res.status_code != 200:
            print(f"Failed to fetch image '{image_url}':")
            print(res.content)
            time.sleep(update_interval)
            continue

        os.makedirs(dir, exist_ok=True)
        with open(path, "wb") as f:
            f.write(res.content)

        prev_image = image_url
        time.sleep(update_interval)
    except Exception as e:
        print("An error occurred:", e)
        time.sleep(update_interval)
