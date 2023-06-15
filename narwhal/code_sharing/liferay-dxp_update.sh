#!/bin/bash

# shellcheck disable=2002,2013

set -o pipefail

source $(dirname "$(readlink /proc/$$/fd/255 2>/dev/null)")/_liferay_common.sh

BASE_DIR="${PWD}"

GITHUB_PROJECT="${GITHUB_PROJECT:-liferay}"
GITHUB_ADDRESS="git@github.com:${GITHUB_PROJECT}"

REPO_PATH_DXP="${BASE_DIR}/liferay-dxp"
REPO_PATH_EE="${BASE_DIR}/liferay-portal-ee"

TAGS_FILE_DXP="/tmp/tags_file_dxp.txt"
TAGS_FILE_EE="/tmp/tags_file_ee.txt"
TAGS_FILE_NEW="/tmp/tags_file_new.txt"

VERSION="${1}"

function check_param {
	if [ -z "${1}" ]
	then
		echo "${2}"
		exit 1
	fi
}

function git_checkout_branch {
	local branch_name="${1}"

	check_param "${branch_name}" "Missing branch name"

	lc_cd "${REPO_PATH_DXP}"

	if (git show-ref --quiet "${branch_name}")
	then
		echo -n "Checking out branch '${branch_name}'..."
		git checkout -f -q "${branch_name}"
		echo "done."
	else
		echo -n "'No ${branch_name}' branch exists, creating..."
		git branch "${branch_name}"
		git checkout -f -q "${branch_name}"
		echo "done."
	fi
}

function checkout_tag {
	local tag_name="${1}"

	git checkout "${1}"
}

function commit_and_tag {
	local tag_name="${1}"

	git add .

	git commit -a -m "${tag_name}" -q

	git tag "${tag_name}"
}

function clone_repository {
	if [ -d "${1}" ]
	then
		return "${LIFERAY_COMMON_EXIT_CODE_SKIPPED}"
	fi

	git clone "${GITHUB_ADDRESS}/${1}"
}

function fetch_repository {
	lc_cd "${BASE_DIR}/${1}"
	
	git fetch --all
}

function git_fsck {
	

	echo "done."
}

function run_git_maintenance {
	while (pgrep -f "git gc" >/dev/null)
	do
		sleep 1
	done

	rm -f .git/gc.log

	git gc --quiet

	if (! git fsck --full >/dev/null 2>&1)
	then
		echo "Running of 'git fsck' has failed."

		exit 1
	fi
}

function git_get_all_tags {
	git tag -l --sort=creatordate --format='%(refname:short)' "${VERSION}*"
}

function git_get_new_tags {
	echo "Getting new tags... "

	lc_cd "${REPO_PATH_EE}"

	git_get_all_tags > "${TAGS_FILE_EE}"

	lc_cd "${REPO_PATH_DXP}"

	git_get_all_tags > "${TAGS_FILE_DXP}"

	local tag_name

	# shellcheck disable=SC2013
	for tag_name in $(cat "${TAGS_FILE_EE}")
	do
		if (! grep -qw "${tag_name}" "${TAGS_FILE_DXP}")
		then
			echo "${tag_name}"
		fi
	done

	echo "done."
}

function init_repo {
	if [ -d "${REPO_PATH_DXP}" ]
	then
		echo "DXP repo already exists: '${REPO_PATH_DXP}'"

		return "${LIFERAY_COMMON_EXIT_CODE_SKIPPED}"
	fi

	git init -q "${REPO_PATH_DXP}"

	lc_cd "${REPO_PATH_DXP}"

	touch README.md

	git add .

	git commit -m "Initial commit"

	git remote add origin "${GITHUB_ADDRESS}/${REPO_NAME_DXP}"
}

function git_pull_and_push_all_tags {
	git_get_new_tags > "${TAGS_FILE_NEW}"

	for version_minor in $(cat "${TAGS_FILE_NEW}" | cut -d "." -f2 | sort -nu)
	do
		local version_patch

		for version_patch in $(cat "${TAGS_FILE_NEW}" | grep "7.${version_minor}." | cut -d "." -f3 | cut -d "-" -f1 | sort -nu)
		do
			local version_semver
			version_semver="7.${version_minor}.${version_patch}"

			git_checkout_branch "${version_semver}"

			local version_full

			for version_full in $(cat "${TAGS_FILE_NEW}" | grep "${version_semver}")
			do
				git_pull_tag "${version_full}"
			done
		done
	done
}

function git_pull_tag {
	local tag_name="${1}"

	lc_cd "${REPO_PATH_EE}"

	lc_time_run checkout_tag "${tag_name}"

	lc_cd "${REPO_PATH_DXP}"

	lc_time_run run_git_maintenance

	lc_time_run run_rsync ${tag_name}

	lc_time_run commit_and_tag "${tag_name}"
}

function git_push_in_batches {
	local batch_size=100
	local branch_name="${2}"
	local remote="${1}"

	check_param "${branch_name}" "Missing branch name"
	check_param "${remote}" "Missing git remote name"

	if git show-ref --quiet --verify "refs/remotes/${remote}/${branch_name}"
	then
		range="${remote}/${branch_name}..HEAD"
	else
		range="HEAD"
	fi

	packages=$(git log --first-parent --format=format:x "${range}" | wc -l)

	echo "Have to push ${packages} packages in range of ${range}"

	for batch_number in $(seq "${packages}" -"${batch_size}" 1)
	do
		batch_commit=$(git log --first-parent --format=format:%H -n1 --reverse --skip "${batch_number}")

		echo "Pushing ${batch_commit}..."

		git push -q "${remote}" "${batch_commit}:refs/heads/${branch_name}"
	done

	git push -q "${remote}" "HEAD:refs/heads/${branch_name}"
}

function git_push_repo {
	lc_cd "${REPO_PATH_DXP}"

	echo -n "Pushing all branches..."

	local branch_list
	branch_list=$(git for-each-ref --format='%(refname:short)' --sort=creatordate refs/heads/ | grep ^7)

	local branch_name

	for branch_name in ${branch_list}
	do
		git_checkout_branch "${branch_name}"

		git_push_in_batches origin "${branch_name}"
	done

	echo "done."

	echo -n "Pushing all tags..."
	git push -q --tags
	echo "done."
}

function run_rsync {
	rsync -ar --delete --exclude '.git' "${REPO_PATH_EE}/" "${REPO_PATH_DXP}/"
}

function main {
	LIFERAY_COMMON_LOG_DIR=logs

	check_param "${VERSION}" "Missing version"

	lc_time_run init_repo liferay-dxp
	
	lc_time_run clone_repository liferay-portal-ee

	lc_time_run fetch_repository liferay-portal-ee

	git_pull_and_push_all_tags

	lc_time_run git_push_repo
}

main "${@}"
