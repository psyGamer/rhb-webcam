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

while True:
    try:
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
                continue

            image_time = datetime.now().strftime("%Y-%m-%d_%H-%M-%S.jpg")
            print(f"New image for '{webcam["name"]}': {image_time}")
            path = os.path.join(save_dir, image_time)
            with open(path, "wb") as f:
                f.write(res.content)

            last_hashes[idx] = hash

        time.sleep(update_interval)
    except Exception as e:
        print("An error occurred:", e)
        time.sleep(update_interval)

