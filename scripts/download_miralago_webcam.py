import os
import requests
import hashlib
import time

from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from dotenv import load_dotenv
load_dotenv()

update_interval = 10.0

url = "https://webcam.miralago.ch/miralago.jpg"
save_dir = os.getenv("WEBCAM_MIRALAGO_SNIPPET")

last_changed = ""
last_length = None
last_saved = False

tz_gmt = ZoneInfo("GMT")
tz_local = ZoneInfo("Europe/Zurich")

while True:
    try:
        res = requests.get(url, stream=True, timeout=10)
        if res.status_code != 200:
            print(f"Failed to fetch image '{url}':")
            print(res.content)
            continue

        if last_changed != res.headers.get("Last-Modified"):
            print("Preparing new image:")
            print(res.headers)
            last_changed = res.headers.get("Last-Modified")
            last_length = res.headers.get("Content-Length")
            last_saved = False
            continue

        if last_saved:
            time.sleep(update_interval)
            continue
        
        if last_length != res.headers.get("Content-Length"):
            last_length = res.headers.get("Content-Length")
            print("Pending new image:")
            print(res.headers)
            continue

        image_time = datetime.strptime(last_changed, "%a, %d %b %Y %H:%M:%S %Z").replace(tzinfo=tz_gmt).astimezone(tz_local) - timedelta(seconds=3)
        image_dir  = image_time.strftime("%Y-%m-%d")
        image_name = image_time.strftime("%Y-%m-%d_%H-%M-%S.jpg")

        print(f"New image for 'Miralago': {image_name}")
        print(res.headers)
        dir = os.path.join(save_dir, image_dir)
        path = os.path.join(dir, image_name)

        os.makedirs(dir, exist_ok=True)
        with open(path, "wb") as f:
            f.write(res.content)

        last_saved = True
    except Exception as e:
        print("An error occurred:", e)



