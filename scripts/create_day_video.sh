#!/bin/bash

set -xe
source ../.env

if [ $# -eq 0 ]; then
    echo "No arguments supplied"
    exit 1
fi

ARCHIVE_FILE_FILISUR=archive_files_filisur.txt
ARCHIVE_FILE_ALPGR=archive_files_alpgr.txt
ARCHIVE_FILE_MIRALAGO=archive_files_miralago.txt
ARCHIVE_FILE_ILANZ=archive_files_ilanz.txt

# Remove empty snippets

mkdir -p ${WEBCAM_FILISUR_SNIPPET:?}/$1 ${WEBCAM_MIRALAGO_SNIPPET:?}/$1 ${WEBCAM_ILANZ_SNIPPET:?}/$1

find ${WEBCAM_FILISUR_SNIPPET:?}/$1 -size 0 -print -delete
find ${WEBCAM_ALPGR_HOURLY:?}/$1 -size 0 -print -delete
find ${WEBCAM_MIRALAGO_SNIPPET:?}/$1 -size 0 -print -delete
find ${WEBCAM_ILANZ_SNIPPET:?}/$1 -size 0 -print -delete

# Collect all snippets of the day
rm -f ${ARCHIVE_FILE_FILISUR:?} ${ARCHIVE_FILE_ALPGR:?} ${ARCHIVE_FILE_MIRALAGO:?} ${ARCHIVE_FILE_ILANZ:?}

ls ${WEBCAM_FILISUR_SNIPPET:?}/$1 | while read -r file ; do
    echo "file '${WEBCAM_FILISUR_SNIPPET:?}/$1/$file'" >> ${ARCHIVE_FILE_FILISUR:?}
done
ls ${WEBCAM_ALPGR_HOURLY:?}/$1 | while read -r file ; do
    echo "file '${WEBCAM_ALPGR_HOURLY:?}/$1/$file'" >> ${ARCHIVE_FILE_ALPGR:?}
done
ls ${WEBCAM_MIRALAGO_SNIPPET:?}/$1 | while read -r file ; do
    echo "file '${WEBCAM_MIRALAGO_SNIPPET:?}/$1/$file'" >> ${ARCHIVE_FILE_MIRALAGO:?}
done
ls ${WEBCAM_ILANZ_SNIPPET:?}/$1 | while read -r file ; do
    echo "file '${WEBCAM_ILANZ_SNIPPET:?}/$1/$file'" >> ${ARCHIVE_FILE_ILANZ:?}
done

# Create mega-video for day
if [ "$HARDWARE_ACCELERATION" == "intel" ]; then
    if [ -f ${ARCHIVE_FILE_MIRALAGO:?} ]; then
        ffmpeg -fflags +genpts -hwaccel qsv -hwaccel_output_format qsv -extra_hw_frames 16 \
            -r 60 -f concat -safe 0 -i ${ARCHIVE_FILE_MIRALAGO:?} \
            -movflags +faststart -vf "vpp_qsv=format=nv12" -c:v h264_qsv ${WEBCAM_MIRALAGO_DAILY:?}/$1.mp4
    fi

    if [ -f ${ARCHIVE_FILE_ILANZ:?} ]; then
        ffmpeg -fflags +genpts -hwaccel qsv -hwaccel_output_format qsv -extra_hw_frames 16 \
            -r 60 -f concat -safe 0 -i ${ARCHIVE_FILE_ILANZ:?} \
            -movflags +faststart -vf "vpp_qsv=format=nv12" -c:v h264_qsv ${WEBCAM_ILANZ_DAILY:?}/$1.mp4
    fi

    if [ -f ${ARCHIVE_FILE_FILISUR:?} ]; then
        ffmpeg -fflags +genpts -hwaccel vaapi -hwaccel_output_format vaapi \
            -f concat -safe 0 -i ${ARCHIVE_FILE_FILISUR:?} \
            -movflags +faststart -vf 'hwmap=derive_device=qsv,format=qsv' -c:v h264_qsv -global_quality 42 -look_ahead 1 -preset veryfast -scenario videosurveillance ${WEBCAM_FILISUR_DAILY:?}/$1.mp4
    fi

    if [ -f ${ARCHIVE_FILE_ALPGR:?} ]; then
        ffmpeg -fflags +genpts -hwaccel vaapi -hwaccel_output_format vaapi \
            -f concat -safe 0 -i ${ARCHIVE_FILE_ALPGR:?} \
            -movflags +faststart -c:v copy ${WEBCAM_ALPGR_DAILY:?}/$1.mp4
    fi
elif [ "$HARDWARE_ACCELERATION" == "nvidia" ]; then
    if [ -f ${ARCHIVE_FILE_MIRALAGO:?} ]; then
        ffmpeg -fflags +genpts -hwaccel cuda -hwaccel_output_format cuda -extra_hw_frames 16 \
            -r 60 -f concat -safe 0 -i ${ARCHIVE_FILE_MIRALAGO:?} \
            -movflags +faststart -vf "scale_cuda=format=nv12" -c:v h264_nvenc ${WEBCAM_MIRALAGO_DAILY:?}/$1.mp4
    fi

    if [ -f ${ARCHIVE_FILE_ILANZ:?} ]; then
        ffmpeg -fflags +genpts -hwaccel cuda -hwaccel_output_format cuda -extra_hw_frames 16 \
            -r 60 -f concat -safe 0 -i ${ARCHIVE_FILE_ILANZ:?} \
            -movflags +faststart -vf "scale_cuda=format=nv12" -c:v h264_nvenc ${WEBCAM_ILANZ_DAILY:?}/$1.mp4
    fi

    if [ -f ${ARCHIVE_FILE_FILISUR:?} ]; then
        ffmpeg -fflags +genpts -hwaccel cuda -hwaccel_output_format cuda \
            -f concat -safe 0 -i ${ARCHIVE_FILE_FILISUR:?} \
            -movflags +faststart -vf 'scale_cuda=format=nv12' -c:v h264_nvenc -cq 30 -preset p1 -tune hq ${WEBCAM_FILISUR_DAILY:?}/$1.mp4
    fi

    if [ -f ${ARCHIVE_FILE_ALPGR:?} ]; then
        ffmpeg -fflags +genpts -hwaccel cuda -hwaccel_output_format cuda \
            -f concat -safe 0 -i ${ARCHIVE_FILE_ALPGR:?} \
            -movflags +faststart -c:v copy ${WEBCAM_ALPGR_DAILY:?}/$1.mp4
    fi
else
    echo "Unsupported hardware acceleration: $HARDWARE_ACCELERATION"
    exit 1
fi

rm -rf ${WEBCAM_FILISUR_SNIPPET:?}/$1
rm -rf ${WEBCAM_ALPGR_HOURLY:?}/$1
rm -rf ${WEBCAM_MIRALAGO_SNIPPET:?}/$1
rm -rf ${WEBCAM_ILANZ_SNIPPET:?}/$1
