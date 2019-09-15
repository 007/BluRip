#!/bin/bash

set -x

PRESET_FILE="${PRESET_FILE:-preset.json}"
PRESET_NAME="${PRESET_NAME:-preset}"

# tracks need to be at least 16 minutes 40 seconds
MIN_LENGTH="${MIN_LENGTH:-1000}"

bluray() {
  # extract disc info
  makemkvcon --cache=100 --minlength=${MIN_LENGTH} --robot info disc:0 > discinfo.txt
  head -20 discinfo.txt

  # extract text metadata
  DISC_LABEL="$(awk -F\" '/^CINFO:32,0,/{print $2}' < discinfo.txt)"
  DISC_DESCRIPTION="$(awk -F\" '/^CINFO:2,0,/{print $2}' < discinfo.txt)"

  # total number of tracks to rip
  TITLE_COUNT="$(awk -F: '/^TCOUNT:/{print $2}' < discinfo.txt)"

  # file being encoded for step N-1
  LAST_FILE="/inbound/last_file"

  echo "$(date) Started extracting ${TITLE_COUNT} tracks from ${DISC_LABEL} for ${DISC_DESCRIPTION}"
  echo "$(date) Using ${PRESET_NAME} from ${PRESET_FILE} for encoding"

  OUTBOUND_PREFIX="/outbound/${DISC_LABEL}"
  mkdir -p "${OUTBOUND_PREFIX}"
  cp discinfo.txt "${OUTBOUND_PREFIX}"

  # extract raw from disk for track N while re-encoding N-1
  for TITLE in $(seq 0 $((TITLE_COUNT - 1))); do
    MKV_FILE="$(awk -F\" "/^TINFO:${TITLE},27,/{print \$2}" < discinfo.txt)"
    TITLE_DURATION="$(awk -F\" "/^TINFO:${TITLE},9,/{print \$2}" < discinfo.txt)"
    INBOUND_FILE="/inbound/${MKV_FILE}"
    OUTBOUND_FILE="${OUTBOUND_PREFIX}/${MKV_FILE%.mkv}.mp4"

    echo "extracting title ${TITLE} (${TITLE_DURATION}) to ${OUTBOUND_FILE}"
    #makemkvcon --cache=1024 --minlength=${MIN_LENGTH} --decrypt --robot --progress=-same mkv disc:0 ${TITLE} /inbound
    makemkvcon --cache=1024 --minlength=${MIN_LENGTH} --decrypt --progress=-same mkv disc:0 ${TITLE} /inbound

    # wait for last encoding to finish so we can clean up and process next one
    wait
    rm "${LAST_FILE}"
    LAST_FILE=${INBOUND_FILE}
    # run this in the background so we can extract next file while it processes
    HandBrakeCLI --preset-import-file /presets/${PRESET_FILE} --preset ${PRESET_NAME} --input "${INBOUND_FILE}" --optimize --output "${OUTBOUND_FILE}" &
    sleep 60
  done

  # wait for the final encoding to complete
  # should this be FG instead?
  wait
  rm "${LAST_FILE}"
}

dvd() {
  # extract disc info
  makemkvcon --cache=100 --minlength=${MIN_LENGTH} --robot info disc:0 > discinfo.txt
  head -20 discinfo.txt

  # extract text metadata
  DISC_LABEL="$(awk -F, '/^CINFO:32,0,/{print $3}' < discinfo.txt | sed 's/"//g')"
  DISC_DESCRIPTION="$(awk -F, '/^CINFO:2,0,/{print $3}' < discinfo.txt | sed 's/"//g')"

  # total number of tracks to rip
  TITLE_COUNT="$(awk -F: '/^TCOUNT:/{print $2}' < discinfo.txt)"

  echo "$(date) Started extracting ${TITLE_COUNT} tracks from ${DISC_LABEL} for ${DISC_DESCRIPTION}"
  echo "$(date) Using ${PRESET_NAME} from ${PRESET_FILE} for encoding"

  OUTBOUND_PREFIX="/outbound/${DISC_LABEL}"
  mkdir -p "${OUTBOUND_PREFIX}"
  cp discinfo.txt "${OUTBOUND_PREFIX}"

  # extract by title vs by sequence
  for TITLE in $(awk -F, '/MSG:3028/{print $8}'< discinfo.txt | sed 's/"//g'); do
    OUTBOUND_FILE="${OUTBOUND_PREFIX}/title_${TITLE}.mp4"
    HandBrakeCLI --preset-import-file /presets/${PRESET_FILE} --preset ${PRESET_NAME} --input /dev/sr0 --title ${TITLE} --optimize --output "${OUTBOUND_FILE}"
    touch "${OUTBOUND_FILE}"
  done
}

eject -t /dev/sr0

sleep 5
while ! eject -X /dev/sr0 ; do
  sleep 5
done

DISC_TYPE="$(dvd+rw-mediainfo /dev/sr0 | awk '/Mounted Media:/{print $4}')"

echo "Attempting identification for ${DISC_TYPE}"

if [ "${DISC_TYPE}" = "BD-ROM" ]; then
  bluray
elif [ "${DISC_TYPE}" = "DVD-ROM" ] ; then
  dvd
else
  echo "Unknown media type ${DISC_TYPE}"
  echo "This may help?"
  dvd+rw-mediainfo /dev/sr0
fi


sync
chown -R ${UID:-1000}:${GID:-1001} "${OUTBOUND_PREFIX}"/*

echo "$(date) Finished disc "
eject /dev/sr0

