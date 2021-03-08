#!/bin/bash -e
set -o pipefail

export PGPORT=${PGPORT}
export PGHOST=${PGHOST}
export db=${DATABASE}
export commit=${GIT_COMMIT}

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

failure=0
error_report=

sql_check="${PWD}/sql_check.py"

fatal_error () {
    echo -e "${RED}**** ERROR REPORT ****\n$1\n**** END OF ERROR REPORT ****${NC}"
    exit 1
}

# List the 'affected files' in this branch
echo "Current commit : $commit"
merge_base_commit=`git merge-base $commit origin/master`
echo "Merge base commit : $merge_base_commit"
files_to_see=`git diff --name-only  $merge_base_commit $commit $db/*/*.sql | grep -v -E "^$db/(archive|perms|pkg|schemas|fixtures|oneshot)/" || echo -n`
echo "The following files must be seen : $files_to_see"

# Check that each file has a test...
for filename in $files_to_see ; do
    if echo "$filename" | grep "dml.sql$" ; then
        echo "** Ignoring test file requirement for $filename"
    else
        required_test=`dirname "$filename"`/tests/`basename "$filename" | sed -e "s/sql$/pg/"`
        if [[ ! -e "$required_test" ]] ; then
            echo "** Missing test file $required_test for $filename"
            error_report="$error_report$filename has no test ($required_test missing) ;\n"
            failure=1
        fi
    fi
done

# Check that each file has a set role...
for filename in $files_to_see ; do
    if echo "$filename" | grep -v "\.sql$" ; then
        echo "** Ignoring set role verification for $filename"
    else
        echo "check that there is a set role in $filename"
        if [[ `grep -Eci '^[[:space:]]*SET ROLE' $filename` -eq 0 ]]; then
                fatal_error "Missing set role in $filename"
        fi
    fi
done

# Check that each DML file is session_replication_role=replica
for filename in $files_to_see ; do
    # If that's not a DML file, skip
    if echo "$filename" | grep -Ev "dml\.sql$"; then
        continue
    fi
    # Does it have a comment telling us that we voluntarily activate triggers ?
    if [[ $(grep -Ec '^[[:space:]]*-- force session_replication_role$' "$filename") -gt 0 ]] ; then
        continue
    fi
    # Is there no line setting session_replication_role either, time to say goodbye
    if [[ $(grep -Ec "^[[:space:]]*SET[[:space:]]+session_replication_role[[:space:]]*='?[[:space:]]*replica" "$filename") -eq 0 ]]; then
        fatal_error "This is a DML. Either have <session_replication_role=replica> or <-- force session_replication_role> in the file $filename"
    fi
    # We have a line setting session_replication_role, check that we also have a SET ROLE postgres somewhere
    if [[ $(grep -Eic "^[[:space:]]*SET[[:space:]]+role[[:space:]]+.*postgres" "$filename") -eq 0 ]]; then
        fatal_error "This is a DML with session_replication_role set: it needs a SET ROLE postgres"
    fi
done

while read line; do
    echo "** $db"

    empty="^[:space:]*$"
    if [[ $line =~ $empty ]] ; then
        fatal_error "jenkins.txt must not contains empty line"
    fi

    schema_part=`echo $line | cut -d ',' -f 2`
    if [[ $schema_part = "followup" ]] ; then
        echo "** $db is following the previous one, no need to drop and create"
    else
        # Wrap createdb in a "critical section" just in case two databases were
        # created at the same time.
        psql -d template1 -c "DROP DATABASE IF EXISTS $db"
        createdb $db
        # Load extensions
        if [[ -f "${WORKSPACE}/$db/schemas/extension.su.sql" ]]; then
            psql -a -d $db --set ON_ERROR_STOP=on -f "${WORKSPACE}/$db/schemas/extension.su.sql"
        elif [[ -f "${WORKSPACE}/$db/schemas/extension.sql" ]]; then
            psql -a -d $db --set ON_ERROR_STOP=on -f "${WORKSPACE}/$db/schemas/extension.sql"
        fi
        if [[ -f "${WORKSPACE}/$db/schemas/extension-deploy.sql" ]]; then
            psql -a -d $db --set ON_ERROR_STOP=on -f "${WORKSPACE}/$db/schemas/extension-deploy.sql"
        fi
        # Create roles
        if [[ -f "${WORKSPACE}/02_roles_tech.su.sql" ]]; then
            psql -a -d $db --set ON_ERROR_STOP=on -f "${WORKSPACE}/02_roles_tech.su.sql"
        fi
        if [[ -f "${WORKSPACE}/$db/schemas/05_roles_$db.sql" ]]; then
            psql -a -d $db --set ON_ERROR_STOP=on -f "${WORKSPACE}/$db/schemas/05_roles_$db.sql"
        fi
        if [[ -f "${WORKSPACE}/$db/schemas/09_manual_$db""_roles.sql" ]]; then
            psql -a -d $db --set ON_ERROR_STOP=on -f "${WORKSPACE}/$db/schemas/09_manual_$db""_roles.sql"
        fi
        if [[ -f "${WORKSPACE}/$db/schemas/roles.sql" ]]; then
            psql -a -d $db --set ON_ERROR_STOP=on -f "${WORKSPACE}/$db/schemas/roles.sql"
        fi
        if [[ -f "${WORKSPACE}/$db/schemas/prerestore.sql" ]]; then
            psql -a -d $db --set ON_ERROR_STOP=on -f "${WORKSPACE}/$db/schemas/prerestore.sql"
        fi

        # Load old schema
        cd "${WORKSPACE}/$db/schemas/";
        last=`echo $line | cut -d ',' -f 2 | cut -d '=' -f 2`
        version_num=$(sed "s/^${db}-schema[_-]\(.*\).sql$/\1/" <<< $last)
        if [[ ! -z "$last" ]]; then
          echo "** Load $last for version $version_num"
          psql -d $db --set ON_ERROR_STOP=on -f $last
          psql -d $db << __________EOF
            DO \$block$
            BEGIN
              PERFORM 1 FROM pg_class WHERE relname = 'sql_version';
              IF FOUND THEN
                INSERT INTO sql_version (version_num, deployment_period)
                  VALUES ('${version_num}', tstzrange(now() - '2 minutes'::interval, now()));
              END IF;
            END;
            \$block$ language plpgsql;
__________EOF

        fi;
        # If there is a schema file for other schemas than public, execute it
        if [[ -f "30_schemas_$db.sql" ]]; then
            psql -a -d $db --set ON_ERROR_STOP=on -f "30_schemas_$db.sql"
        elif [[ -f "schemas.sql" ]]; then
            psql -a -d $db --set ON_ERROR_STOP=on -f "schemas.sql"
        fi
        # If there is a schema-dev file, execute it
        if [[ -f "schemas-dev.sql" ]]; then
            psql -a -d $db --set ON_ERROR_STOP=on -f "schemas-dev.sql"
        fi
        # If there is a default privileges file, execute it
        if [[ -f "40_def_privs_$db.sql" ]]; then
            psql -a -d $db --set ON_ERROR_STOP=on -f "40_def_privs_$db.sql"
        fi
        for manual_file in `ls -1 99_manual_*` ;do
            psql -a -d $db --set ON_ERROR_STOP=on -f $manual_file
        done
        # If there is a owner migration execute it
        if [[ -f "owner-migration-jenkins.sql" ]]; then
            psql -a -d $db --set ON_ERROR_STOP=on -f "owner-migration-jenkins.sql"
        fi
    fi

    # Applying delta
    delta=`echo $line | cut -d ',' -f 3 | cut -d '=' -f 2`
    # delta will be empty if we haven't set a delta (we have just made the dump, and not yet started next version)
    if [[ "$delta" == '' ]]
    then
        continue
    fi
    echo "** Applying delta for version $delta"
    files_to_see=`for file in $files_to_see ; do echo $file ; done | grep -v "$db/$delta/" || echo -n`

    cd "${WORKSPACE}/$db/$delta"

    for sql in `ls -1 *.sql`; do
        echo "** Applying $db/$delta/$sql"
        psql -d $db --set ON_ERROR_STOP=on -f $sql
        python3 "${sql_check}" --uri "postgresql://:@:${PGPORT}/${DATABASE}" "$sql"
    done

    # check the syntax of --meta-psql
    for sql in `ls -1 *.sql`; do
        if [[ $(grep -Eci '^\s+--meta' $sql) != '0' ]]; then
            fatal_error "$sql has a suspicious --meta comment"
        fi
    done

    # unit tests migrations
    if [[ -d "${WORKSPACE}/$db/$delta/tests/" ]]; then
        cd "${WORKSPACE}/$db/$delta/"
        for invalid_name in tests/*.sql ; do
            if [[ -e "${invalid_name}" ]]; then
                fatal_error ".sql file in tests"
            fi
        done
        for test_file in tests/*.pg ; do
            if [[ ! `tac $test_file | grep -m 1 '.'` = "ROLLBACK;" ]] ; then
                fatal_error "$test_file not ending with ROLLBACK"
            fi
            # <1 because there could be several select plan, in case we have different tests on different invironments
            if [[ $(grep -Eci 'select\s+plan\(' $test_file) < '1' ]]; then
                fatal_error "$test_file not having a select plan() call"
            fi
            if [[ $(grep -Eci 'select\s+finish\(\)' $test_file) != '1' ]]; then
                fatal_error "$test_file not having a finish() call"
            fi
        done
        echo "** start pgTap in ${WORKSPACE}/$db/$delta/tests/"
        pg_prove -d $db tests/ --verbose
    fi

    # files post-mep
    if [[ -d "${WORKSPACE}/$db/$delta/post-mep/" ]]; then
        cd "${WORKSPACE}/$db/$delta/post-mep/"
        for sql in `ls -1 *.sql`; do
            echo "** Applying $db/$delta/post-mep/$sql"
            psql -d $db --set ON_ERROR_STOP=on -f $sql
        done
    fi

    # check if the db has a version, and if so check the version it has
    # PSQLRC is set so that a local psqlrc doesn't pollute the result
    db_attached_version=`PSQLRC=/tmp/null psql -d $db -tAb -c "select d.description from pg_namespace n join pg_class c on c.relname='django_site' and c.relnamespace = n.oid join pg_description d on d.objoid = c.oid where n.nspname = 'public';"`
    if [[ ! -z "$db_attached_version" ]]; then
        echo "** Found version $db_attached_version in db"
        usable_version=`echo $db_attached_version | cut -d' ' -f2`
        if [[ $usable_version = $delta ]]; then
            echo "** Version ''$usable_version'' = ''$delta''"
        else
            echo "** Wrong version : $usable_version != $delta"
            error_report="$error_report$usable_version in comment instead of $delta ; \n"
            failure=1
        fi
    fi
done < "${WORKSPACE}/$db/${RELEASE_FILE}"

if [[ ! -z "$files_to_see" ]]; then
    echo "** The following files have not be tested : $files_to_see (check your jenkins file)"
    error_report="$error_report$files_to_see is not tested ;\n"
    failure=1
fi

if [[ $failure -eq 1 ]]; then
    echo "== some checks failed, marking build as broken =="
    fatal_error "$error_report"
fi

cd "${WORKSPACE}"

echo "Testing missing FK indexes on $db"
psql -d "$db" --set ON_ERROR_STOP=on -f missing_fk_indexes.sql

echo "Testing orphan trigger functions on $db"
psql -d "$db" --set ON_ERROR_STOP=on -f orphan_trigger_func.sql

echo -e "${GREEN}** work done.${NC}"
