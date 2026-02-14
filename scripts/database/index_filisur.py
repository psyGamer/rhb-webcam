import os
import sys
import sqlite3

from datetime import datetime

from dotenv import load_dotenv
load_dotenv()

environment = sys.argv[1]
print(f"Using environment '{environment}'...")

db_path = None
if environment == "dev":
    db_path = os.getenv("DATABASE_DEV_PATH")
elif environment == "prod":
    db_path = os.getenv("DATABASE_PROD_PATH")

if db_path is None:
    print("Invalid environment!")
    exit(1)

db = sqlite3.connect(db_path)
db_cur = db.cursor()

db_cur.execute("DELETE FROM filisur_capture")

image_base = os.getenv("WEBCAM_FILISUR_IMAGE")
video_base = os.getenv("WEBCAM_FILISUR_VIDEO")

for dir in os.listdir(image_base):
    date = datetime.strptime(dir, "%Y-%m-%d")
    
    image_dir = f"{image_base}/{dir}"
    video_dir = f"{video_base}/{dir}"

    if date.year > 2022 and not os.path.exists(video_dir):
        print(f"Missing video directory for '{dir}'")

    for file in os.listdir(image_dir):
        try:
            db_cur.execute(f"INSERT INTO filisur_capture (file) VALUES (\"{file[:-4]}\")")
            print(f"Added '{file}'")
        except sqlite3.IntegrityError:
            pass

db.commit()
db.close()

