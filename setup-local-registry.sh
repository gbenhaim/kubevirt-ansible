#!/bin/bash -e

# docker://REF
# docker-daemon:REF
# local registry retention policy

usage() {
    echo "usage"
}

copy_images() {
    local images=(${1:?})
    local dest_registry=${2:?}
    local ret=0
    local image_name
    local protocol

    for image in "${images[@]}"; do
        echo "copying $image"
        protocol=${image%%:*}

        if [[ "$protocol" == "docker" ]]; then
            image_name="${image##*/}" # docker://fedora:latest
            # or  docker://URL:PORT/fedora:latest
        else
            image_name="${image#*:}" # docker-daemon:fedora:latest
        fi

        skopeo copy \
            --dest-tls-verify=false \
            "$image" \
            "docker://${dest_registry}/${image_name}" \
        || {
            ret=$?
            echo "Failed to copy ${image}, are you sure it exists?"
            break
        }
    done

    return $ret
}

is_local_registry_exist() {
    local name="${1:?}"

    docker inspect "$name" &> /dev/null
}

is_local_registry_running() {
    local name="${1:?}"

    is_local_registry_exist "$name" \
    && [[ $(docker inspect -f '{{.State.Running}}' "$name") == "true" ]]
}

start_local_registry() {
    local name="${1:?}"
    local ip="${2:?}"
    local port="${3:?}"
    local volume="${4:?}"

    # check if the registry already running
    docker run -d \
        -p "${ip}:${port}:5000" \
        --name "$name" \
        -v "${volume}:/var/lib/registry" \
        registry:2
}

stop_local_registry() {
    local name=${1:?}

    docker stop "$name" > /dev/null
    docker rm "$name" > /dev/null
}

ensure_volume_exists() {
    local name=${1:?}

    docker volume inspect "$name" > /dev/null \
    || docker volume create --name "$name"
}

main() {
    local name="local-registry"
    local ip="0.0.0.0"
    local port="5000"
    local volume="$name"
    local containers_file
    local containers=()
    local cleanup=false

    local options && options=$( \
        getopt \
            -o hc: \
            --long help,pkg-file:,cleanup,debug,ip:,port: \
            -n 'setup-local-registry.sh' \
            -- "$@" \
    )

    if [[ "$?" != "0" ]]; then
        echo "Failed to parse command line options"
        exit 1
    fi

    eval set -- "$options"
    while true; do
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            -c|--containers-file)
                containers_file=$(realpath $2)
                shift 2
                ;;
            --cleanup)
                cleanup=true
                shift 1
                ;;
            --ip)
                ip="$2"
                shift 2
                ;;
            --port)
                port="$2"
                shift 2
                ;;
            --debug)
                set -x
                shift 1
                ;;
            --)
                shift
                break
                ;;
            *)
                echo "Unkown option $1"
                usage
                exit 1
        esac
    done

    "$cleanup" && {
        echo "Running cleanup"
        stop_local_registry "$name"
        echo "Success !"
        exit 0
    }

    is_local_registry_exist "$name" && ! is_local_registry_running "$name" && {
        echo "A stale registry was detected, \
            please run $0 --cleanup in order to remove it"
        exit 1
    }

    if is_local_registry_running "$name"; then
        echo "$name already running..."
    else
        echo "Starting registry $name"
        ensure_volume_exists "$volume"
        start_local_registry "$name" "$ip" "$port" "$volume"
        echo "Local registry is listening on ${ip}:${port}"
    fi

    [[ -f "$containers_file" ]] && {
        readarray -t containers < "$containers_file"
    }

    containers+=("$@")
    [[ ${#containers[@]} -eq 0 ]] && {
        echo "Containers list is empty, nothing to to sync..."
        exit 0
    }

    echo -e "Syncing containers:\n${containers[*]}"
    copy_images "${containers[*]}" "${ip}:${port}"

    echo "Success !"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
