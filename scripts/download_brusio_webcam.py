import os
import time
import select
import subprocess
import requests
import threading
import traceback

from queue import Queue, Empty
from zoneinfo import ZoneInfo
from pathlib import Path
from datetime import datetime, timedelta
from dataclasses import dataclass
from threading import Thread

from dotenv import load_dotenv

from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

import numpy as np
import cv2

import sqlite3

WEBCAM_URL = "https://stream.panda.cam/cam008/index.m3u8?cookieCheck=1"

SNIPPET_DURATION = 5
SNIPPET_CLEAR_INTERVAL = 3600.0
MIN_VIDEO_DURATION = 10.0

SCALE_FACTOR = 1.0 / 2.0
ROI = { "x1": 0, "x2": 1240, "y1": 420, "y2": 1040 }

debug_mode = False
output_video = True
last_image_write = None

database = None
database_cursor = None

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

    def start_recording(self, frame: cv2.typing.MatLike, timeout_frames: int, curr_time: float, should_buffer_start: bool):
        curr_date = datetime.fromtimestamp(curr_time)
        print(f"== Started Recording at {curr_date} ==")
        if len(self.pending_flush) != 0:
            self.segments = [self.current_file]
            self.start_time = curr_time
        elif len(self.segments) == 0:
            if not should_buffer_start or not self.previous_file:
                self.segments = [self.current_file]
            else:
                self.segments = [self.previous_file, self.current_file]

            video_target_dir = f"{os.getenv("WEBCAM_BRUSIO_VIDEO")}/{curr_date.strftime('%Y-%m-%d')}"
            if (not os.path.exists(video_target_dir)):
                os.makedirs(video_target_dir, exist_ok=True)
            image_target_dir = f"{os.getenv("WEBCAM_BRUSIO_IMAGE")}/{curr_date.strftime('%Y-%m-%d')}"
            if (not os.path.exists(image_target_dir)):
                os.makedirs(image_target_dir, exist_ok=True)
            thumbnail_target_dir = f"{os.getenv("WEBCAM_BRUSIO_THUMBNAIL")}/{curr_date.strftime('%Y-%m-%d')}"
            if (not os.path.exists(thumbnail_target_dir)):
                os.makedirs(thumbnail_target_dir, exist_ok=True)

            self.file_name = curr_date.strftime('%Y-%m-%d_%H-%M-%S')
            self.video_target_file = f"{video_target_dir}/{self.file_name}.mp4"
            self.image_target_file = f"{image_target_dir}/{self.file_name}.jpg"
            self.thumbnail_target_file = f"{thumbnail_target_dir}/{self.file_name}.jpg"
            self.start_time = curr_time
            self.thumbnail_frame = frame.copy()
            self.thumbnail_timeout = timeout_frames

        self.recording = True

    def stop_recording(self, curr_time: float):
        curr_date = datetime.fromtimestamp(curr_time)
        if curr_time - self.start_time < MIN_VIDEO_DURATION:
            print(f"== Cancelled Recording at {curr_date} ({curr_time - self.start_time}s delta) ==")

            if len(self.pending_flush) != 0 and len(self.segments) > 0:
                # Need to flush, to avoid gap in video
                self.flush()

            self.recording = False
            self.segments = []
            return
            
        print(f"== Stopped Recording at {curr_date} ==")
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
        filelist = f"flush_video_brusio.txt"
        with open(filelist, "w") as f:
            for segment in self.pending_flush:
                f.write(f"file '{segment}'\n")

        hwaccel = os.getenv("HARDWARE_ACCELERATION")
        if hwaccel == "nvidia":
            subprocess.Popen([
                "ffmpeg", "-hide_banner", "-loglevel", "error",
                "-fflags", "+genpts",
                "-hwaccel", "cuda", "-hwaccel_output_format", "cuda",
                "-f", "concat", "-safe", "0",
                "-i", filelist,
                "-movflags", "+faststart", 
                "-c:v", "hevc_nvenc", 
                "-cq", "38",
                "-preset", "p7",
                "-level", "6.2",
                "-tier", "high",
                "-bf", "4",
                "-rc", "vbr",
                "-multipass", "fullres",
                "-tf_level", "4",
                "-an",
                self.video_target_file
            ])
        elif hwaccel == "intel":
            subprocess.Popen([
                "ffmpeg", "-hide_banner", "-loglevel", "error",
                "-fflags", "+genpts",
                "-hwaccel", "qsv", "-hwaccel_output_format", "qsv", "-extra_hw_frames", "16",
                "-f", "concat", "-safe", "0",
                "-i", filelist,
                "-movflags", "+faststart", 
                "-c:v", "hevc_qsv", 
                "-global_quality", "38",
                "-preset", "veryslow",
                "-scenario", "videosurveillance",
                "-bf", "8",
                "-an",
                self.video_target_file
            ])
        else:
            subprocess.Popen([
                "ffmpeg", "-hide_banner", "-loglevel", "error",
                "-fflags", "+genpts",
                "-f", "concat", "-safe", "0",
                "-i", filelist,
                "-movflags", "+faststart", 
                "-c:v", "copy", 
                "-an",
                self.video_target_file
            ])

        cv2.imwrite(self.image_target_file, self.thumbnail_frame, [
            cv2.IMWRITE_JPEG_QUALITY, 50,
            cv2.IMWRITE_JPEG_PROGRESSIVE, 1,
            cv2.IMWRITE_JPEG_OPTIMIZE, 1
        ])

        subprocess.Popen([
            "ffmpeg", "-hide_banner", "-loglevel", "error",
            "-i", self.image_target_file,
            "-vf", "crop=iw:iw*9/16:0:ih-iw*9/16,scale=-2:144",
            "-q:v", "10",
            "-frames:v", "1",
            "-update", "1",
            self.thumbnail_target_file
        ])

        global database
        global database_cursor
        database_cursor.execute(f"INSERT INTO alpgr_capture (file) VALUES (\"{self.file_name}\")")
        database.commit()

        # Send notification
        try:
            requests.post(f"http://localhost:{os.getenv("PORT")}/notifications/send", timeout=5, json={
                "password": os.getenv("NOTIFICATION_PASSWORD"),
                "location": "brusio",
                "file": self.file_name,
            })
        except Exception as e:
            print(f"Failed to send notification: {e}")

        print(f" => {self.video_target_file}  ({len(self.pending_flush)} segments)")
        self.pending_flush =  []



def extract_frames(file: Path):
    cap = cv2.VideoCapture(str(file))

    if not cap.isOpened():
        print(f"Failed to open {file}")
        return

    try:
        fps = cap.get(cv2.CAP_PROP_FPS)

        if not fps or fps <= 0:
            print(f"Invalid FPS for {file}")
            return

        file_time = datetime.strptime(file.stem, "%Y-%m-%d_%H-%M-%S")

        next_pos = 0

        while True:
            ok, frame = cap.read()
            if not ok:
                break

            curr_pos = cap.get(cv2.CAP_PROP_POS_MSEC)
            if curr_pos >= next_pos:
                yield {
                    "time": file_time + timedelta(milliseconds=curr_pos),
                    "frame": frame,
                }

                next_pos += 1000

    finally:
        cap.release()


class SegmentHandler(FileSystemEventHandler):
    def __init__(self, debug_frame_queue: Queue):
        super().__init__()

        self.processing = set()
        self.queue = Queue(3)
        self.debug_frame_queue = debug_frame_queue
        self.lock = threading.Lock()

        self.last_date = None
        self.next_snippet_clear = time.time()

        # Limit to only rails
        self.mask = np.zeros(shape=(np.int32((ROI["y2"] - ROI["y1"]) * SCALE_FACTOR), np.int32((ROI["x2"] - ROI["x1"]) * SCALE_FACTOR)), dtype=np.uint8)

        mask_points = [(0, 420), (840, 530), (780, 580), (0, 470)]
        cv2.fillPoly(self.mask, [np.array([[np.int32((point[0] - ROI["x1"]) * SCALE_FACTOR), np.int32((point[1] - ROI["y1"]) * SCALE_FACTOR)] for point in mask_points], np.int32)], color=1)
        mask_points = [(1010, 640), (1120, 720), (0, 840), (420, 1010), (1220, 820), (1240, 670), (990, 570)]
        cv2.fillPoly(self.mask, [np.array([[np.int32((point[0] - ROI["x1"]) * SCALE_FACTOR), np.int32((point[1] - ROI["y1"]) * SCALE_FACTOR)] for point in mask_points], np.int32)], color=1)

        self.collection = SnippetCollection()
        self.prev_gray = None
        self.curr_motion_level = 0
        self.diff_accum = np.zeros(shape=(np.int32((ROI["y2"] - ROI["y1"]) * SCALE_FACTOR), np.int32((ROI["x2"] - ROI["x1"]) * SCALE_FACTOR)), dtype=np.uint8)
        self.rect5x5_kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (5, 5))


    def on_created(self, event):
        if event.is_directory:
            return

        path = Path(event.src_path)
        if path.suffix.lower() != ".mts":
            return

        self.queue.put(path)

        # The last snippet is probably done by now
        if self.queue.full():
            self.process_segment(self.queue.get())

    def process_segment(self, file: Path):
        self.collection.next_snippet(str(file))

        now = datetime.now(ZoneInfo("Europe/Zurich"))
        now_time = time.time()

        curr_date = now.strftime('%Y-%m-%d')
        if self.last_date is None:
            self.last_date = curr_date
        
        if curr_date != self.last_date:
            self.next_snippet_clear = now_time + SNIPPET_CLEAR_INTERVAL

            clear_thread = Thread(target=cleanup_snippets, args=[self.last_date, 0])
            clear_thread.start()

            self.last_date = curr_date
        elif now_time >= self.next_snippet_clear and (now.hour < 23 or now.minute < 30): # Don't trigger in last 30min since the date change will handle it
            self.next_snippet_clear = now_time + SNIPPET_CLEAR_INTERVAL

            clear_thread = Thread(target=cleanup_snippets, args=[curr_date, SNIPPET_CLEAR_INTERVAL])
            clear_thread.start()
        
        for result in extract_frames(file):
            frame = result["frame"]
            curr_time = result["time"]
            curr_timestamp = curr_time.timestamp()

            curr_hour = curr_time.replace(minute=0, second=0, microsecond=0)

            global last_image_write
            if output_video and (last_image_write is None or last_image_write != curr_hour):
                last_image_write = curr_hour
                os.makedirs(os.getenv("WEBCAM_BRUSIO_SNAPSHOT"), exist_ok=True)
                cv2.imwrite(f"{os.getenv("WEBCAM_BRUSIO_SNAPSHOT")}/{curr_time.strftime('%Y-%m-%d_%H-%M-%S')}.jpg", frame)

            curr_gray = cv2.resize(cv2.cvtColor(frame[ROI["y1"]:ROI["y2"], ROI["x1"]:ROI["x2"]], cv2.COLOR_BGR2GRAY), None, fx=SCALE_FACTOR, fy=SCALE_FACTOR)

            if self.prev_gray is None:
                self.prev_gray = curr_gray
                continue

            diff_gray = cv2.absdiff(curr_gray, self.prev_gray)
            diff_gray = cv2.GaussianBlur(diff_gray, (5, 5), 0)
            _, diff_thresh = cv2.threshold(diff_gray * self.mask, 35, 255, cv2.THRESH_BINARY)
            diff_thresh = cv2.morphologyEx(diff_thresh, cv2.MORPH_DILATE, self.rect5x5_kernel)
            diff_gray[(diff_gray * self.mask) < 25] = 0

            self.diff_accum = ((self.diff_accum * 0.75) + diff_gray)
            _, accum_thresh = cv2.threshold(self.diff_accum, 20.0, 255, cv2.THRESH_BINARY)
            accum_thresh = cv2.morphologyEx(accum_thresh, cv2.MORPH_ERODE, self.rect5x5_kernel)

            motion_mask = cv2.bitwise_and(accum_thresh, accum_thresh, mask=diff_thresh)
            motion_sum = np.sum(motion_mask) / 255

            curr_motion = motion_sum >= 1000

            if curr_motion:
                self.curr_motion_level = min(self.curr_motion_level + 1, 5)
            else:
                self.curr_motion_level = max(self.curr_motion_level - 1, 0)

            if self.collection.recording:
                if self.collection.thumbnail_timeout == 0 and curr_motion:
                    self.collection.thumbnail_frame = frame.copy()
                    self.collection.thumbnail_timeout = -1

                    # Match filename with new thumbnail
                    curr_date = datetime.fromtimestamp(curr_timestamp)
                    video_target_dir = f"{os.getenv("WEBCAM_BRUSIO_VIDEO")}/{curr_date.strftime('%Y-%m-%d')}"
                    os.makedirs(video_target_dir, exist_ok=True)
                    image_target_dir = f"{os.getenv("WEBCAM_BRUSIO_IMAGE")}/{curr_date.strftime('%Y-%m-%d')}"
                    os.makedirs(image_target_dir, exist_ok=True)
                    thumbnail_target_dir = f"{os.getenv("WEBCAM_BRUSIO_THUMBNAIL")}/{curr_date.strftime('%Y-%m-%d')}"
                    os.makedirs(thumbnail_target_dir, exist_ok=True)

                    self.collection.file_name = curr_date.strftime('%Y-%m-%d_%H-%M-%S')
                    self.collection.video_target_file = f"{video_target_dir}/{self.collection.file_name}.mp4"
                    self.collection.image_target_file = f"{image_target_dir}/{self.collection.file_name}.jpg"
                    self.collection.thumbnail_target_file = f"{thumbnail_target_dir}/{self.collection.file_name}.jpg"
                elif self.collection.thumbnail_timeout > 0:
                    self.collection.thumbnail_timeout -= 1

            if self.collection.recording and self.curr_motion_level <= 1:
                self.collection.stop_recording(curr_timestamp)
            elif not self.collection.recording and self.curr_motion_level >= 3:
                self.collection.start_recording(frame, timeout_frames=3, curr_time=curr_timestamp, should_buffer_start=True)

            self.prev_gray = curr_gray
            
            if self.debug_frame_queue is not None:
                self.debug_frame_queue.put({
                    "Output": frame,
                    "CurrGray": curr_gray,
                    "DiffGray": diff_gray,
                    "DiffAccum": self.diff_accum / 255,
                    "MotionDiff": diff_thresh,
                    "MotionAccum": accum_thresh,
                    "Motion": motion_mask,
                })
                while not self.debug_frame_queue.empty():
                    pass

def run_analysis():
    debug_frame_queue = Queue(100) if debug_mode else None
    
    handler = SegmentHandler(debug_frame_queue)

    observer = Observer()
    observer.schedule(handler, os.getenv("WEBCAM_BRUSIO_SNIPPET"), recursive=True)
    observer.start()

    try:
        if debug_mode:
            while True:
                try:
                    frames = debug_frame_queue.get_nowait()
                    for name in frames:
                        cv2.imshow(name, frames[name])
                except Empty:
                    pass
            
                cv2.waitKey(0)
        else:
            # Ensure tomorrows snippet directory exists and is watched
            while True:
                tomorrow = datetime.now(ZoneInfo("Europe/Zurich")) + timedelta(days=1)
                snippet_target_dir = f"{os.getenv("WEBCAM_BRUSIO_SNIPPET")}/{tomorrow.strftime('%Y-%m-%d')}"
                print(f"Tomorrows snippet dir '{snippet_target_dir}'")
                if (not os.path.exists(snippet_target_dir)):
                    print("Recreating observer")
                    observer.stop()
                    observer.join()

                    os.makedirs(snippet_target_dir, exist_ok=True)

                    observer = Observer()
                    observer.schedule(handler, os.getenv("WEBCAM_BRUSIO_SNIPPET"), recursive=True)
                    observer.start()

                time.sleep(3600)

    except KeyboardInterrupt:
        observer.stop()

    observer.join()

def run_capture():
    now = datetime.now(ZoneInfo("Europe/Zurich"))
    snippet_target_dir = f"{os.getenv("WEBCAM_BRUSIO_SNIPPET")}/{now.strftime('%Y-%m-%d')}"
    if (not os.path.exists(snippet_target_dir)):
        os.makedirs(snippet_target_dir, exist_ok=True)

    capture = subprocess.Popen([
        "ffmpeg",
        "-hide_banner", "-loglevel", "error",

        "-headers", "Referer: https://stream.panda.cam",
        "-user_agent", "RhB Archive (rhb.webcam@gmail.com) If this automated capture is causing issues, please contact me!",
        "-i", WEBCAM_URL,
        "-c:v", "copy", "-an",

        "-f", "segment",
        "-segment_time", str(SNIPPET_DURATION),
        "-reset_timestamps", "1",

        "-strftime", "1",
        f"{os.getenv("WEBCAM_BRUSIO_SNIPPET")}/%Y-%m-%d/%Y-%m-%d_%H-%M-%S.mts"
    ])

    try:
        capture.wait()
    except:
        capture.kill()
        raise

def capture_worker():
    while True:
        print(f"Attemping capture on {datetime.now()}")
        try:
            run_capture()
        except Exception as e:
            print(f"Unexpected exception: {e}")
            print(traceback.format_exc())


def cleanup_snippets(day, max_age):
    target_dir = f"{os.getenv("WEBCAM_BRUSIO_SNIPPET")}/{day}"

    filelist = f"flush_hourly_brusio.txt"
    files = []

    with open(filelist, "w") as f:
        for file in sorted(os.listdir(target_dir)):
            stat = os.stat(f"{target_dir}/{file}")
            if time.time() - stat.st_mtime > max_age:
                print(f"Removing old snippet {file} ({time.time() - stat.st_mtime}s old)")
                if stat.st_size == 0:
                    os.remove(f"{target_dir}/{file}")
                    continue

                if len(files) < 60:
                    f.write(f"file '{target_dir}/{file}'\n")
                    files.append(file)

    if len(files) == 0:
        return

    # The file-size requirement is currently too large for it to be worth it
    if False:
        hourly_dir = f"{os.getenv("WEBCAM_BRUSIO_HOURLY")}/{day}"
        hourly_file = f"{hourly_dir}/{files[0][:-4]}.mp4"

        os.makedirs(hourly_dir, exist_ok=True)

        hwaccel = os.getenv("HARDWARE_ACCELERATION")
        if hwaccel == "nvidia":
            p = subprocess.Popen([
                "ffmpeg",
                # "-hide_banner", "-loglevel", "error",
                "-fflags", "+genpts",
                "-hwaccel", "cuda", "-hwaccel_output_format", "cuda",
                "-f", "concat", "-safe", "0",
                "-i", filelist,
                "-movflags", "+faststart",
                "-vf", "scale_cuda=format=nv12",
                "-c:v", "h264_nvenc",
                "-preset", "p7",
                "-rc", "vbr",
                "-cq", "42",
                "-b:v", "25k",
                "-maxrate", "60k",
                "-bufsize", "120k",
                "-spatial-aq", "1",
                "-temporal-aq", "1",
                "-aq-strength", "1",
                "-bf", "4",
                "-g", "300",
                "-tf_level", "4",
                "-an",
                hourly_file
            ])
        elif hwaccel == "intel":
            p = subprocess.Popen([
                "ffmpeg", "-hide_banner", "-loglevel", "error",
                "-fflags", "+genpts",
                "-hwaccel", "qsv", "-hwaccel_output_format", "qsv", "-extra_hw_frames", "16",
                "-f", "concat", "-safe", "0",
                "-i", filelist,
                "-movflags", "+faststart", 
                "-vf", "vpp_qsv=format=nv12",
                "-c:v", "h264_qsv",
                "-global_quality", "42",
                "-preset", "veryslow",
                "-scenario", "videosurveillance",
                "-bf", "8",
                "-an",
                hourly_file
            ])
        else:
            raise Exception("Not implemented")

        print(f"Starting hourly archive with {len(files)} snippets...")
        p.wait()
        print(f"Finished hourly archive for '{files[0][:-4]}.mp4'")

    for file in files:
        os.remove(f"{target_dir}/{file}")


def main():
    load_dotenv()
    
    if debug_mode:
        cv2.namedWindow("Output", cv2.WINDOW_NORMAL)
        cv2.namedWindow("CurrGray", cv2.WINDOW_NORMAL)
        cv2.namedWindow("DiffGray", cv2.WINDOW_NORMAL)
        cv2.namedWindow("DiffAccum", cv2.WINDOW_NORMAL)
        cv2.namedWindow("MotionDiff", cv2.WINDOW_NORMAL)
        cv2.namedWindow("MotionAccum", cv2.WINDOW_NORMAL)
        cv2.namedWindow("Motion", cv2.WINDOW_NORMAL)
        cv2.waitKey(1)

    global database
    global database_cursor
    database = sqlite3.connect(os.getenv("DATABASE_PROD_PATH"))
    database_cursor = database.cursor()
    
    capture_thread = Thread(target=capture_worker, args=[])
    capture_thread.daemon = True
    capture_thread.start()
    
    run_analysis()

if __name__ == "__main__":
    main()

