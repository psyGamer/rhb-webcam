import os
import requests
import hashlib
import time

from datetime import datetime

from dotenv import load_dotenv
load_dotenv()

update_interval = 1.0

webcams = [
    # { "name": "Landwasser", "url": "https://webcams.rhb.ch/Landwasserviadukt_c1.jpg", "save_dir": os.getenv("WEBCAM_LANDWASSER_IMAGE") },
    { "name": "Brusio", "url": "https://www.webcam.valtline.it/brusio.jpg", "save_dir": os.getenv("WEBCAM_BRUSIO_IMAGE") },
]

last_hashes = ['' for _ in webcams]
same_hashes = [False for _ in webcams]

while True:
    try:
        should_sleep = True
        for idx, webcam in enumerate(webcams):
            url = webcam["url"]
            save_dir = webcam["save_dir"]

            res = requests.get(url)
            if res.status_code != 200:
                print(f"Failed to fetch image '{url}':")
                print(res.content)
                continue

            hash = hashlib.md5(res.content).hexdigest()
            if hash == last_hashes[idx]:
                if not same_hashes[idx]:
                    should_sleep = False
                same_hashes[idx] = True
                continue

            same_hashes[idx] = False
            should_sleep = False

            now = datetime.now()
            image_time = now.strftime("%Y-%m-%d_%H-%M-%S.jpg")
            image_dir = now.strftime("%Y-%m-%d")
            
            print(f"New image for '{webcam["name"]}': {image_time}")
            print(res.headers),
            print(len(res.content))
            dir = os.path.join(save_dir, image_dir)
            path = os.path.join(dir, image_time)

            os.makedirs(dir, exist_ok=True)
            with open(path, "wb") as f:
                f.write(res.content)

            last_hashes[idx] = hash

        if should_sleep:
            time.sleep(update_interval)
    except Exception as e:
        print("An error occurred:", e)
        # time.sleep(update_interval)

