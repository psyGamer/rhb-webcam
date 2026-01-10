#!/bin/bash

set -xe
source ../.env

if [ $# -eq 0 ]; then
    echo "No arguments supplied"
    exit 1
fi

# Remove empty snippets
find $WEBCAM_SNIPPET_CACHE/$1 -size 0 -print -delete

# Collect all snippets of the day
rm -f archive_files.txt
ls $WEBCAM_SNIPPET_CACHE/$1 | while read -r file ; do
    echo "file '$WEBCAM_SNIPPET_CACHE/$1/$file'" >> archive_files.txt
done

# Create mega-video for day
ffmpeg -fflags +genpts -hwaccel vaapi -hwaccel_output_format vaapi \
       -f concat -safe 0 -i archive_files.txt \
       -movflags +faststart -vf 'hwmap=derive_device=qsv,format=qsv' -c:v h264_qsv -global_quality 40 -look_ahead 1 -preset veryfast -scenario videosurveillance $WEBCAM_VIDEO_ARCHIVE/$1/$1.mp4

