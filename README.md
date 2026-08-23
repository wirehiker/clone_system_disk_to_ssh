# clone_system_disk_to_ssh
    Clone a disk or partition to a compressed image and transfer it to a remote host over SSH.
    
    Features:
    - Reads a block device with dd and creates the image in a configurable local directory.
    - Uses pigz for configurable parallel gzip compression and tests the compressed archive.
    - Transfers the archive to the remote destination with rsync over SSH.
    - Verifies the local image and transferred archive with MD5 checksums unless unsafe mode is enabled.
    - Supports custom image names, optional timestamps, compression levels, verbose output,
      optional logging, and retaining the local image with --keep-local-image.
    - Can generate an Ed25519 SSH key, copy it to the remote host, and create an SSH alias.
    - Provides --help and --version options for command usage and release information.
    
    Usage:
      clone_system_disk_to_ssh.sh [OPTIONS]... SOURCE_DISK... SSH_USER... SSH_HOST... DESTINATION_DIRECTORY
    
    Run as root or with sudo privileges. The source must be a block device, and the local
    image directory and remote destination directory must already exist.
