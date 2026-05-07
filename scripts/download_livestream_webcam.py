import os
import math
import time
import subprocess
import requests

from urllib.parse import urljoin
from datetime import datetime
from typing import Generic, TypeVar
from collections import deque
from threading import Thread
from queue import Queue, Empty

from dotenv import load_dotenv

import numpy as np
import cv2

livestream_url = "https://h058.video-stream-hosting.de/vocom-live/_definst_/smil:livestream.smil/chunklist_w1919586290_b5500000.m3u8"

WIDTH = 1920
HEIGHT = 1080
FPS = 30

frame_size = WIDTH * HEIGHT * 3
frame_time = 1.0 / FPS

debug_mode = True
preview_mode = debug_mode


FileQueue = Queue(bytes)
Process = subprocess.Popen

def run_analysis(capture: Process):
    # capture = subprocess.Popen([
    #     "ffmpeg", "-hide_banner", "-loglevel", "error",

    #     "-fflags", "nobuffer+discardcorrupt+genpts",
    #     "-flags", "low_delay",

    #     "-http_persistent", "1",

    #     "-reconnect", "1",
    #     "-reconnect_streamed", "1",
    #     "-reconnect_delay_max", "2",

    #     "-rw_timeout", "5000000",

    #     "-probesize", "4M",
    #     "-analyzeduration", "2M",

    #     "-i", "-",

    #     "-map", "0:v:0",
    #     "-an",

    #     "-pix_fmt", "bgr24",
    #     "-vcodec", "rawvideo",
    #     "-f", "rawvideo",
    #     "-"
    # ], stdin=subprocess.PIPE, stdout=subprocess.PIPE)

    fail_counter = 0
    snippet_counter = 0
    frame_counter = 0

    curr_image: cv2.typing.MatLike = None
    ret: bool = None

    try:
        while True:
            frame_start = time.time()

            raw = capture.stdout.read(frame_size)
            if len(raw) != frame_size:
                continue

            frame = np.frombuffer(raw, np.uint8).reshape((HEIGHT, WIDTH, 3))

            cv2.imshow("Live Stream", frame)
            if cv2.waitKey(1) & 0xFF == ord("q"):
                break

            frame_end = time.time()
            frame_remaining = frame_time - (frame_end - frame_start)
            if frame_remaining > 0:
                time.sleep(frame_remaining)
    except:
        capture.kill()
        raise


def run_capture(capture: Process):
    target_dir = os.getenv("LIVESTREAM_SNIPPET")
    if (not os.path.exists(target_dir)):
        os.makedirs(target_dir, exist_ok=True)

    downloaded_urls = deque(maxlen=100)
    while True:
        try:
            res = requests.get(livestream_url, timeout=5)
            res.raise_for_status()

            for line in res.text.splitlines():
                if ".ts" not in line:
                    continue

                ts_url = urljoin(livestream_url, line.strip())
                if ts_url in downloaded_urls:
                    continue

                filepath = f"{target_dir}/{line.strip()}"
                file_res = requests.get(ts_url, timeout=5)

                with open(filepath, "wb") as f:
                    f.write(file_res.content)

                    capture.stdin.write(file_res.content)
                    capture.stdin.flush()

                downloaded_urls.append(ts_url)
            time.sleep(1)  # Avoid spamming requests
        except Exception as e:
            print(f"Error: {e}")
            print("Restarting capture...")


def capture_worker(capture: Process):
    while True:
        print(f"Attemping capture on {datetime.now()}")
        try:
            run_capture(capture)
        except Exception as e:
            print(f"Unexpected exception: {e}")


def main():
    load_dotenv()

    if preview_mode:
        cv2.namedWindow("Live Stream", cv2.WINDOW_NORMAL)

    capture = subprocess.Popen([
        "ffmpeg", "-hide_banner", "-loglevel", "error",

        "-f", "mpegts",
        "-i", "pipe:0",
        "-an",

        "-f", "rawvideo",
        "-vcodec", "rawvideo",
        "-pix_fmt", "bgr24",
        "-"
    ], stdin=subprocess.PIPE, stdout=subprocess.PIPE)

    file_queue = Queue(maxsize=0)
    capture_thread = Thread(target=run_capture, args=[capture], daemon=True)
    capture_thread.start()
    run_analysis(capture)

    cv2.destroyAllWindows()

if __name__ == "__main__":
    main()
