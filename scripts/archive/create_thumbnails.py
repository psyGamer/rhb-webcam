import sys
import os
import subprocess

from dotenv import load_dotenv
load_dotenv()

location = sys.argv[1]
print(f"Using location '{location}'...")

input_dir = None
output_dir = None

if location == "filisur":
    input_dir = os.getenv("WEBCAM_FILISUR_IMAGE")
    output_dir = os.getenv("WEBCAM_FILISUR_THUMBNAIL")
elif location == "landwasser":
    input_dir = os.getenv("WEBCAM_LANDWASSER_IMAGE")
    output_dir = os.getenv("WEBCAM_LANDWASSER_THUMBNAIL")
elif location == "landquart":
    input_dir = os.getenv("WEBCAM_LANDQUART_IMAGE")
    output_dir = os.getenv("WEBCAM_LANDQUART_THUMBNAIL")
elif location == "brusio":
    input_dir = os.getenv("WEBCAM_BRUSIO_IMAGE")
    output_dir = os.getenv("WEBCAM_BRUSIO_THUMBNAIL")
elif location == "livestream":
    input_dir = os.getenv("LIVESTREAM_IMAGE")
    output_dir = os.getenv("LIVESTREAM_THUMBNAIL")
else:
    print("Invalid location!")
    exit(1)

# input_dir = "/media/Laptop" + input_dir
# output_dir = "/media/Laptop" + output_dir

processes = []

for day_name in os.listdir(input_dir):
    os.makedirs(os.path.join(output_dir, day_name), exist_ok=True)

    for file_name in os.listdir(os.path.join(input_dir, day_name)):
        input_path  = os.path.join(input_dir, day_name, file_name)
        output_path = os.path.join(output_dir, day_name, file_name[:-4] + ".jpg")

        if os.path.exists(output_path):
            continue

        while len(processes) > 50:
            processes.pop().wait()
        
        print(f"Converting '{file_name}'...")
        processes.append(subprocess.Popen([
            "ffmpeg", "-hide_banner", "-loglevel", "error",
            "-i", input_path,
            "-vf", "crop=iw:iw*9/16:0:ih-iw*9/16,scale=-2:144",
            "-q:v", "10",
            "-frames:v", "1",
            "-update", "1",
            output_path
        ]))

for process in processes:
    process.wait()
    
