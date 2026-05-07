import os
import math
import time
import subprocess
import requests

from urllib.parse import urljoin
from dataclasses import dataclass
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

time_roi = (WIDTH - 400, 0, 400, 50)

minimum_recording_duration = 4.0
maximum_snippet_retention = 3600.0
snippet_clear_interval = 100

debug_mode = True
preview_mode = debug_mode
output_video = True

FileQueue = Queue(bytes)
Process = subprocess.Popen


active_video_segment = None
snippet_collection = None


@dataclass 
class SnippetCollection:
    previous_file: str = None
    current_file: str = None

    file_name: str = None
    video_target_file: str = None
    image_target_file: str = None
    thumbnail_target_file: str = None

    recording: bool = False
    segments: list[str] = None
    pending_flush: list[str] = None

    thumbnail_frame: cv2.typing.MatLike = None
    thumbnail_timeout: int = 0
    
    start_time: float = 0.0

    def __post_init__(self):
        self.segments = []
        self.pending_flush = []

    def start_recording(self, frame: cv2.typing.MatLike, timeout_frames: int, time: float, should_buffer_start: bool):
        now = datetime.now()
        print(f"== Started Recording at {now} ==")
        if len(self.pending_flush) != 0:
            self.segments = [self.current_file]
            self.start_time = time
        elif len(self.segments) == 0:
            if not should_buffer_start or not self.previous_file:
                self.segments = [self.current_file]
            else:
                self.segments = [self.previous_file, self.current_file]

            video_target_dir = f"{os.getenv("LIVESTREAM_VIDEO")}/{now.strftime('%Y-%m-%d')}"
            os.makedirs(video_target_dir, exist_ok=True)
            image_target_dir = f"{os.getenv("LIVESTREAM_IMAGE")}/{now.strftime('%Y-%m-%d')}"
            os.makedirs(image_target_dir, exist_ok=True)
            thumbnail_target_dir = f"{os.getenv("LIVESTREAM_THUMBNAIL")}/{now.strftime('%Y-%m-%d')}"
            os.makedirs(thumbnail_target_dir, exist_ok=True)

            self.file_name = now.strftime('%Y-%m-%d_%H-%M-%S')
            self.video_target_file = f"{video_target_dir}/{self.file_name}.mp4"
            self.image_target_file = f"{image_target_dir}/{self.file_name}.png"
            self.thumbnail_target_file = f"{thumbnail_target_dir}/{self.file_name}.jpg"
            self.start_time = time
            self.thumbnail_frame = frame.copy()
            self.thumbnail_timeout = timeout_frames

        self.recording = True

    def stop_recording(self, time: float):
        if time - self.start_time < minimum_recording_duration:
            print(f"== Cancelled Recording at {datetime.now()} ({time - self.start_time}s delta) ==")

            if len(self.pending_flush) != 0 and len(self.segments) > 0:
                # Need to flush, to avoid gap in video
                self.flush()

            self.recording = False
            self.segments = []
            return
            
        print(f"== Stopped Recording at {datetime.now()} ==")
        self.recording = False


    def next_snippet(self, file: str):
        print(f" -> {file}")

        self.previous_file = self.current_file
        self.current_file = file

        if self.recording:
            self.segments.append(file)
        elif len(self.segments) != 0:
            for seg in self.segments:
                self.pending_flush.append(seg)
            self.segments = []
        elif len(self.pending_flush) != 0:
            self.flush()
    
    def flush(self):
        if not output_video:
            print(f" => {self.video_target_file}  ({len(self.pending_flush)} segments)")
            self.pending_flush =  []
            return

        ## Create file list
        filelist = f"flush_files.txt"
        with open(filelist, "w") as f:
            for segment in self.pending_flush:
                f.write(f"file '{segment}'\n")

        process = subprocess.Popen([
            "ffmpeg", "-hide_banner", "-loglevel", "error",
            "-fflags", "+genpts",
            "-f", "concat", "-safe", "0",
            "-i", filelist,
            "-movflags", "+faststart", "-c:v", "copy", self.video_target_file
        ])

        cv2.imwrite(self.image_target_file, self.thumbnail_frame)

        subprocess.Popen([
            "ffmpeg", "-hide_banner", "-loglevel", "error",
            "-i", self.image_target_file,
            "-vf", "crop=iw:iw*9/16:0:ih-iw*9/16,scale=-2:144",
            "-q:v", "10",
            "-frames:v", "1",
            "-update", "1",
            self.thumbnail_target_file
        ])

        # global database
        # global database_cursor
        # database_cursor.execute(f"INSERT INTO filisur_capture (file) VALUES (\"{self.file_name}\")")
        # database.commit()

        print(f" => {self.video_target_file}  ({len(self.pending_flush)} segments)")
        self.pending_flush =  []


def run_analysis(capture: Process):
    analysis_interval = int(1.0 * FPS)
    next_analysis = analysis_interval

    curr_ad_level = 0
    curr_motion_level = 0
    curr_recording = False

    total_ad = 0
    total_non_ad = 0

    total_frames = 0

    prev_gray = None

    try:
        while True:
            time.sleep(1/60.0)

            raw = capture.stdout.read(frame_size)
            if len(raw) != frame_size:
                continue

            total_frames += 1

            next_analysis -= 1
            if next_analysis > 0:
                cv2.imshow("Normal", np.frombuffer(raw, np.uint8).reshape((HEIGHT, WIDTH, 3)))
                if cv2.waitKey(1) & 0xFF == ord("q"):
                    break
                continue

            next_analysis = analysis_interval

            curr_image = np.frombuffer(raw, np.uint8).reshape((HEIGHT, WIDTH, 3))
            curr_gray = cv2.cvtColor(curr_image, cv2.COLOR_BGR2GRAY)
            curr_gray = cv2.equalizeHist(curr_gray)

            if prev_gray is None:
                prev_gray = curr_gray
                continue

            # Motion detection
            diff_gray = cv2.absdiff(curr_gray, prev_gray)
            diff_gray[diff_gray < 50] = 0

            diff_blur = cv2.GaussianBlur(diff_gray, (5, 5), 0)
            _, diff_thresh = cv2.threshold(diff_blur, 25, 255, cv2.THRESH_BINARY)
            opening_kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (5, 5))
            diff_thresh = cv2.morphologyEx(diff_thresh, cv2.MORPH_OPEN, opening_kernel)
            diff_sum = np.sum(diff_thresh) / 255

            curr_motion = diff_sum > 10_000

            # AD detection
            time_img = curr_image[time_roi[1]:time_roi[1]+time_roi[3], time_roi[0]:time_roi[0]+time_roi[2]]
            time_r, time_g, time_b = cv2.split(time_img)
            diff_time_rg = cv2.absdiff(time_r, time_g)
            diff_time_rb = cv2.absdiff(time_r, time_b)
            diff_time_gb = cv2.absdiff(time_g, time_b)
            time_masks = (diff_time_rg < 30) & (diff_time_rb < 30) & (diff_time_gb > 30)
            _, time_thresh = cv2.threshold(time_img, 240, 255, cv2.THRESH_BINARY)
            time_edges = cv2.Canny(time_thresh, 80, 160)
            #time_density = np.mean(cv2.bitwise_and(time_edges, time_masks))
            time_density = np.mean(time_edges)

            curr_ad = time_density < 9 or time_density > 35

            # Recording
            if curr_motion:
                curr_motion_level = min(curr_motion_level + 1, 5)
            else:
                curr_motion_level = max(curr_motion_level - 1, 0)
            
            if curr_ad:
                curr_ad_level = min(curr_ad_level + 1, 5)
                total_ad += 1
            else:
                curr_ad_level = max(curr_ad_level - 1, 0)
                total_non_ad += 1

            global snippet_collection
            print(f"Motion: {curr_motion_level} ({diff_sum})  AD: {curr_ad_level} ({time_density})  Recording: {snippet_collection.recording} || {total_ad} AD frames, {total_non_ad} non-AD frames: %.2f%% AD" % (total_ad / (total_ad + total_non_ad + 1e-6) * 100))

            if snippet_collection.recording:
                if snippet_collection.thumbnail_timeout == 0:
                    snippet_collection.thumbnail_frame = curr_image.copy()
                    snippet_collection.thumbnail_timeout = -1

                    # Match filename with new thumbnail
                    now = datetime.now()

                    video_target_dir = f"{os.getenv("LIVESTREAM_VIDEO")}/{now.strftime('%Y-%m-%d')}"
                    os.makedirs(video_target_dir, exist_ok=True)
                    image_target_dir = f"{os.getenv("LIVESTREAM_IMAGE")}/{now.strftime('%Y-%m-%d')}"
                    os.makedirs(image_target_dir, exist_ok=True)
                    thumbnail_target_dir = f"{os.getenv("LIVESTREAM_THUMBNAIL")}/{now.strftime('%Y-%m-%d')}"
                    os.makedirs(thumbnail_target_dir, exist_ok=True)

                    snippet_collection.file_name = now.strftime('%Y-%m-%d_%H-%M-%S')
                    snippet_collection.video_target_file = f"{video_target_dir}/{snippet_collection.file_name}.mp4"
                    snippet_collection.image_target_file = f"{image_target_dir}/{snippet_collection.file_name}.png"
                    snippet_collection.thumbnail_target_file = f"{thumbnail_target_dir}/{snippet_collection.file_name}.jpg"
                elif snippet_collection.thumbnail_timeout > 0:
                    snippet_collection.thumbnail_timeout -= 1

            if snippet_collection.recording and (curr_motion_level <= 1 or curr_ad_level >= 2):
                snippet_collection.stop_recording(total_frames / FPS)
            elif not snippet_collection.recording and curr_motion_level >= 3 and curr_ad_level < 3 and curr_motion_level > curr_ad_level:
                snippet_collection.start_recording(curr_image, timeout_frames=3, time=total_frames / FPS, should_buffer_start=True)

            cv2.imshow("Normal", curr_image)
            cv2.imshow("GrayDiff", diff_gray)
            cv2.imshow("GrayBlur", diff_blur)
            cv2.imshow("Motion", diff_thresh)
            cv2.imshow("TimeROI", time_edges.astype(np.uint8))
            if cv2.waitKey(1) & 0xFF == ord("q"):
                break

            prev_gray = curr_gray
    except:
        raise

# Motion:
# * Einfahrt Samedan (13920): 2000-3000
# * Ausfahrt Tiefencastel (13840): 10000-120000
# * CamSwap (13870): >700000
# * Ausfahrt Bergün->Filisur (13877): 10000-100000

def run_capture(capture: Process):

    # files = [
    #     "/tmp/RhB_Cache/Livestream/media_w1919586290_b5500000_13817.ts",
    #     "/tmp/RhB_Cache/Livestream/media_w1919586290_b5500000_13818.ts",
    #     "/tmp/RhB_Cache/Livestream/media_w1919586290_b5500000_13819.ts",
    #     "/tmp/RhB_Cache/Livestream/media_w1919586290_b5500000_13820.ts",
    #     "/tmp/RhB_Cache/Livestream/media_w1919586290_b5500000_13821.ts",
    #     "/tmp/RhB_Cache/Livestream/media_w1919586290_b5500000_13822.ts",
    #     "/tmp/RhB_Cache/Livestream/media_w1919586290_b5500000_13823.ts",
    #     "/tmp/RhB_Cache/Livestream/media_w1919586290_b5500000_13824.ts",
    #     "/tmp/RhB_Cache/Livestream/media_w1919586290_b5500000_13825.ts",
    #     "/tmp/RhB_Cache/Livestream/media_w1919586290_b5500000_13826.ts",
    #     "/tmp/RhB_Cache/Livestream/media_w1919586290_b5500000_13827.ts",
    # ]
    # for file in files:
    #     with open(file, "rb") as f:
    #         data = f.read()

    #         global active_video_segment
    #         active_video_segment = file

    #         capture.stdin.write(data)
    #         capture.stdin.flush()

    # return


    target_dir = os.getenv("LIVESTREAM_SNIPPET")
    if (not os.path.exists(target_dir)):
        os.makedirs(target_dir, exist_ok=True)

    snippet_until_clear = snippet_clear_interval

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

                    global snippet_collection
                    snippet_collection.next_snippet(filepath)

                    capture.stdin.write(file_res.content)
                    capture.stdin.flush()

                    snippet_until_clear -= 1
                    if snippet_until_clear <= 0:
                        for file in os.listdir(target_dir):
                            stat = os.stat(f"{target_dir}/{file}")
                            if time.time() - stat.st_mtime > maximum_snippet_retention:
                                print(f"Removing old snippet {file} ({time.time() - stat.st_mtime}s old)")
                                os.remove(f"{target_dir}/{file}")
                        snippet_until_clear = snippet_clear_interval

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
        cv2.namedWindow("Normal", cv2.WINDOW_NORMAL)
        cv2.namedWindow("GrayDiff", cv2.WINDOW_NORMAL)
        cv2.namedWindow("GrayBlur", cv2.WINDOW_NORMAL)
        cv2.namedWindow("Motion", cv2.WINDOW_NORMAL)
        cv2.namedWindow("TimeROI", cv2.WINDOW_NORMAL)

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

    global snippet_collection
    snippet_collection = SnippetCollection()

    capture_thread = Thread(target=run_capture, args=[capture], daemon=True)
    capture_thread.start()
    run_analysis(capture)

    capture.kill()
    cv2.destroyAllWindows()

if __name__ == "__main__":
    main()
