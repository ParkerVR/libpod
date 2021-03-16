#!/usr/bin/env bats   -*- bats -*-
#
# Tests generated configurations for systemd.
#

load helpers

###############################################################################
# BEGIN one-time envariable setup

# Create a scratch directory; our podman registry will run from here. We
# also use it for other temporary files like authfiles.
if [ -z "${PODMAN_LOGIN_WORKDIR}" ]; then
    export PODMAN_LOGIN_WORKDIR=$(mktemp -d --tmpdir=${BATS_TMPDIR:-${TMPDIR:-/tmp}} podman_bats_login.XXXXXX)
fi

# Randomly-generated username and password
if [ -z "${PODMAN_LOGIN_USER}" ]; then
    export PODMAN_LOGIN_USER="user$(random_string 4)"
    export PODMAN_LOGIN_PASS=$(random_string 15)
fi

# Randomly-assigned port in the 5xxx range
if [ -z "${PODMAN_LOGIN_REGISTRY_PORT}" ]; then
    for port in $(shuf -i 5000-5999);do
        if ! { exec 3<> /dev/tcp/127.0.0.1/$port; } &>/dev/null; then
            export PODMAN_LOGIN_REGISTRY_PORT=$port
            break
        fi
    done
fi

# Override any user-set path to an auth file
unset REGISTRY_AUTH_FILE

# END   one-time envariable setup
###############################################################################

SERVICE_NAME="podman_test_$(random_string)"

SYSTEMCTL="systemctl"
UNIT_DIR="/usr/lib/systemd/system"
if is_rootless; then
    UNIT_DIR="$HOME/.config/systemd/user"
    mkdir -p $UNIT_DIR

    SYSTEMCTL="$SYSTEMCTL --user"
fi
UNIT_FILE="$UNIT_DIR/$SERVICE_NAME.service"

function setup() {
    skip_if_remote "systemd tests are meaningless over remote"

    basic_setup
}

function teardown() {
    run '?' $SYSTEMCTL stop "$SERVICE_NAME"
    rm -f "$UNIT_FILE"
    $SYSTEMCTL daemon-reload
    basic_teardown
}

# COPIED FROM 150-login.bats (TO BE REFACTORED INTO HELPERS)
@test "podman login [start registry]" {
    AUTHDIR=${PODMAN_LOGIN_WORKDIR}/auth
    mkdir -p $AUTHDIR

    # Registry image; copy of docker.io, but on our own registry
    local REGISTRY_IMAGE="$PODMAN_TEST_IMAGE_REGISTRY/$PODMAN_TEST_IMAGE_USER/registry:2.7"

    # Pull registry image, but into a separate container storage
    mkdir -p ${PODMAN_LOGIN_WORKDIR}/root
    mkdir -p ${PODMAN_LOGIN_WORKDIR}/runroot
    PODMAN_LOGIN_ARGS="--root ${PODMAN_LOGIN_WORKDIR}/root --runroot ${PODMAN_LOGIN_WORKDIR}/runroot"
    # Give it three tries, to compensate for flakes
    run_podman ${PODMAN_LOGIN_ARGS} pull $REGISTRY_IMAGE ||
        run_podman ${PODMAN_LOGIN_ARGS} pull $REGISTRY_IMAGE ||
        run_podman ${PODMAN_LOGIN_ARGS} pull $REGISTRY_IMAGE

    # Registry image needs a cert. Self-signed is good enough.
    CERT=$AUTHDIR/domain.crt
    if [ ! -e $CERT ]; then
        openssl req -newkey rsa:4096 -nodes -sha256 \
                -keyout $AUTHDIR/domain.key -x509 -days 2 \
                -out $AUTHDIR/domain.crt \
                -subj "/C=US/ST=Foo/L=Bar/O=Red Hat, Inc./CN=localhost"
    fi

    # Store credentials where container will see them
    if [ ! -e $AUTHDIR/htpasswd ]; then
        htpasswd -Bbn ${PODMAN_LOGIN_USER} ${PODMAN_LOGIN_PASS} \
                 > $AUTHDIR/htpasswd

        # In case $PODMAN_TEST_KEEP_LOGIN_REGISTRY is set, for testing later
        echo "${PODMAN_LOGIN_USER}:${PODMAN_LOGIN_PASS}" \
             > $AUTHDIR/htpasswd-plaintext
    fi

    # Run the registry container.
    run_podman '?' ${PODMAN_LOGIN_ARGS} rm -f registry
    run_podman ${PODMAN_LOGIN_ARGS} run -d \
               -p ${PODMAN_LOGIN_REGISTRY_PORT}:5000 \
               --name registry \
               -v $AUTHDIR:/auth:Z \
               -e "REGISTRY_AUTH=htpasswd" \
               -e "REGISTRY_AUTH_HTPASSWD_REALM=Registry Realm" \
               -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
               -e REGISTRY_HTTP_TLS_CERTIFICATE=/auth/domain.crt \
               -e REGISTRY_HTTP_TLS_KEY=/auth/domain.key \
               $REGISTRY_IMAGE
}

# This test can fail in dev. environment because of SELinux.
# quick fix: chcon -t container_runtime_exec_t ./bin/podman
@test "podman generate - systemd - basic" {
    # podman initializes this if unset, but systemctl doesn't
    if is_rootless; then
        if [ -z "$XDG_RUNTIME_DIR" ]; then
            export XDG_RUNTIME_DIR=/run/user/$(id -u)
        fi
    fi

    cname=$(random_string)

    destname=img-$(random_string 10 | tr A-Z a-z)-img

    # Push image to local repo as destname
    run_podman push --tls-verify=false \
                --creds ${PODMAN_LOGIN_USER}:${PODMAN_LOGIN_PASS} \
                $IMAGE localhost:${PODMAN_LOGIN_REGISTRY_PORT}/$destname

    # Pull the image back as destname
    run_podman pull --tls-verify=false \
                --creds ${PODMAN_LOGIN_USER}:${PODMAN_LOGIN_PASS} \
                localhost:${PODMAN_LOGIN_REGISTRY_PORT}/$destname

    authfile=${PODMAN_LOGIN_WORKDIR}/auth-$(random_string 10).json
    rm -f $authfile

    registry=localhost:${PODMAN_LOGIN_REGISTRY_PORT}

    run_podman login --authfile=$authfile \
        --tls-verify=false \
        --username ${PODMAN_LOGIN_USER} \
        --password ${PODMAN_LOGIN_PASS} \
        $registry

    # See #7407 for --pull=always THIS NEEDS REIMPLEMENTATION
    run_podman create --name $cname --label "io.containers.autoupdate=image" --label "io.containers.autoupdate.authfile=$authfile" localhost:${PODMAN_LOGIN_REGISTRY_PORT}/$destname top

    run_podman generate systemd --new $cname
    echo "$output" > "$UNIT_FILE"

    $SYSTEMCTL daemon-reload

    run_podman rm $cname
    run $SYSTEMCTL start "$SERVICE_NAME"
    if [ $status -ne 0 ]; then
        die "Error starting systemd unit $SERVICE_NAME, output: $output"
    fi

    run $SYSTEMCTL status "$SERVICE_NAME"
    if [ $status -ne 0 ]; then
        die "Non-zero status of systemd unit $SERVICE_NAME, output: $output"
    fi

    # Give container time to start; make sure output looks top-like
    sleep 2
    run_podman logs $cname
    is "$output" ".*Load average:.*" "running container 'top'-like output"

    # Exercise `podman auto-update`.
    # TODO: this will at least run auto-update code but won't perform an update
    #       since the image didn't change.  We need to improve on that and run
    #       an image from a local registry instead.
    

    run_podman auto-update

    # All good. Stop service, clean up.
    run $SYSTEMCTL stop "$SERVICE_NAME"
    if [ $status -ne 0 ]; then
        die "Error stopping systemd unit $SERVICE_NAME, output: $output"
    fi

    rm -f "$UNIT_FILE"
    $SYSTEMCTL daemon-reload
}


# @test "podman autoupdate" {
#     # Preserve image ID for later comparison against push/pulled image
#     run_podman inspect --format '{{.Id}}' $IMAGE
#     iid=$output

#     destname=img-$(random_string 10 | tr A-Z a-z)-img

#     # Push image to local repo as destname
#     run_podman push --tls-verify=false \
#                 --creds ${PODMAN_LOGIN_USER}:${PODMAN_LOGIN_PASS} \
#                 $IMAGE localhost:${PODMAN_LOGIN_REGISTRY_PORT}/$destname

#     # Pull the image back as destname
#     run_podman pull --tls-verify=false \
#                 --creds ${PODMAN_LOGIN_USER}:${PODMAN_LOGIN_PASS} \
#                 localhost:${PODMAN_LOGIN_REGISTRY_PORT}/$destname


#     # Create a conatiner with the pulled image
#     run_podman create --label "io.containers.autoupdate=image" localhost:${PODMAN_LOGIN_REGISTRY_PORT}/$destname
#     cid1=${lines[-1]}

#     # HERE WE SHOULD GENERATE SYSTEMD FILE AND START SERVICE

#     # Run autoupdate and verify no changes to image
#     run_podman auto-update
#     run_podman inspect --format '{{.Id}}' $destname
#     is "$output" "$iid" "Image ID of pulled image == original IID"

#     # Make a modified image
#     run_podman create localhost:${PODMAN_LOGIN_REGISTRY_PORT}/$destname /bin/echo hello >> touche.txt
#     cid2=${lines[-1]}   
#     run_podman start --attach $cid2
    
#     modified=mod-$(random_string 10 | tr A-Z a-z)-mod


#     # Commit change + Push to local repo
#     run_podman commit $cid2 localhost:${PODMAN_LOGIN_REGISTRY_PORT}/$modified
#     run_podman push --tls-verify=false \
#                --creds ${PODMAN_LOGIN_USER}:${PODMAN_LOGIN_PASS}\
#                localhost:${PODMAN_LOGIN_REGISTRY_PORT}/$modified localhost:${PODMAN_LOGIN_REGISTRY_PORT}/$destname

#     run_podman auto-update
#     run_podman inspect --format '{{.Id}}' $destname
#     iid=${lines[-1]}   

#     run_podman inspect --format '{{.Id}}' $modified
#     is "$output" "$iid" "IID Pulled Image == IID Pushed Image"


#     # All good. Stop service, clean up.
#     run $SYSTEMCTL stop "$SERVICE_NAME"
#     if [ $status -ne 0 ]; then
#         die "Error stopping systemd unit $SERVICE_NAME, output: $output"
#     fi

#     rm -f "$UNIT_FILE"
#     $SYSTEMCTL daemon-reload
#     # Cleanup
#     #run_podman rm $cid1
#     #run_podman rm $cid2
#     #run_podman rmi $destname
#     #run_podman rmi $modified

# }

# vim: filetype=sh
