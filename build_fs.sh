#!/bin/bash

err_report() {
    echo "Error on line $1"
    exit 1
}

trap 'err_report $LINENO' ERR


PROJ_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
BUILD_DIR=${PROJ_DIR}/build
mkdir -p ${BUILD_DIR}

FSBIN=${BUILD_DIR}/fatfs.bin
DEFAULT_APPS="netconfig home appmanager"

mcopy -V > /dev/null || {
	echo "Install mtools to create FAT filesystem image"
	exit 1
}

# Create empty FAT filesystem
dd if=/dev/zero of=${FSBIN} bs=64k count=32

# Boot sector and first entry for FAT
echo -n -e \\xeb\\xfe\\x90\\x4d\\x53\\x44\\x4f\\x53\
\\x35\\x2e\\x30\\x00\\x10\\x01\\x01\\x00\
\\x01\\x00\\x02\\x00\\x02\\xf8\\x01\\x00\
\\x3f\\x00\\xff\\x00\\x00\\x00\\x00\\x00\
\\x00\\x00\\x00\\x00\\x80\\x00\\x29\\x00\
\\x00\\x21\\x28\\x4e\\x4f\\x20\\x4e\\x41\
\\x4d\\x45\\x20\\x20\\x20\\x20\\x46\\x41\
\\x54\\x20\\x20\\x20\\x20\\x20\\x00\\x00| \
dd of=${FSBIN} conv=notrunc

echo -n -e \\x55\\xaa | \
dd of=${FSBIN} conv=notrunc bs=1 seek=510

echo -n -e \\xf8\\xff\\xff | \
dd of=${FSBIN} conv=notrunc bs=4096 seek=1

# Install platform tools
pushd ${PROJ_DIR}/platform
for file in *; do
	mcopy -i ${FSBIN} ${file} ::
done
popd

pushd ${PROJ_DIR}
mcopy -i ${FSBIN} config ::

mmd -i ${FSBIN} apps

for app in ${DEFAULT_APPS}; do
	mmd -i ${FSBIN} apps/${app}
	mcopy -i ${FSBIN} -vs apps/${app}/[^.]* ::apps/${app}/
done

SIZE=0x$(hexdump ${FSBIN} |tail -3 |head -1 |cut -b -4)
dd if=${FSBIN} of=tmp.bin bs=0x1000 count=$[${SIZE}+1]
mv tmp.bin ${FSBIN}


# Create and push OTA update

TARGET=$1
OTA_DIR=${BUILD_DIR}/ota
mkdir -p ${OTA_DIR}

PLATFORM_VER=$(cat platform/version.txt)
OTA_FN=badge-platform-ota-${PLATFORM_VER}.tar.gz

# https://git-scm.com/docs/git-archive
# need to remove pax_global_header
git archive --format=tgz HEAD^{tree} -o ${OTA_FN} platform
cat << __EOF__ > version.json
{
  "version": ${PLATFORM_VER},
  "ota_url": "https://badge.arcy.me/ota/${OTA_FN}"
}
__EOF__

mv version.json ${OTA_FN} ${OTA_DIR}

popd


# Create apps repository

APPS_DIR=${PROJ_DIR}/apps
APPDROP_DIR=${BUILD_DIR}/apps
mkdir -p ${APPDROP_DIR}

pushd ${APPS_DIR}

LIST_JSON=${APPDROP_DIR}/list.json
for app in *; do
    cp ${app}/app.json ${APPDROP_DIR}/${app}.json
    tar czvf ${APPDROP_DIR}/${app}.tar.gz --exclude=".*" ${app}
done
python ${PROJ_DIR}/create_json.py ${LIST_JSON}

popd

# Upload

if [ ! -z "${TARGET}" ]; then
    ibmcloud cf push ${TARGET}
fi
