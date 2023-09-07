#!/bin/bash

base_dir=$(cd $(dirname $0);cd ..;pwd)
fess_plugins="
fess-script-groovy:14.10.0
fess-webapp-semantic-search:14.10.1
"

if [ $(uname -s) = "Linux" ] ; then
  echo "Changing an owner for directories..."
  sudo chown -R $(id -u)  ${base_dir}/data
fi

echo "Creating directories..."
mkdir -p ${base_dir}/data/https-portal/ssl_certs
mkdir -p ${base_dir}/data/fess/opt/fess
mkdir -p ${base_dir}/data/fess/var/lib/fess
mkdir -p ${base_dir}/data/fess/var/log/fess
mkdir -p ${base_dir}/data/fess/usr/share/fess/app/WEB-INF/plugin
mkdir -p ${base_dir}/data/fess/usr/share/fess/app/WEB-INF/view/semantic
mkdir -p ${base_dir}/data/opensearch/usr/share/opensearch/data
mkdir -p ${base_dir}/data/opensearch/usr/share/opensearch/config/dictionary

rm -f ${base_dir}/data/fess/usr/share/fess/app/WEB-INF/plugin/fess-*.jar

for fess_plugin in ${fess_plugins} ; do
  plugin_name=$(echo $fess_plugin | sed -e "s/:.*//")
  plugin_version=$(echo $fess_plugin | sed -e "s/.*://")
  plugin_file=${base_dir}/data/fess/usr/share/fess/app/WEB-INF/plugin/${plugin_name}-${plugin_version}.jar
  echo "Downloading ${plugin_name} version ${plugin_version}..."
  curl -s -o ${plugin_file} \
    https://repo1.maven.org/maven2/org/codelibs/fess/${plugin_name}/${plugin_version}/${plugin_name}-${plugin_version}.jar
done

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
