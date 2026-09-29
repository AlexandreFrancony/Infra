# Sourced by backup.sh and verify.sh. The local repository on the USB disk is written as root from a
# throwaway container: Nextcloud's files belong to www-data and aren't readable by bloster.
LOCAL_REPO=/mnt/hdd/backups/restic-local
LOCAL_DOCKER_OPTS=()  # extra bind mounts: what to back up

local_restic() {
  docker run --rm --hostname prodesk \
    -v /home/bloster/bin/restic:/usr/local/bin/restic:ro \
    -v /home/bloster/.restic-password:/run/restic-password:ro \
    -v "$LOCAL_REPO":/repo -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD_FILE=/run/restic-password \
    "${LOCAL_DOCKER_OPTS[@]}" alpine restic "$@"
}
