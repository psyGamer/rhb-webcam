import os
import math
import subprocess

from datetime import datetime
from dataclasses import dataclass
from zoneinfo import ZoneInfo
from enum import Enum
from queue import Queue
from threading import Thread
from typing import Generic, TypeVar

from dotenv import load_dotenv

from PIL import ImageFont, ImageDraw, Image

import numpy as np
import cv2

webcam_url = "https://grischuna-cam.weta.ch/cgi-bin/mjpg/video.cgi?channel=0&subtype=1"

video_source = webcam_url

window_normal  = "Normal"
window_fg = "Foreground Mask"
window_same = "Identical Mask"
window_diff = "Difference"

snippet_duration = 10.0
check_interval = 1.0
minimum_recording_duration = 2.5

crop_region = { "x1": 340, "x2": 704, "y1": 300, "y2": 576 }
track_focal_point = (295, 300)

last_image_write = None

preview_mode = True
debug_mode = False
debug_log = False
output_video = video_source == webcam_url or not debug_mode

T = TypeVar("T")
class RingBuffer(Generic[T]):
    def __init__(self, capacity, dtype):
        self.array: np.ndarray[T] = np.empty(capacity, dtype)

        self.head = -1
        self.tail = 0
        self.capacity = capacity

    def __getitem__(self, item) -> T:
        if isinstance(item, int):
            idx = self.tail + item if item >= 0 else self.head + item + 1
            return self.array[idx]
        elif isinstance(item, slice):
            start_idx = (self.tail + item.start if item.start >= 0 else self.head + item.start + 1) if item.start is not None else self.tail
            stop_idx  = (self.tail + item.stop  if item.stop  >= 0 else self.head + item.stop  + 1) if item.stop  is not None else self.head + 1
            step_size = item.step or 1

            if self.tail <= self.head:
                start_idx = np.clip(start_idx, self.tail, self.head + 1)
                stop_idx  = np.clip(stop_idx,  self.tail, self.head + 1)
                return self.array[start_idx:stop_idx:step_size]
            else:
                start_idx = np.clip(start_idx % self.capacity, self.tail, self.capacity - 1)
                stop_idx  = np.clip(stop_idx  % self.capacity, 1, self.head + 1)
                return np.concatenate([
                    self.array[start_idx:self.capacity:step_size],
                    self.array[((self.capacity - start_idx) % step_size):stop_idx:step_size],
                ])

        return self._unwrap()[item]

    def insert(self, value: T):
        if self.head == -1:
            # Special case for first insert
            self.array[0] = value
            self.head = 0
            return

        self.head = (self.head + 1) % self.capacity
        if self.head == self.tail:
            self.tail = (self.tail + 1) % self.capacity # Discard oldest entry
        self.array[self.head] = value

    def fill(self, value: T):
        self.array[:] = value
        self.tail = 0
        self.head = self.capacity - 1

    def avg(self) -> T:
        if self.tail <= self.head:
            return np.average(self.array[self.tail:(self.head + 1)])
        elif (self.head + 1) % self.capacity == self.tail:
            return np.average(self.array)
        else:
            return np.average(np.concatenate([
                self.array[self.tail:self.capacity],
                self.array[0:(self.head + 1)],
            ]))
    def median(self) -> T:
        if self.tail <= self.head:
            return np.median(self.array[self.tail:(self.head + 1)])
        elif (self.head + 1) % self.capacity == self.tail:
            return np.median(self.array)
        else:
            return np.median(np.concatenate([
                self.array[self.tail:self.capacity],
                self.array[0:(self.head + 1)],
            ]))


@dataclass
class Condition:
    trigger_threshold: float
    trigger_cap: float
    trigger_increase: float = 1.0
    trigger_decrease: float = 1.0

    total_threshold: int = 0
    same_threshold: int = 0
    mask_delta_threshold: int = 0
    diff_threshold: int = 0
    diff_mask_threshold: int = 0

    max_total: int = 2**64
    max_same: int = 2**64
    max_avg_diff: int = 2**64

    buffer_time: float = 0.0

    trigger_value: float = 0.0

    def update(self, total: np.uint32, same: np.uint32, delta: np.uint32, diff_total: np.uint32, diff_avg: np.float32, diff_mask_total: np.uint32, already_triggered: bool) -> bool:
        if (total > self.max_total and same > self.max_same) or diff_avg > self.max_avg_diff:
            if already_triggered:
                return False # Maintain current state
            else:
                self.trigger_value = max(0.0, self.trigger_value - self.trigger_decrease)
                return False # Fall to zero
        
        if total >= self.total_threshold and same >= self.same_threshold and delta >= self.mask_delta_threshold and diff_total >= self.diff_threshold and diff_mask_total >= self.diff_mask_threshold:
            self.trigger_value = min(self.trigger_cap, self.trigger_value + self.trigger_increase)
        else:
            self.trigger_value = max(0.0, self.trigger_value - self.trigger_decrease)

        return self.trigger_value >= self.trigger_threshold

    
    def check(self, total: np.uint32, same: np.uint32, delta: np.uint32, diff_total: np.uint32, diff_avg: np.float32) -> bool:
        if (total > self.max_total and same > self.max_same) or diff_avg > self.max_avg_diff:
            return False

        return self.trigger_value >= self.trigger_threshold


@dataclass
class Area:
    name: str
    points: list[tuple[int, int]]
    conditions: list[Condition]

    region_mask: np.typing.NDArray[np.float32] = None
    region_area: int = 0

    computed_points: np.typing.NDArray[np.int32] = None

    diff_buffer: RingBuffer[np.float32] = None

    def __post_init__(self):
        self.computed_points = np.array([[np.int32(point[0]), np.int32(point[1])] for point in self.points], np.int32)
        self.computed_points = self.computed_points.reshape((-1,1,2))

        self.region_mask = np.zeros(shape=(crop_region["y2"] - crop_region["y1"], crop_region["x2"] - crop_region["x1"]), dtype=np.uint8)
        cv2.fillPoly(self.region_mask, [self.computed_points], color=1)
        self.region_area = int(np.sum(self.region_mask))

        self.diff_buffer = RingBuffer(capacity=120, dtype=np.float32)

    def trigger_check(self, fg_mask: np.typing.NDArray[np.uint8], same_mask: np.typing.NDArray[np.uint8], diff_image: np.typing.NDArray[np.uint8], diff_mask: np.typing.NDArray[np.uint8]) -> tuple[bool, float]:
        mask_total = np.sum(cv2.bitwise_and(fg_mask, self.region_mask), dtype=np.uint32)
        mask_same = np.sum(cv2.bitwise_and(same_mask, self.region_mask), dtype=np.uint32)
        mask_delta = mask_total - mask_same

        diff_total = np.sum(cv2.bitwise_and(diff_image, diff_image, mask=self.region_mask), dtype=np.uint32)
        diff_mask_total = np.sum(cv2.bitwise_and(diff_mask, self.region_mask), dtype=np.uint32)
        diff_avg = self.diff_buffer.median()
        self.diff_buffer.insert(diff_total)

        trigger_condition = None
        for condition in reversed(self.conditions):
            if trigger_condition is not None:
                condition.update(mask_total, mask_same, mask_delta, diff_total, diff_avg, diff_mask_total, already_triggered=True) # Ignore result, just update values

            if condition.update(mask_total, mask_same, mask_delta, diff_total, diff_avg, diff_mask_total, already_triggered=False):
                trigger_condition = condition

        if debug_log:
            print(f"== {self.name} == {mask_total}/{mask_same}/{(mask_total - mask_same)} || {diff_total}/{diff_avg}")
            for condition in self.conditions:
                if (mask_total > condition.max_total and mask_same > condition.max_same) or diff_avg > condition.max_avg_diff:
                    print("  [D", end="")
                else:
                    print("  [ ", end="")
                if condition.trigger_value >= condition.trigger_threshold:
                    print("T", end="")
                else:
                    print(" ", end="")
                if mask_total >= condition.total_threshold and mask_same >= condition.same_threshold and mask_delta >= condition.mask_delta_threshold and diff_total >= condition.diff_threshold and diff_mask_total >= condition.diff_mask_threshold:
                    print("X]", end="")
                else:
                    print(" ]", end="")

                if condition.total_threshold > 0:
                    print(f" MaskTotal: {mask_total}/{condition.total_threshold} ({(mask_total/condition.total_threshold)*100:.2f}%) ", end="")
                if condition.same_threshold > 0:
                    print(f" MaskSame: {mask_same}/{condition.same_threshold} ({(mask_same/condition.same_threshold)*100:.2f}%) ", end="")
                if condition.mask_delta_threshold > 0:
                    print(f" MaskDelta: {mask_delta}/{condition.mask_delta_threshold} ({(mask_delta/condition.mask_delta_threshold)*100:.2f}%) ", end="")
                if condition.diff_threshold > 0:
                    print(f" DiffTotal: {diff_total}/{condition.diff_threshold} ({(diff_total/condition.diff_threshold)*100:.2f}%) ", end="")
                if condition.diff_mask_threshold > 0:
                    print(f" DiffMask: {diff_mask_total}/{condition.diff_mask_threshold} ({(diff_mask_total/condition.diff_mask_threshold)*100:.2f}%) ", end="")
                
                print(f"-> Trigger: {condition.trigger_value}/{condition.trigger_threshold} ({(condition.trigger_value/condition.trigger_threshold)*100:.2f}%)")
    
        if trigger_condition:
            return (True, trigger_condition.buffer_time)
        else:
            return (False, 0.0)


    def draw(self, image, thickness):
        max_lerp = 0.0

        for condition in self.conditions:
            lerp = max(0.0, min(1.0, condition.trigger_value / condition.trigger_threshold))
            max_lerp = max(max_lerp, lerp)

        cv2.polylines(image, [self.computed_points], isClosed=True, color=(0, int(255.0*max_lerp), int(255.0*(1.0 - max_lerp))), thickness=thickness)

scan_areas = [
    Area(
        name="Gleis 1+2 - Richtung St. Moritz",
        points=[(170, 200), (250, 275), (363, 275), (363, 175), (215, 120)],
        conditions=[
            Condition(total_threshold=500, same_threshold=350, mask_delta_threshold=100, buffer_time=3.0, max_total=1_000, max_same=500, # Require small total, to avoid doors/people triggering after arrival
                      trigger_threshold=1.0, trigger_cap=3.0, trigger_increase=0.5, trigger_decrease=0.75),
            Condition(total_threshold=1_000, same_threshold=500, mask_delta_threshold=300, buffer_time=3.0,
                      trigger_threshold=1.0, trigger_cap=2.5, trigger_increase=0.5, trigger_decrease=0.75),
            Condition(total_threshold=10_000, same_threshold=0, mask_delta_threshold=500, buffer_time=2.0,
                      trigger_threshold=1.0, trigger_cap=2.0),

            # Trains can consistantly reach these values, rain/snow usually only spikes
            Condition(diff_threshold=100_000, diff_mask_threshold=1_000, buffer_time=7.0,
                      trigger_threshold=5.0, trigger_cap=8.0),
            Condition(diff_threshold=150_000, diff_mask_threshold=1_000, buffer_time=5.0,
                      trigger_threshold=3.0, trigger_cap=5.0),
            Condition(diff_threshold=200_000, diff_mask_threshold=1_000, buffer_time=0.0,
                      trigger_threshold=1.0, trigger_cap=3.0),
        ]
    ),
    Area(
        name="Gleis 1(+2) - Richtung Chur",
        points=[(170, 200), (215, 120), (10, 20), (10, 50)],
        conditions=[
            Condition(total_threshold=500, same_threshold=200, mask_delta_threshold=50, buffer_time=7.0, max_total=1_000, max_same=400, # Require small total, to avoid doors/people triggering after arrival
                      trigger_threshold=4.0, trigger_cap=8.0),
            Condition(total_threshold=1_000, same_threshold=400, mask_delta_threshold=300, buffer_time=5.0, 
                      trigger_threshold=3.0, trigger_cap=8.0),
            Condition(total_threshold=5_000, same_threshold=2_500, mask_delta_threshold=300, buffer_time=3.0, 
                      trigger_threshold=1.0, trigger_cap=3.0),

            Condition(same_threshold=50, diff_threshold=2_500, diff_mask_threshold=75, max_avg_diff=1_000, buffer_time=5.0, # Detect train movement far into the station during good weather
                      trigger_threshold=3.0, trigger_cap=5.0),
            Condition(same_threshold=100, diff_threshold=15_000, diff_mask_threshold=75, max_avg_diff=5_000, buffer_time=5.0, # BGSub has sometimes a really hard time detecting departures to Chur, so use this fallback during good weather
                      trigger_threshold=3.0, trigger_cap=5.0),
            Condition(same_threshold=100, diff_threshold=15_000, diff_mask_threshold=75, max_avg_diff=10_000, buffer_time=5.0, # BGSub has sometimes a really hard time detecting departures to Chur, so use this fallback during good weather
                      trigger_threshold=3.0, trigger_cap=5.0),
        ]
    ),
    Area(
        name="Gleis 2 - Top (Chur)",
        points=[(40, 25), (25, 25), (130, 85), (130, 55)],
        conditions=[
            Condition(total_threshold=300, same_threshold=150, mask_delta_threshold=75, buffer_time=7.0, 
                      trigger_threshold=4.0, trigger_cap=8.0),
            Condition(total_threshold=1_000, same_threshold=750, mask_delta_threshold=500, buffer_time=5.0, 
                      trigger_threshold=2.0, trigger_cap=4.0),

            Condition(same_threshold=25, diff_threshold=1_500, diff_mask_threshold=50, max_avg_diff=5_000, buffer_time=5.0, # Detect train movement far into the station during good weather
                      trigger_threshold=3.0, trigger_cap=5.0),
        ]
    ),
    Area(
        name="Gleis 2 - Top (St. Moritz)",
        points=[(130, 55), (130, 85), (363, 175), (363, 130)],
        conditions=[
            Condition(total_threshold=300, same_threshold=150, mask_delta_threshold=75, buffer_time=7.0, 
                      trigger_threshold=4.0, trigger_cap=8.0),
            Condition(total_threshold=1_000, same_threshold=750, mask_delta_threshold=500, buffer_time=5.0, 
                      trigger_threshold=2.0, trigger_cap=4.0),

            Condition(same_threshold=25, diff_threshold=10_000, diff_mask_threshold=250, max_avg_diff=5_000, buffer_time=5.0,
                      trigger_threshold=3.0, trigger_cap=5.0),
        ]
    ),
    Area(
        name="Gleis 3+4 - Side",
        points=[(130, 40), (150, 20), (362, 90), (362, 165)],
        conditions=[
            Condition(total_threshold=300, same_threshold=250, mask_delta_threshold=75, buffer_time=8.0, 
                      trigger_threshold=5.0, trigger_cap=8.0),
            Condition(total_threshold=1_000, same_threshold=1_000, mask_delta_threshold=75, buffer_time=5.0, 
                      trigger_threshold=2.0, trigger_cap=4.0),
        ]
    ),
]


@dataclass 
class SnippetCollection:
    previous_file: str = None
    current_file: str = None

    target_file: str = None

    recording: bool = False
    segments: list[str] = None
    pending_flush: list[str] = None

    start_time: float = 0.0

    def __post_init__(self):
        self.segments = []
        self.pending_flush = []

    def start_recording(self, time: float, should_buffer_start: bool):
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

            target_dir = f"{os.getenv("WEBCAM_VIDEO_ARCHIVE")}/{now.strftime('%Y-%m-%d')}"
            if (not os.path.exists(target_dir)):
                os.mkdir(target_dir)

            self.target_file = f"{target_dir}/{now.strftime('%Y-%m-%d_%H-%M-%S')}.mp4"
            self.start_time = time

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
            print(f" => {self.target_file}  ({len(self.pending_flush)} segments)")
            self.pending_flush =  []
            return

        ## Create file list
        filelist = f"flush_files.txt"
        with open(filelist, "w") as f:
            for segment in self.pending_flush:
                f.write(f"file '{segment}'\n")

        process = subprocess.Popen([
            "ffmpeg", "-hide_banner", "-loglevel", "error",
            "-f", "concat", "-safe", "0",
            "-i", filelist,
            "-c:v", "copy", self.target_file
        ])

        print(f" => {self.target_file}  ({len(self.pending_flush)} segments)")
        self.pending_flush =  []

class FFmpegVideoWriter:
    def __init__(self, filepath: str, width: int, height: int, fps: int):
        if not output_video:
            return

        self.process = subprocess.Popen([
            "ffmpeg", "-hide_banner", "-loglevel", "error",
            "-f", "rawvideo", "-r", str(fps), "-pix_fmt", "bgr24", "-s", f"{width}x{height}", "-i", "pipe:0",
            "-f", "mpegts", "-c:v", "h264", "-crf", "22", "-pix_fmt", "yuv420p", filepath
        ], stdin=subprocess.PIPE)

    def write(self, image: np.typing.NDArray[np.uint8]):
        if not output_video:
            return

        self.process.stdin.write(image.tobytes())

    def release(self):
        if not output_video:
            return

        self.process.stdin.close()


## Debug controls
auto_playback = video_source == webcam_url
auto_pause = False
auto_fastforward = False
auto_skip = 000
debug_images = {}


@dataclass
class StreamMeta:
    width: int
    height: int
    fps: float


DataQueue = Queue[StreamMeta | str | tuple[cv2.typing.MatLike, cv2.typing.MatLike] | FFmpegVideoWriter]

def run_analysis(queue: DataQueue):
    meta: StreamMeta = None
    collection = SnippetCollection()

    cropped_shape = (crop_region["y2"] - crop_region["y1"], crop_region["x2"] - crop_region["x1"])
    bg_sub = cv2.bgsegm.createBackgroundSubtractorMOG(history=60)

    total_count = 0
    timeout_counter = 0

    prev_image = None

    prev_fg_mask = None
    diff_mask2 = None
    prev_diff_mask_swap = None

    prev_writer: FFmpegVideoWriter = None

    while True:
        obj = queue.get()
        if isinstance(obj, str):
            if obj == "TERMINATE":
                queue.task_done()
                break

            # New snippet
            if output_video and prev_writer is not None and not collection.recording and len(collection.segments) != 0:
                prev_writer.process.wait()

            collection.next_snippet(obj)
        elif isinstance(obj, FFmpegVideoWriter):
            # Old writer
            prev_writer = obj
        elif isinstance(obj, StreamMeta):
            # Metadata update
            meta = obj
            print(f"Got metadata: {meta}")
        else:
            # Frame to analyse
            image_data: tuple[cv2.typing.MatLike, float] = obj
            curr_image, snippet_duration = image_data

            curr_gray = cv2.cvtColor(curr_image, cv2.COLOR_BGR2GRAY)
            curr_fg_mask = bg_sub.apply(curr_image)
            if prev_image is None or prev_fg_mask is None:
                prev_image = curr_gray
                prev_fg_mask = curr_fg_mask
                queue.task_done()
                continue
            
            diff_image = cv2.absdiff(curr_gray, prev_image)
            diff_image[diff_image < 5] = 0
            _, diff_mask = cv2.threshold(diff_image, 10, 1, cv2.THRESH_BINARY)
            diff_mask = cv2.morphologyEx(diff_mask, cv2.MORPH_ERODE, cv2.getStructuringElement(cv2.MORPH_RECT, (3,3)), diff_mask)
            diff_image = cv2.bitwise_and(diff_image, diff_image, mask=diff_mask)
            prev_image = curr_gray

            same_mask = cv2.bitwise_and(curr_fg_mask, prev_fg_mask)
            prev_fg_mask = curr_fg_mask

            global debug_images
            debug_images = { window_fg: cv2.cvtColor(curr_fg_mask, cv2.COLOR_GRAY2BGR), window_same: cv2.cvtColor(same_mask, cv2.COLOR_GRAY2BGR), window_diff: cv2.cvtColor(diff_image, cv2.COLOR_GRAY2BGR) }

            any_triggered = False
            should_buffer_start = True
            for area in scan_areas:
                trigger, buffer = area.trigger_check(curr_fg_mask, same_mask, diff_image, diff_mask)
                if trigger:
                    any_triggered = True
                    should_buffer_start = should_buffer_start and buffer > snippet_duration

            if any_triggered and not collection.recording:
                global auto_pause
                global auto_playback
                if auto_pause:
                    auto_playback = False

                collection.start_recording(total_count/meta.fps, should_buffer_start)
            elif not any_triggered and collection.recording:
                collection.stop_recording(total_count/meta.fps)

            total_count += int(check_interval*meta.fps)

        queue.task_done()


def run_capture(queue: DataQueue):
    months = {
         1: "Januar",
         2: "Februar",
         3: "März",
         4: "April",
         5: "Mai",
         6: "Juni",
         7: "Juli",
         8: "August",
         9: "September",
        10: "Oktober",
        11: "November",
        12: "Dezember",
    }

    font = ImageFont.load("../assets/mobotix_8pt.pil")
    font_size = 8
    font_scale = 2

    text_meta1 = "Filisur RhB Bahnhof"
    text_meta2 = "Hotel Grischuna"
    max_meta_len = max(len(text_meta1), len(text_meta2))
    textbox_meta = Image.new("LA", (max_meta_len * font_size + 1, (font_size + 1) * 2 + 1), color=(0,0))
    draw_meta = ImageDraw.Draw(textbox_meta)
    draw_meta.text((1, 1), text_meta1, font=font, fill=(0, 255))
    draw_meta.text((0, 0), text_meta1, font=font, fill=(255,255))
    draw_meta.text((1, font_size + 3), text_meta2, font=font, fill=(0, 255))
    draw_meta.text((0, font_size + 2), text_meta2, font=font, fill=(255,255))
    textbox_meta = textbox_meta.resize((textbox_meta.width * font_scale, textbox_meta.height * font_scale), Image.Resampling.NEAREST)

    max_text_time1 = "XX. September 20XX"
    max_text_time2 = "XX:XX:XX CEST"
    max_time_len = max(len(max_text_time1), len(max_text_time2))
    prev_time1 = None
    prev_time2 = None
    textbox_time_size = (max_time_len * font_size + 1, (font_size + 1) * 2 + 1)

    header_background: Image = None
    
    capture = cv2.VideoCapture(video_source)
    writer = None

    fail_counter = 0
    snippet_counter = 0
    frame_counter = 0

    meta: StreamMeta = None

    snippet_counter = 0
    snippet_time = 0

    check_counter = 2 # Allow all images to be initialized first
    check_time = 0

    curr_image: cv2.typing.MatLike = None
    ret: bool = None

    try:
        while True:
            ## Capture current
            ret, curr_image = capture.read(curr_image)
            if not ret:
                # Attempt 100 times
                fail_counter += 1
                if fail_counter > 100:
                    print("Capture failed due to unknown reasons")
                    capture.release()

                    if writer and output_video:
                        writer.release()
                        writer.process.wait()
                    return
                continue
            else:
                # Slowly return to zero
                fail_counter = max(0, fail_counter - 1)

            ## Extract metadata
            if not meta:
                meta = StreamMeta(
                    int(capture.get(cv2.CAP_PROP_FRAME_WIDTH)),
                    int(capture.get(cv2.CAP_PROP_FRAME_HEIGHT)),
                    capture.get(cv2.CAP_PROP_FPS) / (2 if video_source == webcam_url else 1), # For some reason the webcam reports double the actual value
                )
                queue.put(meta)

                snippet_time = int(snippet_duration*meta.fps)
                check_time = int(check_interval*meta.fps)

                header_background = Image.new("LA", (meta.width, textbox_meta.height + font_size), color=(0,48))


            ## Setup output writer for current snippet
            now = datetime.now(ZoneInfo("Europe/Zurich"))

            if writer is None or snippet_counter >= snippet_time:
                if writer:
                    writer.release()
                    queue.put(writer)

                hourly_now = now.replace(minute=0, second=0, microsecond=0)

                global last_image_write
                if output_video and (last_image_write is None or last_image_write != hourly_now):
                    last_image_write = hourly_now
                    cv2.imwrite(f"{os.getenv("WEBCAM_IMAGE_ARCHIVE")}/{now.strftime('%Y-%m-%d_%H-%M-%S')}.png", curr_image)

                target_dir = f"{os.getenv("WEBCAM_SNIPPET_CACHE")}/{now.strftime('%Y-%m-%d')}"
                if (not os.path.exists(target_dir)):
                    os.mkdir(target_dir)

                filepath = f"{target_dir}/{now.strftime('%Y-%m-%d_%H-%M-%S')}.mts"
                writer = FFmpegVideoWriter(filepath, meta.width, meta.height, meta.fps)
                snippet_counter = 0
                
                queue.put(filepath)

            if video_source != webcam_url:
                debug_image = curr_image.copy()
                cv2.putText(debug_image, "DEBUG REPLAY", (30, 120), cv2.FONT_HERSHEY_SIMPLEX, 1, (0, 0, 255), 2, cv2.LINE_AA)
                writer.write(debug_image)
            else:
                curr_time1 = f"{now.day:02d}. {months[now.month]} {now.year}"
                curr_time2 = f"{now:%H:%M:%S} {now.tzname():>4}"

                if curr_time1 != prev_time1 or curr_time2 != prev_time2:
                    textbox_time = Image.new("LA", textbox_time_size, color=(0,0))
                    draw_time = ImageDraw.Draw(textbox_time)
                    draw_time.text(((max_time_len - len(curr_time1)) * font_size + 1, 1), curr_time1, font=font, fill=(0,255))
                    draw_time.text(((max_time_len - len(curr_time1)) * font_size + 0, 0), curr_time1, font=font, fill=(255,255))
                    draw_time.text(((max_time_len - len(curr_time2)) * font_size + 1, font_size + 3), curr_time2, font=font, fill=(0,255))
                    draw_time.text(((max_time_len - len(curr_time2)) * font_size + 0, font_size + 2), curr_time2, font=font, fill=(255,255))
                    textbox_time = textbox_time.resize((textbox_time.width * font_scale, textbox_time.height * font_scale), Image.Resampling.NEAREST)

                    prev_time1 = curr_time1
                    prev_time2 = curr_time2

                offset = int(font_size / 2)
                pil_image = Image.fromarray(curr_image)
                pil_image.paste(header_background, (0,0), header_background)
                pil_image.paste(textbox_meta, (offset, offset), textbox_meta)
                pil_image.paste(textbox_time, (meta.width - textbox_time.width - offset, offset), textbox_time)
                curr_image = np.array(pil_image)
                writer.write(curr_image)

            frame_counter += 1
            snippet_counter += 1

            if check_counter > 0:
                check_counter -= 1
            else:
                check_counter = check_time

                queue.put((
                    cv2.resize(curr_image[crop_region["y1"]:crop_region["y2"], crop_region["x1"]:crop_region["x2"]], (0,0), fx=1, fy=1), 
                    snippet_counter/meta.fps
                ))

            if not debug_mode:
                if preview_mode:
                    if video_source != webcam_url:
                        cv2.imshow(window_normal, debug_image)
                    else:
                        cv2.imshow(window_normal, curr_image)
                    cv2.waitKey(1)

                continue

            # Wait until everything is analyzed
            queue.join()

            global auto_pause
            global auto_playback
            global auto_fastforward
            global auto_skip
            if auto_fastforward and auto_playback:
                continue
            if auto_skip > 0:
                auto_skip -= 1
                continue

            debug_image = curr_image[crop_region["y1"]:crop_region["y2"], crop_region["x1"]:crop_region["x2"]].copy()

            for area in scan_areas:
                area.draw(debug_image, thickness=2)
                for image in debug_images.values():
                    area.draw(image, thickness=1)

            if video_source != webcam_url:
                cv2.putText(debug_image, "DEBUG", (25, 210), cv2.FONT_HERSHEY_SIMPLEX, 1, (0, 0, 255), 2, cv2.LINE_AA)
                cv2.putText(debug_image, "REPLAY", (25, 240), cv2.FONT_HERSHEY_SIMPLEX, 1, (0, 0, 255), 2, cv2.LINE_AA)

            cv2.imshow(window_normal, debug_image)

            for window_name, image in debug_images.items():
                cv2.imshow(window_name, image)

            match cv2.waitKey(1):
                case 112: # 'p'
                    auto_playback = not auto_playback
                    print(f"Toggled auto-playback to {auto_playback}")
                case 97: # 'a'
                    auto_pause = not auto_pause
                    auto_fastforward = False
                    print(f"Toggled auto-pause to {auto_pause}")
                case 102: # 'f'
                    auto_fastforward = not auto_fastforward
                    auto_pause = True
                    print(f"Toggled auto-fastforward to {auto_fastforward}")

            if not auto_playback and check_counter == check_time:
                while True:
                    match cv2.waitKey(1):
                        case 112: # 'p'
                            auto_playback = True
                            print(f"Toggled auto-playback to {auto_playback}")
                            break
                        case 97: # 'a'
                            auto_pause = not auto_pause
                            auto_fastforward = False
                            print(f"Toggled auto-pause to {auto_pause}")
                        case 102: # 'f'
                            auto_fastforward = not auto_fastforward
                            auto_pause = True
                            print(f"Toggled auto-fastforward to {auto_fastforward}")
                        case 27: # ESC
                            break
    except:
        if writer and output_video:
            writer.release()
            writer.process.wait()
        
        raise

def capture_worker(queue: DataQueue):
    if debug_mode or preview_mode:
        cv2.namedWindow(window_normal, cv2.WINDOW_NORMAL)
    if debug_mode:
        cv2.namedWindow(window_fg, cv2.WINDOW_NORMAL)
        cv2.namedWindow(window_same, cv2.WINDOW_NORMAL)
        cv2.namedWindow(window_diff, cv2.WINDOW_NORMAL)

    if video_source == webcam_url:
        while True:
            print(f"Attemping capture on {datetime.now()}")
            try:
                run_capture(queue)
            except Exception as e:
                print(f"Unexpected exception: {e}")
    else:
        run_capture(queue)
        queue.put("TERMINATE")


def main():
    load_dotenv()

    queue: DataQueue = Queue(maxsize=0)
    capture_thread = Thread(target=capture_worker, args=[queue])
    capture_thread.daemon = True
    capture_thread.start()

    run_analysis(queue)

if __name__ == "__main__":
    main()

