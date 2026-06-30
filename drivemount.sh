#!/bin/bash
#
# small script for user level mounting of my nextcloud via davfs2
# prerequisit is a private secret file (600 ~/.davfs2/secrets) with
# the username and password, an entry in fstab with the 'noauto' option(and ) and
# that the user is a member of the davfs2 group
#
# Version: 1.2
# Author: Niclas Fuchs
# created: 22.06.2026
# updated: 29.06.2026
#
# small script for user level mounting of my nextcloud via davfs2
# prerequisit is a private secret file (600 ~/.davfs2/secrets) with
# the username and password, an entry in fstab with the 'noauto' option(and ) and
# that the user is a member of the davfs2 group
#
# script is then used in a user level systemd service
# > /etc/systemd/user/blub.service

# TODO:
# > mute the mounte/umount command > maybe not, could be useful
# > implement syncing from local shadow dir to remote dir on successfull connection > done - pending testing


##
## variable and settings section
##

version="1.2"
localshare_dir="${HOME}/.local/share"
config_file_name="drive_mount_config.sh"

path_to_conffile="${localshare_dir}/${config_file_name}"

if [ -f  "$path_to_conffile" ]; then
    . "$path_to_conffile"
else
    printf "Error. No config file: $path_to_conffile\n"
    exit 1
fi

drivedir="${HOME}/${mountinfo['username']}@${mountinfo['domain']}"
remote_address="https://${mountinfo['domain']}/"
rsync_options_active="au"
rsync_options_dry="auvn" # a = archive; u = skip files with newer version in dst; n = nochanges(dryrun); v = verbose

# create array with the directories I want to link
# local Directory - Drive Directory
# ^! outdated - is now created on installation and stored in local config file


##
## function section
##


function mount_drive() {
    mount "$drivedir"
	# check for errors when mounting
	if [ $? -ne 0 ]; then
		printf "Error mounting filesystem. Abording process"
		exit 1
	fi
}

function dir_check() {
    for localdir in "${!dirs[@]}"; do
        fullpath="${HOME}/${localdir}"
        if [[ -d "$fullpath" ]] && [[ ! -L "$fullpath"  ]]; then
            if [[ -z "$( ls -A "$fullpath" )" ]]; then
                rmdir "$fullpath"
            else
                printf "${fullpath} is a directory and not empty."
                printf "Please check, clear it and rerun the script"
                exit 1
            fi
        fi
    done
}

function create_local_shadow_dirs() {
    for localdir in "${!dirs[@]}"; do
        shadow_dir="${HOME}/.$(echo $localdir | tr '[:upper:]' '[:lower:]')"
        if [ ! -d "$shadow_dir" ]; then
            mkdir "$shadow_dir"
        fi
    done
}

function set_symlinks_to_remote() {
    dir_check

    # loop through keys of array
    for localdir in "${!dirs[@]}"; do
        if [[ -L "${HOME}/${localdir}" ]]; then
            #printf "Directory "${localdir}' already mounted. Skipping.."
            #printf "removing local symlink for '$localdir'"
            rm "${HOME}/$localdir"
        fi
        ln -s "${drivedir}/${dirs[$localdir]}" "${HOME}/$localdir"
    done
}

function set_symlink_to_local() {
    dir_check

    create_local_shadow_dirs
    for localdir in "${!dirs[@]}"; do
        shadowdir="${HOME}/.$(echo $localdir | tr '[:upper:]' '[:lower:]')"
        if [[ -L "${HOME}/${localdir}" ]]; then
            rm "${HOME}/${localdir}"
        fi
        ln -s "$shadowdir" "${HOME}/$localdir"
    done
}

function local_files_exist() {
    # checks if the shadow directories are empty or not.
    # returns 'false' if directories are empty, 'true' if not
    exist="false"
    for localdir in "${!dirs[@]}"; do
        shadowdir="${HOME}/.$(echo $localdir | tr '[:upper:]' '[:lower:]')"
        if [ -d "$shadowdir" ]; then
		if [ ! -z "$( ls -A $shadowdir )" ]; then
        	    exist="true"
	        fi
	fi
    done
    echo $exist
}

function directory_sync() {
    if [ $# -eq 0 ]; then
	rsync_options="$rsync_options_active"
    elif [ $# -eq 1 ]; then
	if [ "$1" == 'dry' ] || [ "$1" == '-dry' ] || [ "$1" == '--dry' ]; then
  	    rsync_options="$rsync_options_dry"
        else
	    rsync_options="$rsync_options_active"
	fi
    else
	rsync_options="$rsync_options_active"
    fi

    if [ "$(local_files_exist)" == "true" ]; then
        #sync (rsync) local here
        if command -v rsync >/dev/null 2>&1; then
            for localdir in "${!dirs[@]}"; do
                shadowdir="${HOME}/.$(echo $localdir | tr '[:upper:]' '[:lower:]')"
		        if [ -d "$shadowdir" ]; then
			        #echo "debug: before rsync command/echo in directory_sync"
			        #echo 'rsync syntax: ' "-${rsync_options}" "$shadowdir/" "${drivedir}/${dirs[$localdir]}/"
			        #printf "running rsync on: ${shadowdir}\n"
	                rsync "-${rsync_options}" "$shadowdir/" "${drivedir}/${dirs[$localdir]}/"
		        fi
            done
        fi
    fi
}

# main functions

function run() {
    if mountpoint -q "$drivedir"
	then
		echo "drive already mounted"
		exit 0
	else
		if ! mount_drive || ! directory_sync; then
            printf "Failed to mount WebDav-Drive\n"
            exit 1
        fi
    fi

    set_symlinks_to_remote
}

function destroy() {
    set_symlink_to_local
    umount "$drivedir"
}

function health_check() {
    if curl -s $remote_address > /dev/null 2>&1; then
        exit 0
    else
        printf "Remote Server '$remote_address' not reachable.\n"
        exit 1
    fi
}

function print_help() {
    cat <<EOF
Usage: $0 [OPTION]

Description:
    Automated mounting and unmounting plus linking of remote webdav drive

Options:
    -r, --run        Mounts drive and sets links to remote dirs
    -d, --destroy    Resets links to local directories and umounts drive.
    -v  --version    Print command version
    -h, --help       Show this help message and exit.
    -s, --sync       Sync local files to network drive

    --health-check   checks connection to network drive (work in progress)
EOF
}


## now that we have the functions all declared and the main functions ready
##
## we can start the main body and check for flags

if [ $# -eq 0 ]; then
    run
    exit 0
elif [ $# -eq 1 ]; then
    case "$1" in
        -r|--run)
            run
            exit 0
            ;;
        -d|--destroy)
            destroy
            exit 0
            ;;
        -v|--version)
            printf "Version: $version\n"
            exit 0
            ;;
        -h|--help)
            print_help
            exit 0
            ;;
        -s|--sync)
            directory_sync
            exit 0
            ;;
    	--dry-sync)
       	    directory_sync dry
	    exit 0
	    ;;
        --health-check)
            health_check
            ;;
        *)
            printf "Invalid option: $1"
            print_help
            exit 1
            ;;
    esac
else
    print_help
    exit 1
fi

