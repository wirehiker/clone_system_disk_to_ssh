#!/bin/bash
SCRIPT_VERSION="0.2.2"

function main()  {
    
    UNSAFE=false #used to initialize the variable to false.
    KEEP_LOCAL_IMAGE=false
    VERBOSE=false
    LOG=false
    READ_ONLY_SOURCE=false
    
    # Clone a disk or partition to a compressed image and transfer it to a remote host over SSH.
    #
    # Features:
    # - Reads a block device with dd and creates the image in a configurable local directory.
    # - Uses pigz for configurable parallel gzip compression and tests the compressed archive.
    # - Transfers the archive to the remote destination with rsync over SSH.
    # - Verifies the local image and transferred archive with MD5 checksums unless unsafe mode is enabled.
    # - Supports custom image names, optional timestamps, compression levels, verbose output,
    #   optional logging, and retaining the local image with --keep-local-image.
    # - Can generate an Ed25519 SSH key, copy it to the remote host, and create an SSH alias.
    # - Provides --help and --version options for command usage and release information.
    #
    # Usage:
    #   clone_system_disk_to_ssh.sh [OPTIONS] SOURCE_DISK SSH_USER SSH_HOST DESTINATION_DIRECTORY
    #
    # Run as root or with sudo privileges. The source must be a block device, and the local
    # image directory and remote destination directory must already exist.

    parse_arguments "$@" # parse command-line arguments and set variables accordingly
    cache_sudo_pwd
    verify_package coreutils openssh-client pigz rsync gddrescue
    verify_command ddrescue pigz rsync ssh md5sum ssh-keyscan ssh-keygen # verify that the required commands are available on the system. If any command is missing, log the error and exit the script.
    if [[ -z "$SSH_KEY_NAME" ]]; then
        generate_ssh_key  # generate an SSH key pair if it does not already exist. Prompt the user for a custom key name and create the key in ~/.ssh.
    fi
    if [[ "$READ_ONLY_SOURCE" == true ]]; then
        printf '%s\n' "$SUDO_PWD" | sudo -S -p '' blockdev --setro "$SOURCE_DISK" #sets a block device to read-only mode on Linux systems.
        if printf '%s\n' "$SUDO_PWD" | sudo -S -p ''  blockdev --getro "$SOURCE_DISK"; then
         #to confirm if it is read-only (returns 1) or read-write (returns 0)
            verbose_log "$SOURCE_DISK is now read-only. At programm exit, write permissions will be recovered"
            trap unlock_source EXIT
        else
            verbose_log "Failed to set read-only mode on $SOURCE_DISK. Unmount volume an attempt again or run as unsafe without read only mode"
        fi
        sudo -k
    fi
    verify_ssh_connection  # verify ssh connection and access to the remote CONNECTION and the backup directory before proceeding with the backup process. If the connection fails or the directory is not accessible, log the error and exit the script.
    clone_disk_to_image  # create a disk image of the specified source disk using dd. Save it to a local file with a timestamped name in the specified backup directory. Ensure that the output file is created on a disk different from the source disk. Ensure that the dd command is executed with appropriate permissions and error handling.
	echo "UNSAFE : $UNSAFE"    
    if [[ "$UNSAFE" == false ]]; then
        verify_local_md5sum  # verify the integrity of the image file by comparing md5 checksums of the disk of origin and the local image file.
    else
        echo "Warning: Unsafe mode enabled. Skipping md5 checksum verification."
    fi
    compress_image  # compress the image file using pigz with the specified compression level and delete the uncompressed image file after successful compression. Ensure that the pigz command is executed with appropriate permissions and error handling.
    transfer_image_to_remote  # save it to the backup directory on the remote CONNECTION using rs
    verify_remote_md5sum  # verify the integrity of the transferred file by comparing md5 checksums of the local archive file and the remote archive file. If the checksums do not match, log the error and exit the script.
    clean_local_files
    
    exit 1
}

### FUNCTIONS ###

# Parsing command-line arguments
function parse_arguments() {
    
    POSITIONAL_ARGS=() # used in case arguments are space separated and not prefixed with a flag. 
    
    CACHE_LOG="" # used to store log messages for later output before log file is created.
    


    while [[ $# -gt 0 ]]; do
        #During each iteration of the loop, the shift command is used to shift the 
        #positional parameters, effectively removing the first argument ($1). 
        #This reduces the value of $# by 1, and the loop continues until all arguments have been processed
        #when assigned to the fist argument ($1).
        # reference: https://stackoverflow.com/questions/192249/how-do-i-parse-command-line-arguments-in-bash
       
        case "$1" in
            -h|--help)
                echo "Usage: [OPTIONS]... SOURCE_DISK... SSH_USER... SSH_HOST... DESTINATION_DIRECTORY"
                echo "or: [OPTIONS]... -l|--local-image LOCAL_IMAGE_DIRECTORY... SOURCE_DISK... SSH_USER... SSH_HOST... DESTINATION_DIRECTORY"
                echo "Options:"
                echo "  -h, --help     Show this help message and exit"
                echo "  -c, --compression-level  Specify the compression level for pigz (1-9)"
                echo "  -L, --local-image  Specify the local directory to store the image file while processing"
                echo "                     ...default to DESTINATION_DIRECTORY if not set"
                echo "  --image-name  Specify the name of the image file to be created"
                echo "                     ...default to SOURCE_DISK if not set"
                echo "  -t, --timestamp  Specify if a timestamp should be added to the image file name"
                echo "  -V, --verbose  Enable verbose output"
                echo "  --unsafe    skips origin to image safety checks and warnings. Use with caution."
                echo "  -s, --ssh-key   Specify the SSH key name to use for the connection, if specified key generation will be skipped."
                # echo "  -d, --debug    Enable debug output"
                echo "  -l, --log      Enable logging"
                # echo "  -q, --quiet    Enable quiet mode"
                echo "  -v, --version  Show version information and exit"
                echo "  -R, --read-only-source  Makes the source block device read-only for the time of execution"
                exit 0
                ;;
            -c|--compression-level)
                COMPRESSION_LEVEL="$2"
                shift 2 # past argument and value
                ;;
            -K|--keep-local-image)
                KEEP_LOCAL_IMAGE=true
                shift # past argument
                ;;
            -L|--local-image)
                LOCAL_IMAGE_DIRECTORY=$(check_mandatory_argument "$2" "LOCAL_IMAGE_DIRECTORY")
                shift 2 # past argument and value
                ;;
            -t|--timestamp)
                TIMESTAMP=$(date +%Y%m%d_%H%M%S)
                shift # past argument
                ;;
            -V|--verbose)
                VERBOSE=true
                cache_print "Verbose mode enabled"
                shift
                ;;
            -v|--version)
                echo "$(basename "$0") version $SCRIPT_VERSION"
                exit 0
                ;;
            --image-name)
                IMAGE_NAME=$(check_mandatory_argument "$2" "IMAGE_NAME")
                shift 2 # past argument and value
                ;;
            --unsafe)
                UNSAFE=true
                cache_print "Unsafe mode enabled. All safety checks and warnings will be suppressed."
                shift
                ;;
            -s|--ssh-key)
                SSH_KEY_NAME=$(check_mandatory_argument "$2" "SSH_KEY_NAME")
                shift 2 # past argument and value
                ;;
            -l|--log)
                LOG=true
                cache_print "Log mode enabled"
                shift
                ;;
            -R|--read-only-source)
                READ_ONLY_SOURCE=true
                cache_print "read only source enabled"
                shift
                ;;
            # -d|--debug)
            #     DEBUG=true
            #     print_debug "Debug mode enabled"
            #     shift
            #     ;;
            # -q|--quiet)
            #     QUIET=true
            #     shift
            #     ;;
            # --default)
            #     DEFAULT=YES
            #     shift # past argument
            #     ;;
            -*)
                echo "Unknown option $1"
                exit 1
                ;;
            *)
            POSITIONAL_ARGS+=("$1") # save positional arg
            shift # past argument
            ;;
        esac
    done

    set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters
    cache_print "Positional arguments: $@"

    SOURCE_DISK=$(check_mandatory_argument "$1" "SOURCE_DISK")
    SSH_USER=$(check_mandatory_argument "$2" "SSH_USER")
    SSH_HOST=$(check_mandatory_argument "$3" "SSH_HOST")
    CONNECTION_CREDENTIALS="$2@$3"  # combine SSH_USER and SSH_HOST into CONNECTION_CREDENTIALS
    DESTINATION_DIRECTORY=$(check_mandatory_argument "$4" "DESTINATION_DIRECTORY")
    if [[ "$UNSAFE" == true ]]; then
        IMAGE_NAME="${IMAGE_NAME:+${IMAGE_NAME}_}$(basename "$SOURCE_DISK")_${TIMESTAMP:+${TIMESTAMP}_}unsafe.img"  # default to the basename of SOURCE_DISK if not set by user
    else
        IMAGE_NAME="${IMAGE_NAME:+${IMAGE_NAME}_}$(basename "$SOURCE_DISK")_${TIMESTAMP}.img"  # default to the basename of SOURCE_DISK if not set by user
    fi
    COMPRESSION_LEVEL="${COMPRESSION_LEVEL:-6}"  # default to 6 if not set
    LOCAL_IMAGE_DIRECTORY="${LOCAL_IMAGE_DIRECTORY:-$DESTINATION_DIRECTORY}"  # default to DESTINATION_DIRECTORY if not set
    if [[ "$LOG" == true ]]; then
            LOCAL_LOG_FILE=$LOCAL_IMAGE_DIRECTORY/$IMAGE_NAME.log
            touch "$LOCAL_LOG_FILE"  # create the log file if it does not exist
            verbose_log "$CACHE_LOG"  # print cached log messages to the console and append them to the log file
    fi
    
    #TODO list on the screen all the global variables.
    verbose_log "$(basename "$0") version $SCRIPT_VERSION"
    verbose_log "SOURCE_DISK: $SOURCE_DISK"
    verbose_log "CONNECTION_CREDENTIALS: $CONNECTION_CREDENTIALS"
    verbose_log "DESTINATION_DIRECTORY: $DESTINATION_DIRECTORY"
    verbose_log "IMAGE_NAME: $IMAGE_NAME"

    verbose_log "COMPRESSION_LEVEL: $COMPRESSION_LEVEL"
    verbose_log "LOCAL_IMAGE_DIRECTORY: $LOCAL_IMAGE_DIRECTORY"
}

function verify_ssh_connection() {

    # Check SSH connection
    if ! ssh -q "$SSH_KEY_NAME" exit; then
        verbose_log "Error: Unable to connect to $SSH_KEY_NAME via SSH."
        exit 1
    fi

    # Check if the destination directory exists on the remote CONNECTION
    if ! ssh "$SSH_KEY_NAME" "[ -d '$DESTINATION_DIRECTORY' ]"; then
        verbose_log "Error: Destination directory '$DESTINATION_DIRECTORY' does not exist on $SSH_KEY_NAME."
        exit 1
    fi

    verbose_log "SSH connection and destination directory verified successfully."
}

function clone_disk_to_image() {
    # Create a disk image of the specified source disk using dd. Save it to a local file with a timestamped name in the specified backup directory. Ensure that the output file is created on a disk different from the source disk. Ensure that the dd command is executed with appropriate permissions and error handling.

    if ! [ -b "$SOURCE_DISK" ]; then
    # Check if the source disk exists and is a block device. If not, log the error and exit the script.
        verbose_log "Error: Source disk '$SOURCE_DISK' does not exist or is not a block device."
        exit 1
    fi

    if [[ ! -d "$LOCAL_IMAGE_DIRECTORY" ]]; then
        verbose_log "Error: Directory '$LOCAL_IMAGE_DIRECTORY' for image output does not exist."
        exit 1
    fi

    # This compares the actual mounted filesystem/device, which is what matters for disk safety.
    # TODO check the physical device of the source disk and the physical device of the output directory to ensure they are not the same. This is a more robust check than just comparing filesystem types.
    # local source_fs=$(df -P "$SOURCE_DISK" | awk 'NR==2 {print $1}')
    # local out_fs=$(df -P "$LOCAL_IMAGE_DIRECTORY" | awk 'NR==2 {print $1}')
    # local source_device=$(lsblk -no PKNAME "$source_fs" 2>/dev/null)
    # local out_device=$(lsblk -no PKNAME "$out_fs" 2>/dev/null)

    # if [[ ]]

    # if [[ "$source_device" == "$out_device" ]]; then
    #     verbose_log "Error: Output directory is on the same device as the source disk."
    #     exit 1
    # fi

    # Create a disk image using dd
    verbose_log "Creating disk image of $SOURCE_DISK..."
    #don't pipe the output to pigz, instead create the image first and then compress it. This allows for better error handling and verification of the image before compression. conv=sync if piped to pigz could cause data loss if the pipe is broken or if pigz stutters. 
    # if ! printf '%s\n' "$SUDO_PWD" | sudo -S -p '' dd if="$SOURCE_DISK" of="${LOCAL_IMAGE_DIRECTORY}/${IMAGE_NAME}" bs=4M status=progress conv=noerror,sync iflag=noatime; then
    #     verbose_log "Error: Failed to create disk image."
    #     exit 1
    # fi
    if ! printf '%s\n' "$SUDO_PWD" | sudo -S -p '' ddrescue -f -n "$SOURCE_DISK" "${LOCAL_IMAGE_DIRECTORY}/${IMAGE_NAME}" "${LOCAL_IMAGE_DIRECTORY}/${IMAGE_NAME}.ddrescue.log"; then
        #FIXME handle the ddrescue log file in a better way, it require dedicated path and it needs to be transfered to the remote location too.
        verbose_log "Error: Failed to create disk image."
        exit 1
    fi
    sudo -k # clear sudo timestamp to require password for next sudo command
    verbose_log "Disk image created successfully: ${LOCAL_IMAGE_DIRECTORY}/${IMAGE_NAME}"
}

function check_mandatory_argument() {
    # Check if an argument is provided for a mandatory option. If not, print an error message and exit the script.
    if [[ -z "$1" ]]; then
        cache_print "Error: $2 is a mandatory argument."
        exit 1
    fi
    
    echo "$1"
}

function verify_local_md5sum() {
    verbose_log "verifying the image file..."
    local sum_source=$(printf '%s\n' "$SUDO_PWD" | sudo -S -p '' md5sum "${SOURCE_DISK}" | cut -d' ' -f1)
    local sum_image=$(md5sum "${LOCAL_IMAGE_DIRECTORY}/${IMAGE_NAME}" | cut -d' ' -f1)
    verbose_log "MD5 checksum of the image file: $sum_image"
    verbose_log "MD5 checksum of the source disk: $sum_source"
    if [[ "$sum_image" != "$sum_source" ]]; then
        verbose_log "Error: MD5 checksum verification failed. The image file may be corrupted."
        exit 1
    fi
    sudo -k
    verbose_log "MD5 checksum verification passed. The image file is valid."
}

function verify_remote_md5sum() {
    verbose_log "verifying the remote file..."
    # Verify the integrity of the transferred file by comparing md5 checksums of the local archive file and the remote archive file. If the checksums do not match, log the error and exit the script.
    local remote_sum=$(ssh "$SSH_KEY_NAME" "md5sum '$DESTINATION_DIRECTORY/${IMAGE_NAME}.gz' | cut -d' ' -f1")
    local local_sum=$(md5sum "${LOCAL_IMAGE_DIRECTORY}/${IMAGE_NAME}.gz" | cut -d' ' -f1)
    verbose_log "MD5 checksum of the remote archive file: ${remote_sum}"
    # MD5 checksum of the remote archive file: 
    verbose_log "MD5 checksum of the local archive file: ${local_sum}"
    # MD5 checksum of the local archive file:
    if [[ "$remote_sum" != "$local_sum" ]]; then
        verbose_log "Error: MD5 checksum verification failed. The transferred archive file may be corrupted."
        exit 1
    else
    verbose_log "MD5 checksum verification passed. The transferred archive file is valid."
    verbose_log "$SOURCE_DISK cloned successfully and archived successfully as ${LOCAL_IMAGE_DIRECTORY}/${IMAGE_NAME}.gz at ${SSH_KEY_NAME} ${CONNECTION_CREDENTIALS}"
    fi

    
}
function compress_image() {
    # Compress the image file using pigz with the specified compression level and delete the uncompressed image file after successful compression. Ensure that the pigz command is executed with appropriate permissions and error handling.
    
    if ! command -v pigz &> /dev/null; then
        verbose_log "Error: pigz is not installed. Please install pigz and try again."
        exit 1
    fi

    local conditional_flags=()
    if [[ "$VERBOSE" == true ]]; then
        conditional_flags+=("-v")
    fi
    if [[ "$KEEP_LOCAL_IMAGE" == true ]]; then
        conditional_flags+=("-k")
    fi

    verbose_log "Compressing the image file with pigz at level $COMPRESSION_LEVEL..."
    verbose_log "Conditional flags for pigz: $conditional_flags"

    verbose_log "Compressing the image file..."
    if ! pigz "-${COMPRESSION_LEVEL}" --rsyncable "${conditional_flags[@]}" "${LOCAL_IMAGE_DIRECTORY}/${IMAGE_NAME}"; then
        verbose_log "Error: Failed to compress the image file."
        exit 1
    else
        verbose_log "Image file compressed successfully: ${LOCAL_IMAGE_DIRECTORY}/${IMAGE_NAME}.gz"
    fi

    verbose_log "testing compressed image file integrity..."
    if ! pigz -t "${LOCAL_IMAGE_DIRECTORY}/${IMAGE_NAME}.gz"; then
        verbose_log "Error: Compressed image file integrity test failed."
        exit 1
    else
        verbose_log "Compressed image file integrity test passed."
    fi

}

function transfer_image_to_remote() {
    # Transfer the compressed image file to the remote CONNECTION using rsync over SSH. Ensure that the rsync command is executed with appropriate permissions and error handling.
    verbose_log "Transferring the compressed image file to the remote $CONNECTION_CREDENTIALS..."
    # reference: https://unix.stackexchange.com/questions/10376/how-to-copy-a-file-to-a-remote-server-using-rsync-over-ssh
    # reference: https://stackoverflow.com/questions/9090817/copying-files-using-rsync-from-remote-server-to-local-machine
    if ! rsync -cavzh -e ssh "${LOCAL_IMAGE_DIRECTORY}/${IMAGE_NAME}.gz" "$SSH_KEY_NAME:$DESTINATION_DIRECTORY"; then
        verbose_log "Error: Failed to transfer the image file to the remote $CONNECTION_CREDENTIALS."
        exit 1
    else
        verbose_log "Image file transferred successfully to $SSH_KEY_NAME:$DESTINATION_DIRECTORY"

    fi

    # Transfer the log file to the remote CONNECTION 
    if [[ "$LOG" == true ]]; then
	verbose_log "transfering the log file to the remote destination..."
        if ! rsync -cavz -e ssh "${LOCAL_IMAGE_DIRECTORY}/${IMAGE_NAME}.log" "$SSH_KEY_NAME:$DESTINATION_DIRECTORY"; then
            verbose_log "Error: Failed to transfer the log file to the remote $CONNECTION_CREDENTIALS."
        else
            verbose_log "Log file transferred successfully to $SSH_KEY_NAME:$DESTINATION_DIRECTORY"
        fi    
    fi

}

function cache_print() {
    # Cache print messages to the console for later output before log file is created.
    while [[ $# -gt 0 ]]; do
        CACHE_LOG+="$1"$'\n'
        shift
    done
}

function print_debug() {
    # Print debug messages to the console if DEBUG is true
    if [[ "$DEBUG" == true ]]; then
        while [[ $# -gt 0 ]]; do
            echo "DEBUG: $1"
            shift
        done
    fi
}

function print_verbose() {
    # Print verbose messages to the console if VERBOSE is true
    if [[ "$VERBOSE" == true ]]; then
        while [[ $# -gt 0 ]]; do
            echo "$1"
            shift
        done
    fi
}

function verbose_log() {
    local messages=("$@")

    # Append log messages to the log file if LOG is true.
    if [[ "$LOG" == true ]]; then
        for message in "${messages[@]}"; do
            echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" >> "$LOCAL_LOG_FILE"
        done
    fi

    # Print verbose messages to the console if VERBOSE is true
    print_verbose "${messages[@]}"
}

function cache_sudo_pwd() {
        while true; do
        read -r -s -p "Enter sudo password: " SUDO_PWD
        printf '\n' >&2

        if printf '%s\n' "$SUDO_PWD" | sudo -S -p '' -v; then
            return 0
        fi

        printf '%s\n' "Incorrect sudo password." >&2
    done
}

function verify_command() {
    echo "verifying commands..."
    # Verify if a command exists. If not, print an error message and exit the script.
    while [[ $# -gt 0 ]]; do
        if ! command -v "$1" &> /dev/null; then
            cache_print "Error: $1 is not installed. Please install it manually and try again."
            exit 1
        fi
        shift
    done

    cache_print "all commands verified"
}

function verify_package() {
    echo "verifying dependencies..."
    while [[ $# -gt 0 ]]; do
        if ! dpkg -s "$1" &> /dev/null; then
            cache_print "Warning: $1 is not installed. Attempting to install via apt..."
            echo "Warning: $1 is not installed. Attempting to install via apt..."
            if ! printf '%s\n' "$SUDO_PWD" | sudo -S -p '' apt install "$1"; then
                cache_print "Error: Failed to intall $1. Please install it manually and try again."
                                echo "Error: Failed to intall $1. Please install it manually and try again."

                sudo -k
                exit 1
            fi
        fi
        shift
    done
    sudo -k
    cache_print "all dependencies verified"
}

function generate_ssh_key() {
    # Generate an SSH key pair if it does not already exist.
    # Prompt the user for a custom key name and create the key in ~/.ssh.

    local ssh_key_name=""
    local ssh_key_path=""
    local ssh_config_file="$HOME/.ssh/config"

    if [[ ! -d "$HOME/.ssh" ]]; then
        mkdir -p "$HOME/.ssh"
    fi

    read -rp "Enter a name for the SSH key file (default: id_rsa): " ssh_key_name
    ssh_key_name="${ssh_key_name:-id_rsa}"
    ssh_key_path="$HOME/.ssh/$ssh_key_name"

    # if the key already exists skeep the generating of a new key
    if [[ -f "$ssh_key_path" || -f "${ssh_key_path}.pub" ]]; then
        verbose_log "SSH key already exists at $ssh_key_path."
        SSH_KEY_NAME="$ssh_key_name"
        return 0
    fi
    
    # verbose_log "SSH key not found. Generating a new SSH key pair named '$ssh_key_name' without a passphrase..."
    if ! ssh-keygen -t ed25519 -f "$ssh_key_path" -N "" -C "$CONNECTION_CREDENTIALS"; then
        verbose_log "Error: Failed to generate SSH key pair."
        exit 1
    fi

    if ! ssh-copy-id -i "${ssh_key_path}.pub" "$CONNECTION_CREDENTIALS"; then
        verbose_log "Error: Failed to copy SSH public key to $CONNECTION_CREDENTIALS."
        exit 1
    else
        verbose_log "SSH public key copied to $CONNECTION_CREDENTIALS successfully."
    fi


    if [[ ! -f "$ssh_config_file" ]]; then
        touch "$ssh_config_file"
        chmod 600 "$ssh_config_file"
    fi



    verbose_log "ssh_key_name: $ssh_key_name"
    verbose_log "SSH_HOST: $SSH_HOST"
    verbose_log "SSH_USER: $SSH_USER"

    # if ! grep -q "^Host $ssh_key_name$" "$ssh_config_file"; then
        cat >> "$ssh_config_file" << EOF

Host "$ssh_key_name"
    HostName "$SSH_HOST"
    User "$SSH_USER"
    Port 22
    IdentityFile "$ssh_key_path"
EOF
    #FIXME: The following code is commented out because it may not work as intended in all environments. It attempts to add the SSH host to known_hosts, but this may not be necessary if the user has already connected to the host before. Consider removing or modifying this section based on your specific use case.
    #     verbose_log "SSH config entry added for host alias '$ssh_key_name'."
    # else
    #     verbose_log "SSH config already contains an entry for host alias '$ssh_key_name'."
    # fi

    SSH_KEY_NAME="$ssh_key_name"
    verbose_log "SSH key pair generated successfully at $ssh_key_path."

    # FIXME verification of the SSH connection using the generated key. The following code is commented out because it may not work as intended in all environments. It attempts to add the SSH host to known_hosts, but this may not be necessary if the user has already connected to the host before. Consider removing or modifying this section based on your specific use case.
    # if ! ssh-keyscan $SSH_HOST >> "$HOME/.ssh/known_hosts"; then
    #     verbose_log "Error: Failed to add $SSH_HOST to known_hosts."
    #     exit 1
    # else
    #     verbose_log "$SSH_HOST added to known_hosts."
    #     SSH_KEY_NAME="$ssh_key_name"
    # fi
}

function unlock_source() {
    printf '%s\n' "$SUDO_PWD" | sudo -S -p '' blockdev --setrw "$SOURCE_DISK" #to switch the device back to read-write mode.
    echo "write permissions on $SOURCE_DISK have been restored"
}

function clean_local_files() {
        if rm "${LOCAL_IMAGE_DIRECTORY}/${IMAGE_NAME}.gz"; then
            echo "Local compressed image file deleted successfully: ${LOCAL_IMAGE_DIRECTORY}/${IMAGE_NAME}.gz"
        else
            echo "Error: Failed to delete the local compressed image file: ${LOCAL_IMAGE_DIRECTORY}/${IMAGE_NAME}.gz"
        fi
        
        if rm "${LOCAL_IMAGE_DIRECTORY}/${IMAGE_NAME}.log"; then
            echo "Local log file deleted successfully: ${LOCAL_IMAGE_DIRECTORY}/${IMAGE_NAME}.log"
        else
            echo "Error: Failed to delete the local log file: ${LOCAL_IMAGE_DIRECTORY}/${IMAGE_NAME}.log"
        fi

        if rm "${LOCAL_IMAGE_DIRECTORY}/${IMAGE_NAME}.ddrescue.log"; then
            echo "Local ddrescue log file deleted successfully: ${LOCAL_IMAGE_DIRECTORY}/${IMAGE_NAME}.ddrescue.log"
        else
            echo "Error: Failed to delete the local log file: ${LOCAL_IMAGE_DIRECTORY}/${IMAGE_NAME}.ddrescue.log"
        fi

        if rm "${LOCAL_IMAGE_DIRECTORY}/${IMAGE_NAME}.ddrescue.log.bak"; then
            echo "Local ddrescue log file deleted successfully: ${LOCAL_IMAGE_DIRECTORY}/${IMAGE_NAME}.ddrescue.log.bak"
        else
            echo "Error: Failed to delete the local log file: ${LOCAL_IMAGE_DIRECTORY}/${IMAGE_NAME}.ddrescue.log.bak"
        fi

}

main "$@" #keep at the very end of the script to ensure that the main function is executed when the script is run. 