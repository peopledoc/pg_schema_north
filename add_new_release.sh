#!/bin/bash
set -u -e
PROJECT=$1
RELEASE=$2

RELEASE_DIR="${PROJECT}/${RELEASE}"
LAST_RELEASE=$(find "${PROJECT}" -maxdepth 1 -regex "${PROJECT}/\\([0-9]+\\.\\)+[0-9]+" -printf '%P\n' | sort -rV | head -n 1)

mkdir "${RELEASE_DIR}"
mkdir "${RELEASE_DIR}/tests/"
ln -s ../../versioning_objects/version-management-ddl.sql "${RELEASE_DIR}/${RELEASE}-0-version-ddl.sql"
ln -s ../../../versioning_objects/tests/version_management-ddl.pg "${RELEASE_DIR}/tests/${RELEASE}-0-version-ddl.pg"

cat << EOF > "${RELEASE_DIR}/${RELEASE}-1-version-dml.sql"
BEGIN;
-- force session_replication_role
SET ROLE dba;
SELECT begin_deploy_version('${LAST_RELEASE}', '${RELEASE}');
COMMIT;
EOF

cat << EOF > "${RELEASE_DIR}/${RELEASE}-z-version-dml.sql"
BEGIN;
-- force session_replication_role
SET ROLE dba;
COMMENT ON TABLE sql_version IS 'version ${RELEASE}';
SELECT end_deploy_version('${RELEASE}');
COMMIT;
EOF

echo "target=${RELEASE},followup,delta=${RELEASE}" >> "${PROJECT}/jenkins.txt"
