#!/bin/bash

# Set 3 *critical* bash options :
# -e : on the first command failure, exit immediately !
# -u : if we use unbound variables, fail instead of assuming empty strings
# pipefail : when piping, instead of always having the last command result, get the first non-zero result
set -eu -o pipefail

pause_for_each=0
resume_file=
github_issue=
base_folder=$(dirname "$(readlink -f "$0")")

# Change application_name to avoid sending actions in DBA's mails
export PGAPPNAME="psql_dba"

###########################
## Parameters handling ! ##
###########################
TEMP=$(getopt -o 'Pr:p:i:' --long 'pause,resume:,port:,issue:' -n 'deploy-release.sh' -- "$@")

# Check that parameters are right
if [ $? -ne 0 ]; then
    exit 1
fi

# Now we can set our variables
eval set -- "$TEMP"
unset TEMP

while true; do
    case "$1" in
        '-P'|'--pause')
            pause_for_each=1
            shift
            continue
        ;;
        '-r'|'--resume')
            resume_file=$2
            shift 2
            continue
        ;;
        '-p'|'--port')
            export PGPORT=$2
            shift 2
            continue
        ;;
        '-i'|'--issue')
            github_issue=$2
            shift 2
            continue
        ;;
        '--')
            shift
            break
        ;;
        *)
            echo "Internal error, this should not happen"
            exit 1
        ;;
    esac
done

if [ $# -ne 2 ]; then
    echo "Invalid parameters, got $@"
    echo "Usage : $0 [-i GITHUB_ISSUE] [-p PORT] [-r RESUME_FILE.sql] [-P] PROJECT RELEASE"
    echo "  -p or --port: specify PostgreSQL port"
    echo "  -r or --resume: restart with the specified file"
    echo "  -P or --pause: wait for confirmation after each file"
    echo "  -i or --issue: github issue to comment on and close after deployment"
    echo "PROJECT and RELEASE, you understand, right ? otherwise, please don't use me."
    exit 1
fi

##############################
## Parameters handling done ##
##############################

# Now we must read the remaining items
project=$1
release=$2
log_file="$base_folder/$project/$release/deploy.log"
deploy_dir="$base_folder"/"$project"/"$release"
global_dbs_test_dir="$base_folder"/global-db-properties/"$project"/
datadog_url=""
datadog_key=""

# Generate a restore point appended by a timestamp in order to avoid same restore_point when we resume deployment
restore_point=${project}-${release}-$(date +"%d-%m-%Y_%T")

function log() {
    echo "[$(date --iso-8601=seconds)] $@" | tee -a $log_file
}

function send_slack() {
    if [ -v SLACK_NOTIFICATIONS ]; then
      for url in $SLACK_NOTIFICATIONS ; do
          curl -X POST -H 'Content-type: application/json' -s --data "{\"text\":\"$@\"}" $url > /dev/null
      done
    fi
}

# This one is a subshell to not die if it fails... "set" is global and we don't want this
function send_datadog() (
    set +eu +o pipefail

    if [ $# != 3 ]; then
        echo "send_datadog function require 3 arguments:"
        echo "title, text and alert type (error,warning,info,success)"
        return
    fi

    JSON_STRING=$( jq -n \
                  --arg host "$(hostname -f)" \
                  --arg source_type_name "Postgres" \
                  --arg release "release:${release}" \
                  --arg project "project:${project}" \
                  --arg env "env:${ENVIRONMENT_NAME}" \
                  --arg title "$1" \
                  --arg text "$2" \
                  --arg alert_type "$3" \
                  '{host: $host,  title: $title, text: $text, alert_type: $alert_type, source_type_name: "Postgres", tags: ["team:dba","tool:deploy-release",$release,$project,$env]}' )

    if [ "$datadog_url" = "" ]; then
        echo "Datadog integration disabled"
    else
        response=$(curl --silent  -X POST "https://api.${datadog_url}/api/v1/events?api_key=${datadog_key}" -H "Content-Type: application/json" -d "${JSON_STRING}")

        if [ "$(echo "${response}" | jq --raw-output '.status')" != "ok" ]; then
            echo "Error during sending event to datadog:"
            echo "${response}" | jq .
        fi
    fi
)


function apply_sql() {
    sql_file="$@"
    log "Applying SQL file $sql_file"
    # A file with meta psql is run in a loop with simple regexp. this can be improved...
    if grep "^--meta-psql:do-until-0" "$sql_file" > /dev/null ; then
        log "This is a loop file, special execution required"


        while true ; do
            # Create a named pipe that will be displayed real time on the stdout here
            psql_pipe=$(mktemp -u /tmp/tmp.deploy.XXXX.fifo)
            mkfifo "$psql_pipe"
            cat "$psql_pipe" &

            echo "Going to execute ..."
            # Now we can call psql while capturing its output
            # (and keeping newlines, thus the IFS)
            IFS= psql_output=$(psql -d "$project" --set ON_ERROR_STOP=on -f "$sql_file" |& tee -a "$log_file" | tee "$psql_pipe")
            rm "$psql_pipe"

            # And now, we play with this output
            if echo "$psql_output" | grep -E "^(INSERT|UPDATE|DELETE) " | grep -v -E "^(UPDATE|INSERT|DELETE) 0" > /dev/null ; then
                log "* Need to continue"
                if [ $pause_for_each = 1 ]; then
                    echo "Press enter to continue"
                    read line
                fi
                continue
            else
                log "** File $sql_file done"
                break
            fi
        done

    else
        # Regular files are FAR simpler
        log "This is a regular file, no worries"
        psql -d "$project" --set ON_ERROR_STOP=on -f "$sql_file" |& tee -a "$log_file"
        log "** File $sql_file done"
    fi
}

function github_post_comment()
{
    # Parameter is an issue number, and a filename containing the message
    jq -n --arg msg "$( cat $2 )" '{body: $msg}' | curl -s -XPOST -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/repos/peopledoc/sql-ddl-migration/issues/$1/comments  -d @- > /dev/null
}

function github_close_issue()
{
    # Parameter is an issue number
    # We do that only if there is one environment tag
    count_envs=$(curl -s -XGET -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/repos/peopledoc/sql-ddl-migration/issues/$1 | jq ".labels[].name" | grep -c "Env - ")
    if (( $count_envs > 1 )) ; then
        log "There is more than one env tag on this issue, not closing it"
    else
        curl -s -XPOST -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/repos/peopledoc/sql-ddl-migration/issues/$1 -d '{"state": "closed"}' > /dev/null
    fi
}

function github_get_issue_title()
{
    # Parameter is an issue number
    curl -s -XGET -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/repos/peopledoc/sql-ddl-migration/issues/$1 | jq '.title' --raw-output
}

# Check that our configuration file exists
if [ -f "$HOME/.deploy-release.cfg" ]; then
    source ~/.deploy-release.cfg
else
    echo -e "Configuration file ~/.deploy-release.cfg not found, \033[5mslack and github integration will not work\033[0m"
fi

# Check that the given resume_file, if any, exists
if [ "$resume_file" != "" ]; then
    if [ ! -f "$project/$release/$resume_file" ]; then
        echo "The specified resume file '$project/$release/$resume_file' does not exist"
        exit 1
    fi
fi

# Try to connect to postgresql to catch mistakes
psql -d "$project" --set ON_ERROR_STOP=on -c "SELECT 'PostgreSQL connection is working';"

# Show a simple summary of the situation
echo "Before starting, make sure you are on the right environment, and the required notifications have been made"
echo "Currently on env : $ENVIRONMENT_NAME"
echo "Working on host  : $(hostname -f)"
echo "Selected project : $project"
echo "Selected release : $release"
echo "Resume with file : $resume_file"
echo "Restore point    : ${restore_point}"
echo -n "Github issue     : $github_issue"
if [ "$github_issue" = "" ]; then
    echo
else
    echo -n " — "
    github_get_issue_title $github_issue
fi

# If we are not running in screen, this is worth a warning
if [[ (! -v STY) && (! -v TMUX) ]]; then
    echo "GNU/Screen has not been detected. It is recommended, for safety, to run deployments in a screen"
fi

# Ensure we are on master branch
if [[ $(git rev-parse --abbrev-ref HEAD) != "master" ]]; then
    echo "Be careful, you are not under master branch: $(git rev-parse --abbrev-ref HEAD)"
    exit 1
fi

# Ensure we had pulled last changes
git fetch
if [[ $(git rev-list --left-only --count origin/master...@) != "0" ]]; then
    echo "You are $(git rev-list --left-only --count origin/master...@) commits behind master. Do not forget to pull last changes"
    exit 1
fi

# Ask confirmation
if [ $pause_for_each = 1 ]; then
    echo "If all these are right, press enter to continue."
else
    echo "If all these are right, press enter to continue. THIS IS YOUR LAST CALL."
fi
read line

# Notify the world
if [ "$resume_file" = "" ]; then
    send_slack ":information_source: Deployment of SQL $release for $project in $ENVIRONMENT_NAME started by $USER"
else
    send_slack ":information_source: Deployment of SQL $release for $project in $ENVIRONMENT_NAME resumed by $USER"
fi

# Setup a trap for errors to send a notification for failures
error_exit_hook() {
    send_slack ":negative_squared_cross_mark: Deployment of SQL $release for $project in $ENVIRONMENT_NAME interrupted"
}
trap error_exit_hook ERR

# And let the fun begin !
log "We will deploy project $project, release $release"
if [ "$resume_file" != "" ]; then
    log "Resume point specified : $resume_file"
fi

# Create a restore point
psql -d postgres  --set ON_ERROR_STOP=on -c "set role postgres; select pg_create_restore_point('${restore_point}');"
log "Restore point created - ${restore_point}"

# First step, go in target folder
pushd "$deploy_dir" > /dev/null

# Now we can iterate
for sql in *.sql; do
    log "** File $sql"

    # Check with our resume point
    if [ "$resume_file" != "" ]; then
        if [ "$resume_file" == "$sql" ] ; then
            log "This is our resume point, starting back here"
            resume_file=""
        fi
    fi
    # Resume point not reached ? skip.
    if [ "$resume_file" != "" ]; then
        log "Skipping until we reach our resume point"
        continue
    fi

    # Apply ...
    apply_sql "$sql"

    if [ $pause_for_each = 1 ]; then
        echo "Press enter to continue"
        read line;
    fi
done

log "Running pgtap"
if [ "$github_issue" = "" ]; then
    sudo -E -u postgres pg_prove -d "$project" tests/ |& tee -a "$log_file"
    if [ -d "$global_dbs_test_dir" ]; then
        pushd "$global_dbs_test_dir"
        sudo -E -u postgres pg_prove -d "$project" . |& tee -a "$log_file"
        popd
    fi
else
    msg_file=$(mktemp)
    echo "Deployment done by $USER on $ENVIRONMENT_NAME ($(hostname -f))" > $msg_file
    echo "" >> $msg_file
    echo "\`\`\`" >> $msg_file
    sudo -E -u postgres pg_prove -d "$project" tests/ |& tee -a "$log_file" | tee -a "$msg_file"
    echo "\`\`\`" >> $msg_file
    if [ -d "$global_dbs_test_dir" ]; then
        pushd "$global_dbs_test_dir"
        sudo -E -u postgres pg_prove -d "$project" . |& tee -a "$log_file"
        popd
    fi
    github_post_comment $github_issue $msg_file
    github_close_issue $github_issue
fi
log "Deployment complete !"
popd > /dev/null


send_slack ":green_check_teamcity: Deployment of SQL $release for $project in $ENVIRONMENT_NAME is done"

if [ "$ENVIRONMENT_NAME" = "qualif" ]; then
    log "We are on qualif, doing a dump"
    sudo -E -u postgres pg_dump -s -O -x -n public -d "$project" | grep -vE "^CREATE SCHEMA public;" > "$project"-schema_"$release".sql

    log "Dump done in $(readlink -f "$project"-schema_"$release".sql)"
fi

