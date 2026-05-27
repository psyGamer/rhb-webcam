#!/bin/bash

set -xe
source ../.env

FILE_URL=$(curl https://www.rhb.ch/de/bahnfans/lokdienste/ | grep -oP 'https://assets.eu.ctfassets.net/h76myjvzsgnd/lokdienstPdf/[0-9a-f]{32}/[a-zA-Z0-9._]+\.pdf' | head -n 1)
FILE_NAME=$(basename $FILE_URL)

if [ -f $LOCOMOTIVE_ALLOCATIONS_ARCHIVE/$FILE_NAME ]; then
    exit 0
fi

# Download
wget -O $LOCOMOTIVE_ALLOCATIONS_ARCHIVE/$FILE_NAME $FILE_URL
# Parse

source .venv/bin/activate
python3 parse_locomotive_allocations.py $LOCOMOTIVE_ALLOCATIONS_ARCHIVE/$FILE_NAME $LOCOMOTIVE_ALLOCATIONS_STORAGE


