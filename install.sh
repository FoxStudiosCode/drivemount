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

# utils
function chk_mk_dir() {
    if [ "$#" -eq 1 ]; then
        mkdir -p "$1"
    fi
}


# pre run preparations
function pre_run() {
    if ! sudo apt install -y davfs2 >/dev/null 2>&1; then
        printf "Couldn't install davfs2 via apt. Aborting..\n"
        exit 1
    fi
	sudo usermod -aG davfs2 $USER
    davfs_reconfig
	if ! [ -d "$localbin_dir" ]; then
		mkdir -p "$localbin_dir"
	fi
    if ! [ -d "$localshare_dir" ]; then
        mkdir -p "$localshare_dir"
    fi

}

function davfs_reconfig() {
    echo "davfs2 davfs2/suid_file boolean true" | sudo debconf-set-selections 
    sudo DEBIAN_FRONTEND=noninteractive dpkg-reconfigure davfs2
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
    chk_mk_dir "$davfs_dir"
    echo "# added automatically by drive mount service installation script" >> $davfs_secret_file
    printf "https://${mountinfo["domain"]}/remote.php/webdav\t${mountinfo["username"]}\t${mountinfo["password"]}\n" >> $davfs_secret_file
    chmod 600 "$davfs_secret_file"

    # write mapping
    cat << EOF > "${localshare_dir}/${config_file_name}"
declare -A mountinfo
declare -A dirs

mountinfo["username"]="${mountinfo["username"]}"
mountinfo["domain"]="${mountinfo["domain"]}"

EOF

    for key in ${!dirs[@]};do
        echo "dirs[\"$key\"]=\"${dirs[$key]}\"" >> "${localshare_dir}/${config_file_name}"
    done

    sudo tee -a /etc/fstab > /dev/null <<EOF
# automatically added my drivemount install
https://${mountinfo['domain']}/remote.php/webdav    ${HOME}/${mountinfo['username']}@${mountinfo['domain']} davfs  user,rw,noauto 0   0
EOF

}

function write_service_file() {
    chk_mk_dir "$service_dir"
    tee "${service_dir}/${mountinfo['username']}@${mountinfo['domain']}.service" > /dev/null <<EOF
[Unit]
Description=Mounting WebDav Drive and syncing local data
After=network-online.target basic.target
Wants=network-online.target

# Allow 3 failed starts/restarts within 10 minutes.
# After that, systemd stops trying and the unit remains failed.
StartLimitIntervalSec=10min
StartLimitBurst=3

[Service]
Type=notify
NotifyAccess=all

ExecStart=%h/.local/bin/drivemount_wrapper.sh
ExecStop=%h/.local/bin/drivemount.sh -d

Restart=on-failure
RestartSec=60s

TimeoutStartSec=60s
TimeoutStopSec=60s

[Install]
WantedBy=default.target
EOF

}

function copy_executables() {
    cp "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/drivemount.sh" "${localbin_dir}/" || \
        printf "Error copying main script to \"${localbin_dir}\"\n" && exit 1
    cp "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/drivemount_wrapper.sh" "${localbin_dir}/" || \
        printf "Error copying wrapper script to \"${localbin_dir}\"\n" && exit 1
	chmod +x "$localbin_dir"/drivemount*.sh
}

function create_mountpoint() {
    if ! [ -d "${HOME}/${mountinfo['username']}@${mountinfo['domain']}" ]; then
        mkdir -p "${HOME}/${mountinfo['username']}@${mountinfo['domain']}"
    fi
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
    printf "Done.\n"
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
    write_service_file && printf "Created Service: \"${mountinfo['username']}@${mountinfo['domain']}.service\"\n" ||\
        printf "Error writing service file." && exit 1

    post_run
}

# calling main function
main
