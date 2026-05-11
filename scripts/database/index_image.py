
import os
import sys
import sqlite3

from datetime import datetime

from dotenv import load_dotenv
load_dotenv()

environment = sys.argv[1]
location = sys.argv[2]
print(f"Using environment '{environment}'...")
print(f"Using location '{location}'...")

db_path = None
if environment == "dev":
    db_path = os.getenv("DATABASE_DEV_PATH")
elif environment == "prod":
    db_path = os.getenv("DATABASE_PROD_PATH")

if db_path is None:
    print("Invalid environment!")
    exit(1)

image_path = None
table_name = None
if location == "brusio":
    image_path = os.getenv("WEBCAM_BRUSIO_IMAGE")
    table_name = "brusio_capture"
elif location == "landwasser":
    image_path = os.getenv("WEBCAM_LANDWASSER_IMAGE")
    table_name = "landwasser_capture"
elif location == "landquart":
    image_path = os.getenv("WEBCAM_LANDQUART_IMAGE")
    table_name = "landquart_capture"

if image_path is None or table_name is None:
    print("Invalid location")
    exit(1)

db = sqlite3.connect(db_path)
db_cur = db.cursor()

db_cur.execute(f"DELETE FROM {table_name}")

for dir in os.listdir(image_path):
    date = datetime.strptime(dir, "%Y-%m-%d")
    
    image_dir = f"{image_path}/{dir}"

    for file in os.listdir(image_dir):
        try:
            db_cur.execute(f"INSERT INTO {table_name} (file) VALUES (\"{file[:-4]}\")")
            print(f"INSERT INTO {table_name} (file) VALUES (\"{file[:-4]}\")")
            # print(f"Added '{file}'")
        except sqlite3.IntegrityError:
            pass

db.commit()
db.close()

