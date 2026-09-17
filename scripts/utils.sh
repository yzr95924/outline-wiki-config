#!/bin/bash
set -e
shopt -s expand_aliases

if [ "$(uname)" == "Darwin" ]; then
    if ! command -v gsed &> /dev/null
    then
        # https://unix.stackexchange.com/a/131940
        echo "sed commands here are tested only with GNU sed"
        echo "Installing gnu-sed"
        brew install gnu-sed
    else
        alias sed=gsed
    fi
fi

if ! command -v docker-compose &> /dev/null
then
    alias docker-compose="docker compose"
fi

function env_add {
    key=$1
    val=$2
    filename=$3
    echo "${key}=${val}" >> $filename
}

function env_replace {
    key=$1
    val=$2
    filename=$3
    # Anchor to line start: an unanchored `KEY=.*` also mangles any line that
    # merely CONTAINS the key (e.g. `DATABASE_URL=` under `URL=`, `CDN_URL=`
    # silently picking up the URL value). Exact-key lines only.
    sed "s|^${key}=.*|${key}=${val}|" -i $filename
}

function env_tmpl_replace {
    key=$1
    val=$2
    filename=$3
    sed -e "s#\${${key}}#${val}#" -i $filename
}

function env_delete {
    key=$1
    filename=$2
    # Anchored, like env_replace — deleting substring matches would also drop
    # unrelated lines that merely contain the key.
    sed "/^${key}=/d" -i $filename
}

function rm_block {
    block=$1
    filename=$2
    sed "/##BEGIN ${block}/,/##END/d" -i $filename
}