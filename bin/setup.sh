#!/bin/bash

base_dir=$(cd $(dirname $0);cd ..;pwd)
fess_plugins="
fess-script-groovy:14.18.0
fess-webapp-semantic-search:14.18.0
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
  if [[ ${plugin_version} = *SNAPSHOT ]] ; then
    filename="${plugin_name}-${plugin_version}.jar"
    metadata_file="${base_dir}/maven-metadata.$$"
    metadata_url="https://oss.sonatype.org/content/repositories/snapshots/org/codelibs/fess/${plugin_name}/${plugin_version}/maven-metadata.xml"
    if ! curl -fs -o "${metadata_file}" "${metadata_url}" ; then
      echo "Failed to download from ${metadata_url}."
      exit 1
    fi
    version_timestamp=$(cat ${metadata_file} | grep "<timestamp>" | head -n1 | sed -e "s,.*timestamp>\(.*\)</timestamp.*,\1,")
    version_buildnum=$(cat ${metadata_file} | grep "<buildNumber>" | head -n1 | sed -e "s,.*buildNumber>\(.*\)</buildNumber.*,\1,")
    rm -f ${metadata_file}
    filename=$(echo ${filename} | sed -e "s/SNAPSHOT/${version_timestamp}-${version_buildnum}/")
    plugin_url="https://oss.sonatype.org/content/repositories/snapshots/org/codelibs/fess/${plugin_name}/${plugin_version}/${filename}"

    curl -s -o ${plugin_file} ${plugin_url}
  else
    curl -s -o ${plugin_file} \
      https://repo1.maven.org/maven2/org/codelibs/fess/${plugin_name}/${plugin_version}/${plugin_name}-${plugin_version}.jar
  fi
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
