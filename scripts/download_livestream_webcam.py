import os
import math
import time
import subprocess
import requests
import pytesseract
import sqlite3
import imagehash

from urllib.parse import urljoin
from dataclasses import dataclass
from datetime import datetime
from typing import Generic, TypeVar
from collections import deque
from threading import Thread
from queue import Queue, Empty
from PIL import Image

from dotenv import load_dotenv

import numpy as np
import cv2

livestream_url = "https://h058.video-stream-hosting.de/vocom-live/_definst_/smil:livestream.smil/chunklist_w1919586290_b5500000.m3u8"
debug_files = []

WIDTH = 1920
HEIGHT = 1080
FPS = 30

SCALE_FACTOR = 1.0 / 2.0

frame_size = WIDTH * HEIGHT * 3
frame_time = 1.0 / FPS

time_roi = (WIDTH - 400, 0, 400, 50)
location_roi = (0, HEIGHT - 60, 325, 60)

minimum_recording_duration = 4.0
maximum_snippet_retention = 3600.0
snippet_clear_interval = 100

debug_mode = len(debug_files) > 0
preview_mode = False or debug_mode
output_video = len(debug_files) == 0

FileQueue = Queue(bytes)
Process = subprocess.Popen


snippet_collection = None

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

    location: Location = None

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
            self.image_target_file = f"{image_target_dir}/{self.file_name}.jpg"
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
            
        print(f"== Stopped Recording at {datetime.now()} ({time - self.start_time}s: {self.start_time}-{time}) ==")
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

        hwaccel = os.getenv("HARDWARE_ACCELERATION")
        if hwaccel == "nvidia":
            subprocess.Popen([
                "ffmpeg", "-hide_banner", "-loglevel", "error",
                "-fflags", "+genpts",
                "-hwaccel", "cuda",
                "-hwaccel_output_format", "cuda",
                "-f", "concat", "-safe", "0",
                "-i", filelist,
                "-movflags", "+faststart", 
                "-c:v", "hevc_nvenc", 
                "-cq", "41",
                "-preset", "p7",
                "-level", "6.2",
                "-tier", "high",
                "-bf", "4",
                "-spatial_aq", "1",
                "-temporal_aq", "1",
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
                "-f", "concat", "-safe", "0",
                "-i", filelist,
                "-movflags", "+faststart", 
                "-c:v", "hevc_qsv", 
                "-global_quality", "40",
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

        # cv2.imwrite(self.image_target_file, self.thumbnail_frame, [cv2.IMWRITE_PNG_COMPRESSION, 9])
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
        database_cursor.execute(f"INSERT INTO livestream_capture (file, location) VALUES (\"{self.file_name}\", {(f'\"{self.location.names[0]}\"' if self.location else 'NULL')})")
        database.commit()

        # Send notification
        try:
            requests.post(f"http://localhost:{os.getenv("PORT")}/notifications/send", timeout=5, json={
                "password": os.getenv("NOTIFICATION_PASSWORD"),
                "location": "livestream",
                "file": self.file_name,
            })
        except Exception as e:
                print(f"Failed to send notification: {e}")

        print(f" => {self.video_target_file}  ({len(self.pending_flush)} segments)")
        self.pending_flush =  []

default_motion_threshold = 10_000 * (SCALE_FACTOR**2)
default_mask = [(0, 0), (WIDTH - 1, 0), (WIDTH - 1, HEIGHT - 1), (0, HEIGHT - 1)]

@dataclass
class Location:
    names: list[str]

    motion_threshold: float = default_motion_threshold

    masks: list[list[tuple[int, int]]] = None
    mask_image: np.typing.NDArray[np.float32] = None

    reference_threshold: float = 15.0
    reference_images: list[str] = None
    reference_hashes: set[imagehash.ImageHash] = None

    def __post_init__(self):
        if self.masks is None:
            self.masks = [default_mask]
        if self.reference_images is None:
            self.reference_images = []

        self.mask_image = np.zeros(shape=(np.int32(HEIGHT * SCALE_FACTOR), np.int32(WIDTH * SCALE_FACTOR)), dtype=np.uint8)
        for points in self.masks:
            cv2.fillPoly(self.mask_image, [np.array([[np.int32(point[0] * SCALE_FACTOR), np.int32(point[1] * SCALE_FACTOR)] for point in points], np.int32)], color=1)

        self.reference_hashes = set()
        for image in self.reference_images:
            image_path = f"{os.path.dirname(os.path.realpath(__file__))}/livestream_references/{image}"
            self.reference_hashes.add(imagehash.dhash(Image.open(image_path)))

# * Alp Grüm: False positive mit bernina pause

locations = [
    ## "Volatile"/"Nameless" cameras which require hash detection
    Location(
        names=["Reichenau-Tamins (Ost)"],
        reference_images=["reichenau_ost_tag.jpg", "reichenau_ost_nacht.jpg"],
        masks=[
            [(0, 0), (630, 0), (630, 250), (800, 250), (800, 80), (1180, 80), (1210, 200), (1919, 370), (1919, 1079), (0, 1079)]
        ],
        motion_threshold=15_000 * (SCALE_FACTOR**2)
    ),
    Location(
        names=["Reichenau-Tamins (West)"],
        reference_images=["reichenau_west_morgen.jpg", "reichenau_west_sonne.jpg", "reichenau_west_tag.jpg"],
        masks=[
            [(0, 450), (910, 240), (950, 100), (1919, 100), (1919, 1079), (0, 1079)]
        ],
        motion_threshold=15_000 * (SCALE_FACTOR**2)
    ),
    Location(
        names=["Filisur (Ost)"],
        reference_images=["filisur_ost_tag.jpg", "filisur_ost_nachmittag.jpg", "filisur_ost_abend.jpg", "filisur_ost_sonne.jpg", "filisur_ost_schatten.jpg"],
        masks=[
            [(0, 600), (870, 310), (1410, 310), (1400, 1079), (0, 1079)]
        ],
        motion_threshold=1_000 * (SCALE_FACTOR**2)
    ),
    Location(
        names=["Filisur (West)"],
        reference_images=["filisur_west_morgen.jpg", "filisur_west_tag.jpg", "filisur_west_abend.jpg"],
        masks=[
            [(0, 480), (920, 480), (650, 1079), (0, 1079)]
        ],
        motion_threshold=15_000 * (SCALE_FACTOR**2)
    ),

    ## "Noisy" cameras which require masking to avoid false positives
    Location(
        names=["Thusis", "Th us"],
        masks=[
            [(0, 1079), (350, 1079), (800, 60), (600, 60), (0, 250)],
            [(1630, 999), (1919, 999), (1919, 500), (1060, 60), (950, 60)],
        ],
        motion_threshold=15_000 * (SCALE_FACTOR**2)
    ),
    Location(
        names=["Untervaz"],
        masks=[
            [(1300, 1079), (1499, 1079), (1499, 999), (1919, 999), (1919, 700), (1080, 520), (930, 520)],
            [(1050, 1079), (850, 740), (680, 740), (400, 1079)],
        ],
        motion_threshold=5_000 * (SCALE_FACTOR**2)
    ),
    Location(
        names=["Bernina Cambrena"],
        masks=[
            #[(730, 350), (1300, 365), (1370, 375), (1370, 330), (1300, 330), (730, 330)],
            [(1380, 340), (1030, 370), (920, 470), (1040, 1079), (1760, 1079), (1580, 640), (1120, 475), (1380, 390)]
        ],
        motion_threshold=3_000 * (SCALE_FACTOR**2)
    ),
    Location(
        names=["Bernina Suot", "Suot"],
        masks=[
            [(0, 1000), (1210, 350), (1919, 380), (1919, 1079), (0, 1079)],
        ],
        motion_threshold=10_000 * (SCALE_FACTOR**2)
    ),
    Location(
        names=["Schnaus Strada", "Schnaus", "Strada"],
        masks=[
            [(1919, 600), (1919, 170), (1100, 140), (960, 150), (950, 200)],
            [(900, 1079), (1499, 1079), (1499, 600), (800, 240), (600, 240)]
        ],
        motion_threshold=15_000 * (SCALE_FACTOR**2)
    ),
    Location(
        names=["Ospizio Bernina"],
        masks=[
            [(850, 1079), (1919, 1079), (1919, 880), (630, 250), (530, 250)]
        ],
        motion_threshold=8_000 * (SCALE_FACTOR**2)
    ),
    Location(
        names=["Poschiavo Pradei", "Pradei"],
        masks=[default_mask],
        motion_threshold=default_motion_threshold
    ),
    Location(
        names=["Poschiavo"],
        masks=[
            [(0, 1079), (0, 770), (680, 520), (1380, 520), (1470, 1079)]
        ],
        motion_threshold=5_000 * (SCALE_FACTOR**2)
    ),
    Location(
        names=["Alp Grüm", "Alp"],
        masks=[
            [(610, 370), (690, 630), (950, 1079), (1919, 1079), (1919, 600), (720, 330), (610, 330)]
        ],
        motion_threshold=30_000 * (SCALE_FACTOR**2)
    ),
    Location(
        names=["Bergün"],
        masks=[
            [(300, 1079), (550, 160), (680, 130), (1060, 150), (1080, 300), (1919, 300), (1919, 1079)]
        ],
        motion_threshold=20_000 * (SCALE_FACTOR**2)
    ),
    Location(
        names=["Malans", "MEIERS", "MEIELS", "METETS", "METIEDE"],
        masks=[
            [(730, 1079), (570, 300), (660, 300), (1540, 1079)]
        ],
        motion_threshold=20_000 * (SCALE_FACTOR**2)
    ),
    # TODO
    Location(
        names=["Stablini", "VID-STAK-CAMM", "VID", "STAK", "CAMM"],
        masks=[
            #[(1040, 300), (1260, 1079), (1919, 1079), (1919, 500)]
            default_mask
        ],
        motion_threshold=default_motion_threshold
    ),
    Location(
        names=["Sagliains"],
        masks=[
            # Richtung Scoul
            [(0, 490), (830, 400), (830, 450), (0, 820)],
            [(960, 400), (860, 520), (160, 1079), (800, 1079), (1040, 520), (1010, 400)],
            # Richtung Samedan
            [(1060, 310), (0, 460), (0, 900), (1060, 370)],
            [(130, 1079), (1190, 320), (1250, 320), (1000, 1079)]
        ],
        motion_threshold=25_000 * (SCALE_FACTOR**2)
    ),
    # TODO
    Location(
        names=["Landwasserviadukt"],
        masks=[
            default_mask
        ],
        motion_threshold=default_motion_threshold
    ),
    Location(
        names=["Ems Werk", "Ems", "Werk"],
        masks=[
            [(0, 1079), (0, 630), (1420, 760), (1360, 1079)],
            [(950, 440), (1460, 440), (1500, 320), (1400, 320), (1040, 330)],
            [(650, 400), (1130, 330), (1130, 400)],
        ],
        motion_threshold=20_000 * (SCALE_FACTOR**2)
    ),
    Location(
        names=["Morteratsch"],
        masks=[
            [(460, 1079), (350, 80), (1690, 780), (1690, 1079)]
        ],
        motion_threshold=30_000 * (SCALE_FACTOR**2)
    ),

    ## Remaining cameras which just exist to track the location
    Location(
        names=["Samedan", "San;;dan", "Saniedan"],
    ),
    Location(
        names=["Bever"],
    ),
    Location(
        names=["Tiefencastel"],
    ),
    Location(
        names=["Filisur"],
    ),
    Location(
        names=["St. Moritz", "Moritz"],
    ),
    Location(
        names=["Bernina Lagalb", "Lagalb"],
    ),
    Location(
        names=["Cavaglia"],
    ),
]

def run_analysis(capture: Process):
    analysis_interval = int(1.0 * FPS)
    next_analysis = analysis_interval

    ocr_interval = 5
    next_ocr = ocr_interval

    curr_ad_level = 0
    curr_motion_level = 0
    curr_recording = False
    curr_location = None

    total_ad = 0
    total_non_ad = 0

    total_frames = 0

    prev_gray = None

    debug_paused = False

    try:
        while True:
            if preview_mode:
                time.sleep(1/60.0)

            key = cv2.waitKey(1) & 0xFF
            if debug_paused and key == ord("o"):
                debug_paused = False
            elif not debug_paused and key == ord("p"):
                debug_paused = True
            elif key == ord("q"):
                break

            if debug_paused and key != 27:
                continue

            raw = capture.stdout.read(frame_size)
            if len(raw) != frame_size:
                continue

            total_frames += 1

            next_analysis -= 1
            if next_analysis > 0:
                if not preview_mode:
                    continue

            curr_image = np.frombuffer(raw, np.uint8).reshape((HEIGHT, WIDTH, 3))

            if next_analysis > 0:
                cv2.imshow("Normal", curr_image)
                continue

            curr_gray = cv2.resize(cv2.cvtColor(curr_image, cv2.COLOR_BGR2GRAY), None, fx=SCALE_FACTOR, fy=SCALE_FACTOR)
            # curr_gray = cv2.equalizeHist(curr_gray)
            # curr_gray = cv2.GaussianBlur(curr_gray, (5, 5), 0)

            if prev_gray is None:
                prev_gray = curr_gray
                continue

            next_analysis = analysis_interval

            # AD detection
            time_img = curr_image[time_roi[1]:time_roi[1]+time_roi[3], time_roi[0]:time_roi[0]+time_roi[2]]
            time_r, time_g, time_b = cv2.split(time_img)
            diff_time_rg = cv2.absdiff(time_r, time_g)
            diff_time_rb = cv2.absdiff(time_r, time_b)
            diff_time_gb = cv2.absdiff(time_g, time_b)
            time_masks = (diff_time_rg < 30) & (diff_time_rb < 30) & (diff_time_gb > 30)
            _, time_thresh = cv2.threshold(time_img, 240, 255, cv2.THRESH_BINARY)
            time_edges = cv2.Canny(time_thresh, 80, 160)
            time_density = np.mean(time_edges)

            curr_ad = time_density < 9 or time_density > 35

            # Location detection
            next_ocr -= 1
            if next_ocr <= 0 and not curr_ad:
                # Compare hash against known cameras
                curr_hash = imagehash.dhash(Image.fromarray(curr_image))
                found_location = None
                for location in locations:
                    for location_hash in location.reference_hashes:
                        if abs(location_hash - curr_hash) < location.reference_threshold:
                            found_location = location
                            break
                    
                    if found_location is not None:
                        break

                if found_location is None:
                    location_img = curr_image[location_roi[1]:location_roi[1]+location_roi[3], location_roi[0]:location_roi[0]+location_roi[2]]
                    #location_img = cv2.GaussianBlur(location_img, (3, 3), 0)
                    location_r, location_g, location_b = cv2.split(location_img)
                    diff_location_rg = cv2.absdiff(location_r, location_g)
                    diff_location_rb = cv2.absdiff(location_r, location_b)
                    diff_location_gb = cv2.absdiff(location_g, location_b)
                    location_masks = (diff_location_rg < 20) & (diff_location_rb < 15) & (diff_location_gb > 15)
                    _, location_thresh = cv2.threshold(location_img, 200, 255, cv2.THRESH_BINARY)
                    location_density = np.mean(location_thresh)

                    dilate_kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (2, 2))
                    location_thresh = cv2.morphologyEx(location_thresh, cv2.MORPH_DILATE, dilate_kernel)

                    location_text = ""
                    try:
                        location_text = pytesseract.image_to_string(location_thresh, config="--psm 6 -l deu").strip()
                    except Exception as e:
                        print(f"OCR error: {e}")
                        pass

                    for location in locations:
                        for name in location.names:
                            if name in location_text:
                                found_location = location
                                break
                        
                        if found_location is not None:
                            break
                
                # Avoid updating to 'None' if OCR fails
                if found_location is not None or curr_ad_level > 0:
                    curr_location = found_location
                    next_ocr = ocr_interval
                elif location_density < 8:
                    curr_location = None
                    next_ocr = ocr_interval


            # Motion detection
            diff_gray = cv2.absdiff(curr_gray, prev_gray)
            diff_gray = cv2.GaussianBlur(diff_gray, (5, 5), 0)
            if curr_location is not None:
                diff_gray[(diff_gray * curr_location.mask_image) < 20] = 0
            else:
                diff_gray[diff_gray < 50] = 0

            _, diff_thresh = cv2.threshold(diff_gray, 25, 255, cv2.THRESH_BINARY)
            open_kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (5, 5))
            diff_thresh = cv2.morphologyEx(diff_thresh, cv2.MORPH_OPEN, open_kernel)
            diff_sum = np.sum(diff_thresh) / 255

            curr_motion = diff_sum > default_motion_threshold
            if curr_location is not None:
                curr_motion = diff_sum > location.motion_threshold

            # Recording
            if curr_motion:
                curr_motion_level = max(min(curr_motion_level + (-0.5 if curr_ad else 1.0), 5), 0)
            else:
                curr_motion_level = max(curr_motion_level - ( 2.0 if curr_ad else 1.0), 0)
            
            if curr_ad:
                curr_ad_level = min(curr_ad_level + 1, 5)
                total_ad += 1
            else:
                if curr_ad_level > 0:
                    next_ocr = 0 # Trigger rescan

                curr_ad_level = max(curr_ad_level - 1, 0)
                total_non_ad += 1

            global snippet_collection

            if snippet_collection.recording:
                if snippet_collection.location is None:
                    snippet_collection.location = curr_location

                if snippet_collection.thumbnail_timeout == 0 and not curr_ad and curr_motion:
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
                    snippet_collection.image_target_file = f"{image_target_dir}/{snippet_collection.file_name}.jpg"
                    snippet_collection.thumbnail_target_file = f"{thumbnail_target_dir}/{snippet_collection.file_name}.jpg"
                elif snippet_collection.thumbnail_timeout > 0:
                    snippet_collection.thumbnail_timeout -= 1

            if snippet_collection.recording and (curr_motion_level <= 1 or curr_ad_level >= 2):
                snippet_collection.stop_recording(total_frames / FPS)
            elif not snippet_collection.recording and curr_motion_level >= 3 and curr_ad_level < 3 and curr_motion_level > curr_ad_level + 1:
                snippet_collection.start_recording(curr_image, timeout_frames=3, time=total_frames / FPS, should_buffer_start=True)
                snippet_collection.location = curr_location

            if preview_mode:
                cv2.imshow("Normal", curr_image)
                if debug_mode:
                    if curr_location is not None:
                        cv2.imshow("GrayBlur", cv2.bitwise_and(curr_gray, curr_gray, mask=curr_location.mask_image))
                    else:
                        cv2.imshow("GrayBlur", curr_gray)

                    cv2.imshow("GrayDiff", diff_gray)
                    cv2.imshow("Motion", diff_thresh)
                    # cv2.imshow("TimeROI", time_edges.astype(np.uint8))
                
            prev_gray = curr_gray
    except:
        raise


def run_capture(capture: Process):
    if len(debug_files) > 0:
        for file in debug_files:
            with open(file, "rb") as f:
                data = f.read()

                capture.stdin.write(data)
                capture.stdin.flush()
        return

    global database
    global database_cursor
    database = sqlite3.connect(os.getenv("DATABASE_PROD_PATH"), check_same_thread=False)
    database_cursor = database.cursor()

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


def main():
    load_dotenv()

    if preview_mode:
        cv2.namedWindow("Normal", cv2.WINDOW_NORMAL)
    if debug_mode:
        cv2.namedWindow("GrayDiff", cv2.WINDOW_NORMAL)
        cv2.namedWindow("GrayBlur", cv2.WINDOW_NORMAL)
        cv2.namedWindow("Motion", cv2.WINDOW_NORMAL)
        # cv2.namedWindow("TimeROI", cv2.WINDOW_NORMAL)
        # cv2.namedWindow("LocationROI", cv2.WINDOW_NORMAL)

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
