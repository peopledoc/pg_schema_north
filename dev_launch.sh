#!/bin/bash

if [ -z "$1" ]; then
	echo "** Missing mandatory DATABASE_NAME parameter"
	exit 1
fi

#Check for some mandatory 12 packages
packages="postgresql-12 postgresql-12-pgtap postgresql-client postgresql-client-12 postgresql-plpython3-12 postgresql-server-dev-12"
missing_packages=""
failed=0
for package in $packages ; do
	if [ ! -e /var/lib/dpkg/info/$package.list ] ; then
		echo "** Missing package $package"
		missing_packages="$missing_packages $package"
		failed=1
	fi
done
if [ $failed -ne 0 ]; then
	echo "Install the following packages on your system :$missing_packages"
	exit 1
fi

# Change CWD to current directory
cd "$(dirname ${BASH_SOURCE[0]})"
# run the job
pg_virtualenv -v 12 sh -c "createuser -s postgres; createuser -s dba; createuser -s jenkins ; DATABASE=$1 WORKSPACE=`readlink -f .` RELEASE_FILE=jenkins.txt GIT_COMMIT=HEAD ./jenkins-job.sh"
