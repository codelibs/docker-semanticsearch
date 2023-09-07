#!/bin/bash

base_dir=$(cd $(dirname $0);cd ..;pwd)
user_id=$(id -u)
branch=`git branch | grep ^\* | awk '{ print $2 }'`
tmp_file=/tmp/system.properties.$$

if [ $(uname -s) = "Linux" ] ; then
  echo "Changing an owner for directories..."
  sudo chown -R ${user_id} ${base_dir}/data
fi

cp ${base_dir}/data/fess/opt/fess/system.properties ${tmp_file}
git checkout -- ${base_dir}/data/fess/opt/fess
git pull origin ${branch}

cp ${tmp_file} ${base_dir}/data/fess/opt/fess/system.properties

if [ $(uname -s) = "Linux" ] ; then
  echo "Changing an owner for directories..."
  sudo chown -R root ${base_dir}/data/https-portal/ssl_certs
  sudo chown -R 1001 ${base_dir}/data/fess/opt/fess
  sudo chown -R 1001 ${base_dir}/data/fess/var/lib/fess
  sudo chown -R 1001 ${base_dir}/data/fess/var/log/fess
  sudo chown -R 1001 ${base_dir}/data/fess/usr/share/fess/app/WEB-INF/plugin
  sudo chown -R 1001 ${base_dir}/data/fess/usr/share/fess/app/WEB-INF/view/semantic
  sudo chown -R 1000 ${base_dir}/data/opensearch/usr/share/opensearch/data
  sudo chown -R 1000 ${base_dir}/data/opensearch/usr/share/opensearch/config/dictionary
fi

rm ${tmp_file}
