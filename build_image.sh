#!/bin/bash

function check_utils {

	#
	# https://stackoverflow.com/a/677212
	#

	for util in "${@}"
	do
		command -v ${util} >/dev/null 2>&1 || { echo >&2 "The utility ${util} is not installed."; exit 1; }
	done
}

function configure_tomcat {
	printf "\nCATALINA_OPTS=\"\${CATALINA_OPTS} \${LIFERAY_JVM_OPTS}\"" >> ${1}/liferay/tomcat/bin/setenv.sh
}

function date {
	if [ -z ${1+x} ] || [ -z ${2+x} ]
	then
		if [ "$(uname)" == "Darwin" ]
		then
			echo $(/bin/date)
		elif [ -e /bin/date ]
		then
			echo $(/bin/date)
		else
			echo $(/usr/bin/date)
		fi
	else
		if [ "$(uname)" == "Darwin" ]
		then
			echo $(/bin/date -jf "%a %b %e %H:%M:%S %Z %Y" "${1}" "${2}")
		elif [ -e /bin/date ]
		then
			echo $(/bin/date -d "${1}" "${2}")
		else
			echo $(/usr/bin/date -d "${1}" "${2}")
		fi
	fi
}

function get_tomcat_version {
	if [ -e ${1}/tomcat-* ]
	then
		for temp_file_name in `ls ${1}`
		do
			if [[ ${temp_file_name} == tomcat-* ]]
			then
				local liferay_tomcat_version=${temp_file_name#*-}
			fi
		done
	fi

	if [ -z ${liferay_tomcat_version+x} ]
	then
		echo "Unable to determine Tomcat version."

		exit 1
	fi

	echo ${liferay_tomcat_version}
}

function main {
	check_utils 7z curl docker java unzip

	#
	# Make temporary directory.
	#

	local current_date=$(date)

	local timestamp=$(date "${current_date}" "+%Y%m%d%H%M")

	local temp_dir=temp-${timestamp}

	mkdir -p ${temp_dir}

	cp -r template/* ${temp_dir}

	#
	# Download and prepare release.
	#

	local release_dir=${1%/*}

	release_dir=${release_dir#*com/}
	release_dir=${release_dir#*com/}
	release_dir=${release_dir#*liferay-release-tool/}
	release_dir=${release_dir#*private/ee/}
	release_dir=releases/${release_dir}

	local release_file_name=${1##*/}

	local release_file_url=${1}

	if [[ ${release_file_url} != http://mirrors.*.liferay.com* ]] && [[ ${release_file_url} != http://release* ]]
	then
		release_file_url=http://mirrors.lax.liferay.com/${release_file_url}
	fi

	if [ ! -e ${release_dir}/${release_file_name} ]
	then
		echo ""
		echo "Downloading ${release_file_url}."
		echo ""

		mkdir -p ${release_dir}

		curl -f -o ${release_dir}/${release_file_name} ${release_file_url} || exit 2
	fi

	if [[ ${release_file_name} == *.7z ]]
	then
		7z x -O${temp_dir} ${release_dir}/${release_file_name} || exit 3
	else
		unzip -q ${release_dir}/${release_file_name} -d ${temp_dir}  || exit 3
	fi

	mv ${temp_dir}/liferay-* ${temp_dir}/liferay

	#
	# Configure Tomcat.
	#

	local liferay_tomcat_version=$(get_tomcat_version ${temp_dir}/liferay)

	mv ${temp_dir}/liferay/tomcat-${liferay_tomcat_version} ${temp_dir}/liferay/tomcat

	#ln -s tomcat ${temp_dir}/liferay/tomcat-${liferay_tomcat_version}

	configure_tomcat ${temp_dir}

	#
	# Warm up Tomcat for older versions to speed up starting Tomcat. Populating
	# the Hypersonic files can take over 20 seconds.
	#

	warm_up_tomcat ${temp_dir}

	#
	# Download trial DXP license.
	#

	if [[ ${release_file_name} == *-dxp-* ]]
	then
		if [ -z "${LIFERAY_DOCKER_LICENSE_CMD}" ]
		then
			echo "Please set the environment variable LIFERAY_DOCKER_LICENSE_CMD to generate a trial DXP license."

			exit 1
		else
			mkdir -p ${temp_dir}/liferay/deploy

			license_file_name=license-$(date "${current_date}" "+%Y%m%d").xml

			eval "curl --silent --header \"${LIFERAY_DOCKER_LICENSE_CMD}?licenseLifetime=$(expr 1000 \* 60 \* 60 \* 24 \* 30)&startDate=$(date "${current_date}" "+%Y-%m-%d")&owner=hello%40liferay.com\" > ${temp_dir}/liferay/deploy/${license_file_name}"

			sed -i "s/\\\n//g" ${temp_dir}/liferay/deploy/${license_file_name}
			sed -i "s/\\\t//g" ${temp_dir}/liferay/deploy/${license_file_name}
			sed -i "s/\"<?xml/<?xml/" ${temp_dir}/liferay/deploy/${license_file_name}
			sed -i "s/license>\"/license>/" ${temp_dir}/liferay/deploy/${license_file_name}
			sed -i 's/\\"/\"/g' ${temp_dir}/liferay/deploy/${license_file_name}
			sed -i 's/\\\//\//g' ${temp_dir}/liferay/deploy/${license_file_name}

			if [ ! -e ${temp_dir}/liferay/deploy/${license_file_name} ]
			then
				echo "Trial DXP license does not exist at ${temp_dir}/liferay/deploy/${license_file_name}."

				exit 1
			else
				echo "Trial DXP license exists at ${temp_dir}/liferay/deploy/${license_file_name}."

				#exit 1
			fi
		fi
	fi

	#
	# Build Docker image.
	#

	local docker_image_name
	local label_name

	if [[ ${release_file_name} == *-commerce-* ]]
	then
		docker_image_name="commerce"
		label_name="Liferay Commerce"
	elif [[ ${release_file_name} == *-dxp-* ]] || [[ ${release_file_name} == *-private* ]]
	then
		docker_image_name="dxp"
		label_name="Liferay DXP"
	elif [[ ${release_file_name} == *-portal-* ]]
	then
		docker_image_name="portal"
		label_name="Liferay Portal"
	else
		echo "${release_file_name} is an unsupported release file name."

		exit 1
	fi

	if [[ ${release_file_url%} == */snapshot-* ]]
	then
		docker_image_name=${docker_image_name}-snapshot
	fi

	if [[ ${release_file_url} == http://release* ]]
	then
		docker_image_name=${docker_image_name}-snapshot
	fi

	local release_version=${release_file_url%/*}

	release_version=${release_version##*/}

	if [[ ${release_file_url} == http://release* ]]
	then
		release_version=${release_file_url#*tomcat-}
		release_version=${release_version%.*}
	fi

	local label_version=${release_version}

	if [[ ${release_file_url%} == */snapshot-* ]]
	then
		local release_branch=${release_file_url%/*}

		release_branch=${release_branch%/*}
		release_branch=${release_branch%-private*}
		release_branch=${release_branch##*-}

		local release_hash=$(cat ${temp_dir}/liferay/.githash)

		release_hash=${release_hash:0:7}

		if [[ ${release_branch} == master ]]
		then
			label_version="Master Snapshot on ${label_version} at ${release_hash}"
		else
			label_version="${release_branch} Snapshot on ${label_version} at ${release_hash}"
		fi
	fi

	local docker_image_tags=()

	if [[ ${release_file_url%} == */snapshot-* ]]
	then
		docker_image_tags+=("liferay/${docker_image_name}:${release_branch}-${release_version}-${release_hash}")
		docker_image_tags+=("liferay/${docker_image_name}:${release_branch}-$(date "${current_date}" "+%Y%m%d")")
		docker_image_tags+=("liferay/${docker_image_name}:${release_branch}")
	else
		docker_image_tags+=("liferay/${docker_image_name}:${release_version}-${timestamp}")
		docker_image_tags+=("liferay/${docker_image_name}:${release_version}")
	fi

	local docker_image_tags_args=""

	for docker_image_tag in "${docker_image_tags[@]}"
	do
		docker_image_tags_args="${docker_image_tags_args} --tag ${docker_image_tag}"
	done

	docker build \
		--build-arg LABEL_BUILD_DATE=$(date "${current_date}" "+%Y-%m-%dT%H:%M:%SZ") \
		--build-arg LABEL_NAME="${label_name}" \
		--build-arg LABEL_VCS_REF=$(git rev-parse HEAD) \
		--build-arg LABEL_VERSION="${label_version}" \
		$(echo ${docker_image_tags_args}) \
		${temp_dir}

	#
	# Push Docker image.
	#

	if [ "${2}" == "push" ]
	then
		for docker_image_tag in "${docker_image_tags[@]}"
		do
			docker push ${docker_image_tag}
		done
	fi

	#
	# Clean up temporary directory.
	#

	rm -fr ${temp_dir}
}

function start_tomcat {
	local temp_dir=${1}

	./${temp_dir}/liferay/tomcat/bin/catalina.sh start

	until $(curl --head --fail --output /dev/null --silent http://localhost:8080)
	do
		sleep 3
	done

	./${temp_dir}/liferay/tomcat/bin/catalina.sh stop

	sleep 10

	rm -fr ${temp_dir}/liferay/data/osgi/state
	rm -fr ${temp_dir}/liferay/osgi/state
	rm -fr ${temp_dir}/liferay/tomcat/logs/*
}

function stat {
	if [ "$(uname)" == "Darwin" ]
	then
		echo $(/usr/bin/stat -f "%z" "${1}")
	else
		echo $(/usr/bin/stat --printf="%s" "${1}")
	fi
}

function warm_up_tomcat {
	local temp_dir=${1}

	if [ -d ${temp_dir}/liferay/data/hsql ]
	then
		if [ $(stat ${temp_dir}/liferay/data/hsql/lportal.script) -lt 1024000 ]
		then
			start_tomcat ${temp_dir}
		else
			echo Tomcat is already warmed up.
		fi
	fi

	if [ -d ${temp_dir}/liferay/data/hypersonic ]
	then
		if [ $(stat ${temp_dir}/liferay/data/hypersonic/lportal.script) -lt 1024000 ]
		then
			start_tomcat ${temp_dir}
		else
			echo Tomcat is already warmed up.
		fi
	fi
}

main ${1}