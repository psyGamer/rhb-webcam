import sys
import os
import subprocess

input_dir  = sys.argv[1]
output_dir = sys.argv[2]

processes = []

for day_name in os.listdir(input_dir):
    os.makedirs(os.path.join(output_dir, day_name), exist_ok=True)

    for file_name in os.listdir(os.path.join(input_dir, day_name)):
        input_path  = os.path.join(input_dir, day_name, file_name)
        output_path = os.path.join(output_dir, day_name, file_name[:-4] + ".jpg")

        if os.path.exists(output_path):
            continue
        
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
    
