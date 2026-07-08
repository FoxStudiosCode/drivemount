#!/bin/bash

# installer for webdav auto mount with file linking
# currently only optimized for nextcloud
# other cloud provider might need manaul adjustment
#
# version: 1.0
# author: Niclas Fuchs
# created: 26.06.2026
# updated: 29.06.2026

# TODO:
#   > add user to the davfs2 group - done
#   > create mount point - done
#   > get informaiton from the user (drive domain, username, password, dir mapping,..) -done
#       > write a config file to save the variables for future use -done > ~/.local/share/drive_mount_config.sh
#   > write wrapper script for health check - done > ~/.local/bin/drivemount_wrapper.sh
#   > write service file > done - pending testing
#   > reconfigure systemd for user level - doesn't seem to be necessary
#   > reconfigure davfs2 for user level mounting - done
#

# setting working constants
service_dir="${HOME}/.config/systemd/user"
localbin_dir="${HOME}/.local/bin"
localshare_dir="${HOME}/.local/share"
config_file_name="drive_mount_config.sh"
davfs_dir="${HOME}/.davfs2"
davfs_secret_file="${davfs_dir}/secrets"
run_as_root="false"
username="$(whoami)"
fstab_comment="# automatically added by drivemount install"

declare -A mountinfo
declare -A dirs

# getting sudo cached for later use

if [ ${EUID} -eq 0 ]; then
    printf "Running script as root. Are you sure you want to install on root level?"
    read -e -p "[Y/n]: " rootlevel
    if [ "$rootlevel" == "y" ] || [ "$rootlevel" == "Y" ]; then
		echo "As you wish, m'Lord."
        run_as_root="true"
    else
		exit 0
    fi
fi


while true; do
  sudo -n true
  sleep 60
done 2>/dev/null &

sudo_keepalive_pid=$!

trap "kill $sudo_keepalive_pid 2>/dev/null" exit


# utils
function chk_mk_dir() {
    if [ "$#" -eq 1 ]; then
        if ! [ -d "$1" ]; then
            mkdir -p "$1"
        fi
    fi
}


# pre run preparations
function pre_run() {
    printf "Installing davfs2 via apt...\n"
    #printf "You will be asked if you want to enable user-level mounting."
    #printf "++ Please select \"Yes\"! ++"
    #read "Press Enter to continue." null

    sudo debconf-set-selections <<EOF
davfs2 davfs2/suid_file boolean true
EOF

    if ! sudo apt install -y davfs2 -qq \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        > /dev/null; then
        printf "\nCouldn't install davfs2 via apt. Aborting..\n"
        exit 1
    else
        printf "Done.\n"
    fi

	sudo usermod -aG davfs2 $USER
    # davfs_reconfig
	if ! [ -d "$localbin_dir" ]; then
		mkdir -p "$localbin_dir"
	fi
    if ! [ -d "$localshare_dir" ]; then
        mkdir -p "$localshare_dir"
    fi

}

function davfs_reconfig() {
    printf "Reconfiguring davfs2 to make sure user can mount drives.\n\
        Confirm with \"yes\" if promted.\n"
    echo "davfs2 davfs2/suid_file boolean true" | sudo debconf-set-selections
    sudo DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f davfs2

    # testing alternative method
    #sudo debconfig-set-selections <<EOF
# davfs2 davfs2/non_root_user_confimed boolean true
# EOF
    #sudo DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f noninteractive davfs2
}

function get_user_input() {
	printf "++ Let's get some infos then ++\n"
	read -e -p "Enter the domain of your nextcloud server: " mountinfo["domain"]
	read -e -p "Username for the server: " mountinfo["username"]
	read -e -s -p "Password for the server: " mountinfo["password"]
	printf "\nLet's define your folder mapping.\n" \
		"I will need the name of the Directory on your Cloud and" \
		"the name you want it to map to in your home"
    get_dir_mapping
}

function get_dir_mapping() {
    while true; do
        read -e -p "remote directory: " remotedir
        read -e -p "local directory: " localdir
        dirs["$localdir"]="$remotedir"
        read -e -p "add another? [Y/n]: " another
        if ! [ $(echo $another | tr '[:upper:]' '[:lower:]') == 'y' ];then
            break
        fi
    done
}

function write_config_to_files() {
    # writing secret file
    printf "Writing drive authentication information to secret file...\t"
    chk_mk_dir "$davfs_dir"
    echo "# added automatically by drive mount service installation script" >> $davfs_secret_file
    printf "https://${mountinfo["domain"]}/remote.php/webdav\t${mountinfo["username"]}\t${mountinfo["password"]}\n" >> $davfs_secret_file
    chmod 600 "$davfs_secret_file"
    printf "Done.\n"

    # write mapping
    printf "Writing mapping to config file...\t"
    cat << EOF > "${localshare_dir}/${config_file_name}"
declare -A mountinfo
declare -A dirs

mountinfo["username"]="${mountinfo["username"]}"
mountinfo["domain"]="${mountinfo["domain"]}"

EOF

    for key in ${!dirs[@]};do
        echo "dirs[\"$key\"]=\"${dirs[$key]}\"" >> "${localshare_dir}/${config_file_name}"
    done
    printf "Done.\n"

    printf "Writing mounting config to /etc/fstab...\t"
    sudo tee -a /etc/fstab > /dev/null <<EOF
$fstab_comment
https://${mountinfo['domain']}/remote.php/webdav    ${HOME}/${mountinfo['username']}@${mountinfo['domain']} davfs  user,rw,noauto 0   0
EOF
    printf "Done.\n"

}

function write_service_file() {
    chk_mk_dir "$service_dir"
    printf "Writing Service file to ${service_dir}/ ...\t"
    tee "${service_dir}/${mountinfo['username']}@${mountinfo['domain']}.service" > /dev/null <<EOF
[Unit]
Description=Mounting WebDav Drive and syncing local data
After=network-online.target basic.target
Wants=network-online.target

# Allow 3 failed starts/restarts within 10 minutes.
# After that, systemd stops trying and the unit remains failed.

# old values for limited restart before failure
#StartLimitIntervalSec=10min
#StartLimitBurst=3

StartLimitIntervalSec=0

[Service]
Type=notify
NotifyAccess=all

ExecStart=%h/.local/bin/drivemount_wrapper.sh
ExecStop=%h/.local/bin/drivemount.sh -d

Restart=on-failure
RestartSec=10s

TimeoutStartSec=60s
TimeoutStopSec=60s

[Install]
WantedBy=default.target
EOF
    printf "Done.\n"
}

function copy_executables() {
    printf "Copying main scripts to ${localbin_dir} ...\t"
    if ! cp "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/drivemount.sh" "${localbin_dir}/"; then
        printf "Error copying main script to \"${localbin_dir}\"\n"
        exit 1
    fi
    if ! cp "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/drivemount_wrapper.sh" "${localbin_dir}/"; then
        printf "Error copying wrapper script to \"${localbin_dir}\"\n"
        exit 1
    fi
	chmod +x "$localbin_dir"/drivemount*.sh
    printf "Done.\n"
}

function create_mountpoint() {
    printf "Creating mountpoint at ${HOME}/${mountinfo['username']}@${mountinfo['domain']}\t"
    if ! [ -d "${HOME}/${mountinfo['username']}@${mountinfo['domain']}" ]; then
        mkdir -p "${HOME}/${mountinfo['username']}@${mountinfo['domain']}"
    fi
    printf "Done.\n"
}

function systemd_finisher() {
    systemctl --user daemon-reload
    systemctl --user enable "${mountinfo['username']}@${mountinfo['domain']}.service"
    # systemctl --user start "${mountinfo['username']}@${mountinfo['domain']}.service" > not feasable due to the users session not having the proper group yet
    printf "\nThe Service has been installed and enabled.\nIt will start with the next login.\n"
}


function post_run() {
    create_mountpoint
    copy_executables
    systemd_finisher
    printf "Installer finished successfully.\n"
}

# uninstaller functions
# called with --remove flag

function fstab_cleaner() {
    printf "Removing entry from /etc/fstab...\n"
    sudo awk "
    /^${fstab_comment}$/ {
        getline
        next
    }
    { print }
    " /etc/fstab | sudo tee /etc/fstab.tmp >/dev/null

    sudo mv /etc/fstab.tmp /etc/fstab
}

function shadowdir_warning() {
    printf "\nThe following directories were left intact:\n"
    for localdir in "${!dirs[@]}"; do
        shadowdir="${HOME}/.$(echo $localdir | tr '[:upper:]' '[:lower:]')"
        printf "\t$shadowdir\n"
    done
    printf "Remove them manually if no longer needed.\n"
}

# main uninstall function
function uninstall() {
    printf "Starting removal of DriveMount...\n"

    # declaring variables
    local config_file="${localshare_dir}/${config_file_name}"

    if [ -f "$config_file" ]; then
        . "$config_file"


        service_name="${mountinfo['username']}@${mountinfo['domain']}.service"
        mountpoint="${HOME}/${mountinfo['username']}@${mountinfo['domain']}"


        # removing systemd service
        printf "Stopping service $service_name..."
        if systemctl --user stop "$service_name" 2>/dev/null; then
            printf "\tDone\n"
        else
            printf "Error stopping service. Aborting removal.\n"
            exit 1
        fi

        if ! systemctl --user disable "$service_name" 2>/dev/null; then
            printf "Error disableing service. Aborting removal.\n"
            exit 1
        fi

        printf "Removing Service..."
        if rm -f "${service_dir}/${service_name}"; then
            printf "\tDone.\n"
        else
            printf "\nError removing Service file \"${service_dir}/${service_name}\"\n"
        fi

        #removing mountpoint
        printf "Removing mountpoint..."
        if mountpoint "$mountpoint"; then
            umount "$mountpoint" 2>/dev/null
        fi
        rmdir "$mountpoint" 2>/dev/null
        printf "\tDone.\n"

        # calling fstab cleaner function
        fstab_cleaner

        # removing config file
        printf "Removing local config file..."
        if rm -f "$config_file"; then
            printf "\tDone.\n"
        else
            printf "\nError removing config file \"$config_file\"\n"
        fi

    else
        printf "[WARNING] No local configuration file found at ${config_file}. Performing partial cleanup.\n"
    fi

    printf "Removing scripts..."
    if rm -f "${localbin_dir}/drivemount.sh" "${localbin_dir}/drivemount_wrapper.sh"; then
        printf "\tDone\n"
    else
        printf "\n[ERROR] Error removing scripts from ${localbin_dir}."
    fi

    printf "Reloading systemd..."
    systemctl --user daemon-reload
    printf "\tDone.\n"

    shadowdir_warning

    printf "\nRemoval completed.\n"

}

##
## test functions
##

function sudo_test() {
	printf "++ sudo tests ++\n"
	echo "user: $(whoami)/$USER : ${EUID}"
	echo "sudo: $(sudo whoami)/$USER : $(sudo echo ${EUID})"
}

function print_vars() {
    for key in ${!mountinfo[@]};do
        printf "key: $key\tval: ${mountinfo[$key]}\n"
    done
    for key in ${!dirs[@]};do
        printf "key: $key\tval: ${dirs[$key]}\n"
    done
}

# main funtion to call all the others
function main() {
    pre_run

    get_user_input
    write_config_to_files
    if write_service_file; then
        printf "Created Service: \"${mountinfo['username']}@${mountinfo['domain']}.service\"\n"
    else
        printf "Error writing service file.\n" && exit 1
    fi

    post_run
}

# calling main function
# validating run mode
if [ "$#" -eq 1 ] && [ "$1" = "--remove" ]; then
    uninstall
    exit 0
else
    main
    exit 0
fi

