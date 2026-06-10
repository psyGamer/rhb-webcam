import os
import time
import select
import subprocess
import requests

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

import sqlite3

webcam_url = "http://webcam2.internet-box.ch/channel2"
debug_files = [
]

debug_mode = False
output_video = True or len(debug_files) == 0

WIDTH = 1280
HEIGHT = 1024

SCALE_FACTOR = 1.0 / 2.0

frame_size = WIDTH * HEIGHT * 3

snippet_duration = 10.0
snippet_clear_interval = 3600.0
check_interval = 1.0
minimum_recording_duration = 10.0

crop_region = { "x1": 0, "x2": 700, "y1": 375, "y2": HEIGHT }
last_image_write = None

database = None
database_cursor = None

class FFmpegVideoWriter:
    def __init__(self, filepath: str, width: int, height: int, start_time):
        self.start_time = start_time

        if not output_video:
            return

        hwaccel = os.getenv("HARDWARE_ACCELERATION")
        if hwaccel == "nvidia":
            init_args = [
                "-hwaccel", "cuda", "-hwaccel_output_format", "cuda",
            ]
            codec_args = [
                "-c:v", "h264_nvenc",
                "-preset", "fast",
                "-rc", "vbr_hq",
                "-cq", "24",
            ]
        elif hwaccel == "intel":
            init_args = [
                "-hwaccel", "qsv", "-hwaccel_output_format", "qsv", "-extra_hw_frames", "16",
            ]
            codec_args = [
                "-c:v", "h264_qsv",
                "-preset", "fast",
                "-global_quality", "24",
            ]
        else:
            init_args = []
            codec_args = [
                "-c:v", "libx264",
                "-preset", "ultrafast",
                "-crf", "24",
                "-tune", "zerolatency",
            ]

        self.process = subprocess.Popen([
            "ffmpeg", "-hide_banner", "-loglevel", "error", *init_args,
            "-f", "rawvideo", "-use_wallclock_as_timestamps", "1", "-pix_fmt", "bgr24", "-s", f"{width}x{height}", "-i", "pipe:0",
            "-f", "mpegts", *codec_args, "-pix_fmt", "yuv420p", filepath,
        ], stdin=subprocess.PIPE)

    def write(self, image: np.typing.NDArray[np.uint8]):
        if not output_video:
            return

        self.process.stdin.write(image.tobytes())

    def release(self):
        if not output_video:
            return

        self.process.stdin.close()

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

            video_target_dir = f"{os.getenv("WEBCAM_ALPGR_VIDEO")}/{curr_date.strftime('%Y-%m-%d')}"
            if (not os.path.exists(video_target_dir)):
                os.makedirs(video_target_dir, exist_ok=True)
            image_target_dir = f"{os.getenv("WEBCAM_ALPGR_IMAGE")}/{curr_date.strftime('%Y-%m-%d')}"
            if (not os.path.exists(image_target_dir)):
                os.makedirs(image_target_dir, exist_ok=True)
            thumbnail_target_dir = f"{os.getenv("WEBCAM_ALPGR_THUMBNAIL")}/{curr_date.strftime('%Y-%m-%d')}"
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
        if curr_time - self.start_time < minimum_recording_duration:
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
        filelist = f"flush_files_alpgr.txt"
        with open(filelist, "w") as f:
            for segment in self.pending_flush:
                f.write(f"file '{segment}'\n")

        p = subprocess.Popen([
            "ffmpeg", "-hide_banner", "-loglevel", "error",
            "-fflags", "+genpts",
            "-f", "concat", "-safe", "0",
            "-i", filelist,
            "-movflags", "+faststart", 
            "-c:v", "libx265",
            "-preset", "ultrafast",
            "-crf", "25",
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
                "location": "alpgr",
                "file": self.file_name,
            })
        except Exception as e:
            print(f"Failed to send notification: {e}")

        print(f" => {self.video_target_file}  ({len(self.pending_flush)} segments)")
        self.pending_flush =  []


DataQueue = Queue[str | tuple[cv2.typing.MatLike, cv2.typing.MatLike] | FFmpegVideoWriter]

def run_analysis(queue: DataQueue):
    collection = SnippetCollection()

    curr_motion_level = 0

    prev_gray = None
    prev_writer: FFmpegVideoWriter = None

    # Limit to only rails
    mask = np.zeros(shape=(np.int32((crop_region["y2"] - crop_region["y1"]) * SCALE_FACTOR), np.int32((crop_region["x2"] - crop_region["x1"]) * SCALE_FACTOR)), dtype=np.uint8)
    mask_points = [(0, 240), (380, 60), (380, 0), (700, 0), (700, 220), (480, 648), (0, 648)]
    cv2.fillPoly(mask, [np.array([[np.int32(point[0] * SCALE_FACTOR), np.int32(point[1] * SCALE_FACTOR)] for point in mask_points], np.int32)], color=1)

    diff_accum = np.zeros(shape=(np.int32((crop_region["y2"] - crop_region["y1"]) * SCALE_FACTOR), np.int32((crop_region["x2"] - crop_region["x1"]) * SCALE_FACTOR)), dtype=np.uint8)

    rect5x5_kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (5, 5))

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
        else:
            # Frame to analyse
            image_data: tuple[cv2.typing.MatLike, float] = obj
            curr_frame, curr_time = image_data
            curr_image = curr_frame[crop_region["y1"]:crop_region["y2"], crop_region["x1"]:crop_region["x2"]]

            curr_gray = cv2.resize(cv2.cvtColor(curr_image, cv2.COLOR_BGR2GRAY), None, fx=SCALE_FACTOR, fy=SCALE_FACTOR)

            if prev_gray is None:
                prev_gray = curr_gray
                queue.task_done()
                continue

            diff_gray = cv2.absdiff(curr_gray, prev_gray)
            diff_gray = cv2.GaussianBlur(diff_gray, (5, 5), 0)
            _, diff_thresh = cv2.threshold(diff_gray * mask, 10, 255, cv2.THRESH_BINARY)
            diff_thresh = cv2.morphologyEx(diff_thresh, cv2.MORPH_DILATE, rect5x5_kernel)
            diff_gray[(diff_gray * mask) < 15] = 0

            diff_accum = ((diff_accum * 0.75) + diff_gray)
            _, accum_thresh = cv2.threshold(diff_accum, 20.0, 255, cv2.THRESH_BINARY)
            accum_thresh = cv2.morphologyEx(accum_thresh, cv2.MORPH_ERODE, rect5x5_kernel)

            motion_mask = cv2.bitwise_and(accum_thresh, accum_thresh, mask=diff_thresh)
            motion_sum = np.sum(motion_mask) / 255

            curr_motion = motion_sum >= 3000

            if debug_mode:
                cv2.imshow("full", curr_frame)
                cv2.imshow("img", curr_gray)
                cv2.imshow("diff", diff_gray)
                cv2.imshow("accum", diff_accum / 255)
                cv2.imshow("motion diff", diff_thresh)
                cv2.imshow("motion accum", accum_thresh)
                cv2.imshow("motion", motion_mask)
                while cv2.waitKey(1) != ord('c'):
                    pass

            if curr_motion:
                curr_motion_level = min(curr_motion_level + 1, 5)
            else:
                curr_motion_level = max(curr_motion_level - 1, 0)

            if collection.recording:
                if collection.thumbnail_timeout == 0 and curr_motion:
                    collection.thumbnail_frame = curr_frame.copy()
                    collection.thumbnail_timeout = -1

                    # Match filename with new thumbnail
                    curr_date = datetime.fromtimestamp(curr_time)
                    video_target_dir = f"{os.getenv("WEBCAM_ALPGR_VIDEO")}/{curr_date.strftime('%Y-%m-%d')}"
                    os.makedirs(video_target_dir, exist_ok=True)
                    image_target_dir = f"{os.getenv("WEBCAM_ALPGR_IMAGE")}/{curr_date.strftime('%Y-%m-%d')}"
                    os.makedirs(image_target_dir, exist_ok=True)
                    thumbnail_target_dir = f"{os.getenv("WEBCAM_ALPGR_THUMBNAIL")}/{curr_date.strftime('%Y-%m-%d')}"
                    os.makedirs(thumbnail_target_dir, exist_ok=True)

                    collection.file_name = curr_date.strftime('%Y-%m-%d_%H-%M-%S')
                    collection.video_target_file = f"{video_target_dir}/{collection.file_name}.mp4"
                    collection.image_target_file = f"{image_target_dir}/{collection.file_name}.jpg"
                    collection.thumbnail_target_file = f"{thumbnail_target_dir}/{collection.file_name}.jpg"
                elif collection.thumbnail_timeout > 0:
                    collection.thumbnail_timeout -= 1

            if collection.recording and curr_motion_level <= 1:
                collection.stop_recording(curr_time)
            elif not collection.recording and curr_motion_level >= 3:
                collection.start_recording(curr_frame, timeout_frames=3, curr_time=curr_time, should_buffer_start=False)

            prev_gray = curr_gray

        queue.task_done()

def run_capture(queue: DataQueue):
    if len(debug_files) > 0:
        import av

        last_time = None
        writer = None

        file_idx = 1
        for file in debug_files:
            while queue.qsize() > 100:
                pass

            print(f"== DEBUG '{file}' [{file_idx}/{len(debug_files)}]")
            file_idx += 1

            try:
                queue.put(file)

                container = av.open(file)
                video_stream = container.streams.video[0]

                file_time = None

                for frame in container.decode(video_stream):
                    if file_time is None:
                        file_time = datetime.strptime(os.path.basename(file), "%Y-%m-%d_%H-%M-%S.mts").timestamp() - frame.time
                    curr_time = file_time + frame.time

                    if last_time is None:
                        last_time = curr_time

                    if curr_time - last_time >= check_interval:
                        last_time = curr_time
                    
                    curr_image = frame.to_ndarray(format="bgr24")
                    cv2.putText(curr_image, "DEBUG REPLAY", (30, 120), cv2.FONT_HERSHEY_SIMPLEX, 1, (0, 0, 255), 2, cv2.LINE_AA)
                    
                    queue.put((curr_image, curr_time))
            except Exception as e:
                print(f"Got bad debug snippet: '{e}'")

        return

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

    text_meta1 = "Alp Grüm RhB Bahnhof"
    text_meta2 = "Hotel Alp Grüm"
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

    header_background: Image = Image.new("LA", (WIDTH, textbox_meta.height + font_size), color=(0,48))
    
    capture = subprocess.Popen([
        "ffmpeg", "-hide_banner", "-loglevel", "error",

        "-headers", "Authorization: Basic dmlld2VyOnRlc3Q=", # viewer:test
        "-user_agent", "RhB Archive (rhb.webcam@gmail.com) If this automated capture is causing issues, please contact me!",
        "-i", webcam_url,
        "-an",

        "-f", "rawvideo",
        "-vcodec", "rawvideo",
        "-pix_fmt", "bgr24",
        "-"
    ], stdout=subprocess.PIPE)

    last_time = None
    last_date = None
    next_snippet_clear = time.time()
    writer = None

    fail_count = 0
    curr_image: cv2.typing.MatLike = None

    try:
        while True:
            ## Capture current
            ready_stdout, _, _ = select.select([capture.stdout], [], [], 10)
            if len(ready_stdout) > 0:
                raw = ready_stdout[0].read(frame_size)

                if len(raw) != frame_size:
                    fail_count += 1

                    if fail_count >= 100:
                        print("Capture failed due to unknown reasons")
                        capture.kill()
                        if writer and output_video:
                            writer.release()
                            writer.process.wait()
                        return

                    continue
                else:
                    fail_count = max(0, fail_count)

                curr_image = np.frombuffer(raw, np.uint8).reshape((HEIGHT, WIDTH, 3))
            else:
                print("Capture timed out due to unknown reasons")
                capture.kill()
                if writer and output_video:
                    writer.release()
                    writer.process.wait()
                return

            ## Setup output writer for current snippet
            now = datetime.now(ZoneInfo("Europe/Zurich"))
            now_time = time.time()

            curr_date = now.strftime('%Y-%m-%d')
            if last_date is None:
                last_date = curr_date

            if writer is None or (now_time - writer.start_time) >= snippet_duration:
                if writer:
                    writer.release()
                    queue.put(writer)

                hourly_now = now.replace(minute=0, second=0, microsecond=0)

                global last_image_write
                if output_video and (last_image_write is None or last_image_write != hourly_now):
                    last_image_write = hourly_now
                    os.makedirs(os.getenv("WEBCAM_ALPGR_SNAPSHOT"), exist_ok=True)
                    cv2.imwrite(f"{os.getenv("WEBCAM_ALPGR_SNAPSHOT")}/{now.strftime('%Y-%m-%d_%H-%M-%S')}.jpg", curr_image)

                target_dir = f"{os.getenv("WEBCAM_ALPGR_SNIPPET")}/{curr_date}"
                if (not os.path.exists(target_dir)):
                    os.makedirs(target_dir, exist_ok=True)

                basefile = f"{target_dir}/{now.strftime('%Y-%m-%d_%H-%M-%S')}" 
                filepath = f"{basefile}.mts"
                dup_idx = 1
                while os.path.exists(filepath):
                    dup_idx += 1
                    filepath = f"{basefile}_{dup_idx}.mts"

                writer = FFmpegVideoWriter(filepath, WIDTH, HEIGHT, time.time())
                
                queue.put(filepath)

            if curr_date != last_date:
                next_snippet_clear = time.time() + snippet_clear_interval

                clear_thread = Thread(target=cleanup_snippets, args=[last_date, 0])
                clear_thread.start()
            elif now_time >= next_snippet_clear:
                next_snippet_clear = time.time() + snippet_clear_interval

                clear_thread = Thread(target=cleanup_snippets, args=[curr_date, snippet_clear_interval])
                clear_thread.start()

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
            pil_image.paste(textbox_time, (WIDTH - textbox_time.width - offset, offset), textbox_time)
            curr_image = np.array(pil_image)
            writer.write(curr_image)

            if last_time is None:
                last_time = now_time
            elif now_time - last_time >= check_interval:
                last_time = now_time
                queue.put((curr_image, now_time))
    except:
        if writer and output_video:
            writer.release()
            writer.process.wait()
        
        raise

def capture_worker(queue: DataQueue):
    if len(debug_files) == 0:
        while True:
            print(f"Attemping capture on {datetime.now()}")
            try:
                run_capture(queue)
            except Exception as e:
                print(f"Unexpected exception: {e}")
                import traceback
                print(traceback.format_exc())
    else:
        run_capture(queue)
        queue.put("TERMINATE")

def cleanup_snippets(day, max_age):
    target_dir = f"{os.getenv("WEBCAM_ALPGR_SNIPPET")}/{day}"

    filelist = f"flush_files_alpgr2.txt"
    files = []

    with open(filelist, "w") as f:
        for file in sorted(os.listdir(target_dir)):
            stat = os.stat(f"{target_dir}/{file}")
            if time.time() - stat.st_mtime > max_age:
                print(f"Removing old snippet {file} ({time.time() - stat.st_mtime}s old)")
                if stat.st_size > 0:
                    f.write(f"file '{target_dir}/{file}'\n")
                files.append(file)

    if len(files) == 0:
        return

    hourly_dir = f"{os.getenv("WEBCAM_ALPGR_HOURLY")}/{day}"
    hourly_file = f"{hourly_dir}/{files[0][:-4]}.mp4"

    os.makedirs(hourly_dir, exist_ok=True)

    hwaccel = os.getenv("HARDWARE_ACCELERATION")
    if hwaccel == "nvidia":
        p = subprocess.Popen([
            "ffmpeg", "-hide_banner",
            "-fflags", "+genpts",
            "-hwaccel", "cuda", "-hwaccel_output_format", "cuda",
            "-f", "concat", "-safe", "0",
            "-i", filelist,
            "-movflags", "+faststart",
            "-vf", "scale_cuda=format=nv12",
            "-c:v", "h264_nvenc",
            "-cq", "40",
            "-preset", "p7",
            "-bf", "4",
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
            "-global_quality", "38",
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

    os.makedirs(f"/media/Storage/RhB_Webcam/AlpGr/Deleted/{day}")
    for file in files:
        os.delete(f"{target_dir}/{file}")


def main():
    load_dotenv()

    global database
    global database_cursor
    database = sqlite3.connect(os.getenv("DATABASE_PROD_PATH"))
    database_cursor = database.cursor()

    queue: DataQueue = Queue(maxsize=0)
    capture_thread = Thread(target=capture_worker, args=[queue])
    capture_thread.daemon = True
    capture_thread.start()

    run_analysis(queue)

if __name__ == "__main__":
    main()
