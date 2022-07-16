#!/bin/bash
# Program: install_cm_license.sh

eval $@

if [ -z "${CM_HOST}" ]
then
  CM_HOST=$(hostname -f)
fi

BASEDIR=$(dirname "$0")
cd ${BASEDIR}

source repo.env
curl -i -X POST -F license=@license/license.txt -u ${CM_USER}:${CM_PASS} -H "Content-Type:multipart/form-data" ${CM_PROTOCOL}://${CM_HOST}:${CM_PORT}/api/${APIV}/cm/license
