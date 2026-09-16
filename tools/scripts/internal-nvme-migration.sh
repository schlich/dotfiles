set -euo pipefail

readonly INTERNAL_DISK="/dev/disk/by-id/nvme-HFS512GEJ9X108N_5YD6N025713106N3O"
readonly INTERNAL_SERIAL="5YD6N025713106N3O"
readonly OLD_ROOT_PARTUUID="4deb6d01-9325-41ee-90e9-2b4c92fd8192"
readonly OLD_ROOT_SIZE_BYTES="104857600000"
readonly WINDOWS_ESP_PARTUUID="75faa981-45b9-4b4f-983d-3117a0f1e756"
readonly WINDOWS_MSR_PARTUUID="0a12c9f5-db60-406a-a1e4-6ab917684243"
readonly WINDOWS_OS_PARTUUID="30e1ee66-1108-434f-8932-b38ed7b35ddc"
readonly WINDOWS_RECOVERY_PARTUUID="6d5b6144-5be2-4ba5-b5e9-13959071ae17"
readonly ASUS_UTILITY_PARTUUID="f34fbb8d-589a-4cf0-8192-50f3cda0d52a"
readonly ESP_PARTUUID="a0c12edf-d4cc-4092-8d91-4bf52bec0202"
readonly ROOT_PARTUUID="31b09ff2-10ae-4ea3-a267-4cff8bdac130"
readonly ESP_UUID="A0C1-2EDF"
readonly LUKS_UUID="fcad07cd-274e-4cc6-99a5-b285bf647626"
readonly BTRFS_UUID="27a94ece-bfea-4870-ac2e-6723e07db334"
readonly MAPPER_NAME="nixos-root"
readonly EXTERNAL_ROOT_UUID="b1409dcc-54c2-4f90-8712-3c52aff50c20"
readonly BACKUP_FS_UUID="a3536890-f3c5-4bfa-8f9a-3853af88ea18"
readonly BACKUP_PARENT="/run/media/schlich/ul"
readonly BACKUP_DIR="${MIGRATION_BACKUP_DIR:-$BACKUP_PARENT/internal-nvme-migration-2026-08-27}"
readonly LUKS_HEADER_BEFORE_TPM="$BACKUP_DIR/nixos-luks-header-before-tpm.img"
readonly LUKS_HEADER_AFTER_TPM="$BACKUP_DIR/nixos-luks-header-after-tpm.img"
readonly WINDOWS_ISO="${MIGRATION_WINDOWS_ISO:-$BACKUP_PARENT/Win11.iso}"
readonly WINDOWS_ISO_SHA256="768984706b909479417b2368438909440f2967ff05c6a9195ed2667254e465e3"
readonly RECOVERY_USB="/dev/disk/by-id/usb-General_UDisk-0:0"
readonly RECOVERY_USB_SIZE_BYTES="4026531840"
readonly RECOVERY_USB_MODEL="UDisk"
readonly RECOVERY_USB_SERIAL="General_UDisk-0:0"
readonly RECOVERY_USB_OLD_PARTUUID="95a4b066-01"
readonly RECOVERY_USB_OLD_UUID="6E3E-CAAF"
readonly TARGET="${MIGRATION_TARGET:-/mnt}"
readonly REPO="${MIGRATION_REPO:-/home/schlich/dotfiles}"

log() {
  printf '==> %s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  [[ "$EUID" -eq 0 ]] || die "run this subcommand as root"
}

real_disk() {
  readlink -f "$INTERNAL_DISK"
}

part_by_uuid() {
  local uuid="$1"
  local path="/dev/disk/by-partuuid/$uuid"
  [[ -e "$path" ]] || die "missing expected partition $path"
  readlink -f "$path"
}

assert_partition_on_internal_disk() {
  local uuid="$1"
  local partition parent
  partition="$(part_by_uuid "$uuid")"
  parent="$(lsblk -ndo PKNAME "$partition")"
  [[ "/dev/$parent" == "$(real_disk)" ]] ||
    die "partition $uuid is not on the expected internal NVMe"
}

verify_protected_partitions() {
  local uuid
  for uuid in \
    "$WINDOWS_ESP_PARTUUID" \
    "$WINDOWS_MSR_PARTUUID" \
    "$WINDOWS_OS_PARTUUID" \
    "$WINDOWS_RECOVERY_PARTUUID" \
    "$ASUS_UTILITY_PARTUUID"; do
    assert_partition_on_internal_disk "$uuid"
  done
}

verify_windows_boot_entry() {
  local entries entry_count
  entries="$(
    efibootmgr -v |
      grep -Ei '^Boot[[:xdigit:]]{4}\*?[[:space:]]+Windows Boot Manager[[:space:]]+(HD|VenHw)' || true
  )"
  [[ -n "$entries" ]] ||
    die "no named Windows Boot Manager firmware entry"

  entry_count="$(printf '%s\n' "$entries" | wc -l | xargs)"
  [[ "$entry_count" == "1" ]] ||
    die "expected one unambiguous Windows Boot Manager entry, found $entry_count"
  printf '%s\n' "$entries" |
    grep -Fqi "HD(1,GPT,$WINDOWS_ESP_PARTUUID" ||
    die "Windows Boot Manager does not point to the protected internal ESP"
  printf '%s\n' "$entries" |
    grep -Fqi '\EFI\Microsoft\Boot\bootmgfw.efi' ||
    die "Windows Boot Manager does not point to bootmgfw.efi"
}

preflight_storage() {
  require_root

  local disk serial old_partition size_bytes fs_type signatures
  disk="$(real_disk)"
  [[ -b "$disk" ]] || die "internal disk is not a block device: $disk"
  serial="$(lsblk -dn -o SERIAL "$disk" | xargs)"
  [[ "$serial" == "$INTERNAL_SERIAL" ]] ||
    die "internal serial mismatch: expected $INTERNAL_SERIAL, got $serial"

  verify_protected_partitions
  old_partition="$(part_by_uuid "$OLD_ROOT_PARTUUID")"
  assert_partition_on_internal_disk "$OLD_ROOT_PARTUUID"
  size_bytes="$(blockdev --getsize64 "$old_partition")"
  [[ "$size_bytes" == "$OLD_ROOT_SIZE_BYTES" ]] ||
    die "blank p6 size changed: expected $OLD_ROOT_SIZE_BYTES, got $size_bytes"
  findmnt -rn -S "$old_partition" | grep -q . &&
    die "blank p6 is mounted"
  fs_type="$(lsblk -ndo FSTYPE "$old_partition" | xargs)"
  [[ -z "$fs_type" ]] || die "blank p6 now has filesystem type $fs_type"
  signatures="$(wipefs --noheadings --output TYPE "$old_partition" | xargs)"
  [[ -z "$signatures" ]] || die "blank p6 now has signatures: $signatures"
  [[ ! -e "/dev/disk/by-partuuid/$ROOT_PARTUUID" ]] ||
    die "new root partition GUID already exists; use 'status' instead"

  log "preflight passed"
  lsblk -e7 -o NAME,PATH,SIZE,TYPE,FSTYPE,LABEL,PARTLABEL,PARTUUID,UUID,MOUNTPOINTS "$disk"
  sgdisk --info=6 "$disk"
}

preflight() {
  preflight_storage
  verify_windows_boot_entry
  log "unique Windows Boot Manager entry points to the internal Microsoft EFI loader"
}

verify_backup_filesystem() {
  local backup_uuid
  [[ -d "$BACKUP_PARENT" ]] || die "backup filesystem is not mounted at $BACKUP_PARENT"
  backup_uuid="$(findmnt -rn -T "$BACKUP_PARENT" -o UUID | head -n 1)"
  [[ "$backup_uuid" == "$BACKUP_FS_UUID" ]] ||
    die "backup filesystem UUID mismatch: expected $BACKUP_FS_UUID, got ${backup_uuid:-none}"
}

verify_internal_root() {
  local root_uuid
  root_uuid="$(findmnt -rn -T / -o UUID | head -n 1)"
  [[ "$root_uuid" == "$BTRFS_UUID" ]] ||
    die "current root is not the internal Btrfs installation"
}

verify_internal_luks() {
  local root_part
  root_part="$(part_by_uuid "$ROOT_PARTUUID")"
  assert_partition_on_internal_disk "$ROOT_PARTUUID"
  [[ "$(cryptsetup luksUUID "$root_part")" == "$LUKS_UUID" ]] ||
    die "internal LUKS UUID does not match the declared configuration"
}

backup_luks_header() {
  require_root
  verify_internal_root
  verify_backup_filesystem
  verify_internal_luks

  local root_part confirmation checksum_file
  root_part="$(part_by_uuid "$ROOT_PARTUUID")"
  checksum_file="$LUKS_HEADER_BEFORE_TPM.sha256"
  if [[ -f "$LUKS_HEADER_BEFORE_TPM" || -f "$checksum_file" ]]; then
    [[ -f "$LUKS_HEADER_BEFORE_TPM" && -f "$checksum_file" ]] ||
      die "incomplete existing pre-TPM LUKS header backup"
    (cd "$BACKUP_DIR" && sha256sum --check "$(basename "$checksum_file")")
    log "verified existing pre-TPM LUKS header backup; refusing to overwrite it"
    return
  fi

  printf '%s\n' "This reads the internal LUKS2 header and writes a sensitive recovery image to the external archive."
  read -r -p "Type BACKUP-LUKS-HEADER to continue: " confirmation
  [[ "$confirmation" == "BACKUP-LUKS-HEADER" ]] || die "LUKS header backup was not confirmed"

  umask 077
  cryptsetup luksHeaderBackup "$root_part" --header-backup-file "$LUKS_HEADER_BEFORE_TPM"
  chmod 0600 "$LUKS_HEADER_BEFORE_TPM"
  (
    cd "$BACKUP_DIR"
    sha256sum "$(basename "$LUKS_HEADER_BEFORE_TPM")" >"$(basename "$checksum_file")"
    sha256sum --check "$(basename "$checksum_file")"
  )
  sync
  log "verified pre-TPM LUKS header backup: $LUKS_HEADER_BEFORE_TPM"
}

enroll_tpm2() {
  require_root
  verify_internal_root
  verify_backup_filesystem
  verify_internal_luks
  systemd-analyze has-tpm2 >/dev/null || die "no usable TPM2 device was detected"

  local root_part confirmation before_checksum after_checksum
  root_part="$(part_by_uuid "$ROOT_PARTUUID")"
  before_checksum="$LUKS_HEADER_BEFORE_TPM.sha256"
  after_checksum="$LUKS_HEADER_AFTER_TPM.sha256"
  [[ -f "$LUKS_HEADER_BEFORE_TPM" && -f "$before_checksum" ]] ||
    die "verified pre-TPM LUKS header backup is missing"
  (cd "$BACKUP_DIR" && sha256sum --check "$(basename "$before_checksum")")
  cryptsetup luksDump "$root_part" | grep -q 'systemd-tpm2' &&
    die "a TPM2 token is already enrolled; refusing to add another"
  [[ ! -e "$LUKS_HEADER_AFTER_TPM" && ! -e "$after_checksum" ]] ||
    die "post-TPM LUKS header backup already exists"

  printf '%s\n' "This adds a TPM2 keyslot bound to PCR 7."
  printf '%s\n' "Existing passphrase and recovery-key slots will remain intact."
  read -r -p "Type ENROLL-TPM2-PCR7 to continue: " confirmation
  [[ "$confirmation" == "ENROLL-TPM2-PCR7" ]] || die "TPM2 enrollment was not confirmed"

  systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 "$root_part"
  cryptsetup luksDump "$root_part" | grep -q 'systemd-tpm2' ||
    die "TPM2 enrollment did not create the expected LUKS2 token"

  umask 077
  cryptsetup luksHeaderBackup "$root_part" --header-backup-file "$LUKS_HEADER_AFTER_TPM"
  chmod 0600 "$LUKS_HEADER_AFTER_TPM"
  (
    cd "$BACKUP_DIR"
    sha256sum "$(basename "$LUKS_HEADER_AFTER_TPM")" >"$(basename "$after_checksum")"
    sha256sum --check "$(basename "$after_checksum")"
  )
  sync
  log "TPM2 PCR-7 enrollment and post-enrollment header backup verified"
}

backup_windows_boot_partitions() {
  require_root
  preflight_storage
  verify_backup_filesystem

  local confirmation disk
  printf '%s\n' "This creates recovery images before repairing the missing Windows EFI files."
  printf '%s\n' "It reads protected p1, p2, p4, and p5 but does not modify the internal NVMe."
  read -r -p "Type BACKUP-PROTECTED-PARTITIONS to continue: " confirmation
  [[ "$confirmation" == "BACKUP-PROTECTED-PARTITIONS" ]] ||
    die "protected-partition backup was not confirmed"

  disk="$(real_disk)"
  mkdir -p "$BACKUP_DIR"
  sgdisk --backup="$BACKUP_DIR/internal-nvme.gpt" "$disk"
  sgdisk --print "$disk" >"$BACKUP_DIR/partition-table.txt"
  sgdisk --info=6 "$disk" >"$BACKUP_DIR/original-p6.txt"
  lsblk -e7 -o NAME,PATH,SIZE,TYPE,FSTYPE,LABEL,PARTLABEL,PARTUUID,UUID \
    "$disk" >"$BACKUP_DIR/lsblk-before.txt"

  dd if="$(part_by_uuid "$WINDOWS_ESP_PARTUUID")" \
    of="$BACKUP_DIR/windows-esp.img" bs=4M status=progress conv=fsync
  dd if="$(part_by_uuid "$WINDOWS_MSR_PARTUUID")" \
    of="$BACKUP_DIR/windows-msr.img" bs=4M status=progress conv=fsync
  dd if="$(part_by_uuid "$WINDOWS_RECOVERY_PARTUUID")" \
    of="$BACKUP_DIR/windows-recovery.img" bs=4M status=progress conv=fsync
  dd if="$(part_by_uuid "$ASUS_UTILITY_PARTUUID")" \
    of="$BACKUP_DIR/asus-utility.img" bs=4M status=progress conv=fsync

  (
    cd "$BACKUP_DIR"
    sha256sum \
      internal-nvme.gpt \
      windows-esp.img \
      windows-msr.img \
      windows-recovery.img \
      asus-utility.img >SHA256SUMS
    sha256sum --check SHA256SUMS
  )
  sync
  log "verified backups written to $BACKUP_DIR"
}

record_windows_validation() {
  require_root
  preflight
  verify_backup_filesystem
  [[ -f "$BACKUP_DIR/SHA256SUMS" ]] || die "backup checksum manifest is missing"
  (
    cd "$BACKUP_DIR"
    sha256sum --check SHA256SUMS
  )

  local confirmation
  printf '%s\n' "Confirm all of the following are complete:"
  printf '%s\n' "  - Windows booted successfully with the BitLocker recovery key"
  printf '%s\n' "  - the recovery key is stored independently"
  printf '%s\n' "  - chkdsk C: /scan passed"
  printf '%s\n' "  - reagentc /info reports Windows RE enabled"
  read -r -p "Type WINDOWS-VALIDATED to continue: " confirmation
  [[ "$confirmation" == "WINDOWS-VALIDATED" ]] || die "Windows validation was not confirmed"
  printf '%s\n' "Windows booted, BitLocker key secured, chkdsk passed, WinRE enabled." \
    >"$BACKUP_DIR/windows-validation.txt"
  sync
  log "Windows validation recorded"
}

prepare_windows_recovery_usb() {
  require_root
  verify_backup_filesystem

  local usb usb_part size model serial transport removable read_only
  local source_device source_parent actual_sha repair_size confirmation mount_dir
  local -a usb_parts usb_mounts
  [[ -f "$WINDOWS_ISO" ]] || die "Windows ISO is missing: $WINDOWS_ISO"
  [[ -e "$RECOVERY_USB" ]] || die "recovery USB is missing: $RECOVERY_USB"
  usb="$(readlink -f "$RECOVERY_USB")"
  [[ -b "$usb" ]] || die "recovery USB is not a block device: $usb"
  [[ "$usb" != "$(real_disk)" ]] || die "refusing to use the internal NVMe as recovery media"

  read -r size model serial transport removable read_only < <(
    lsblk -bdno SIZE,MODEL,SERIAL,TRAN,RM,RO "$usb" | xargs
  )
  [[ "$size" == "$RECOVERY_USB_SIZE_BYTES" ]] ||
    die "recovery USB size mismatch: expected $RECOVERY_USB_SIZE_BYTES, got $size"
  [[ "$model" == "$RECOVERY_USB_MODEL" ]] ||
    die "recovery USB model mismatch: expected $RECOVERY_USB_MODEL, got $model"
  [[ "$serial" == "$RECOVERY_USB_SERIAL" ]] ||
    die "recovery USB serial mismatch: expected $RECOVERY_USB_SERIAL, got $serial"
  [[ "$transport" == "usb" && "$removable" == "1" && "$read_only" == "0" ]] ||
    die "recovery target is not a writable removable USB device"

  mapfile -t usb_parts < <(lsblk -lnpo PATH,TYPE "$usb" | awk '$2 == "part" { print $1 }')
  [[ "${#usb_parts[@]}" == "1" ]] ||
    die "expected exactly one existing recovery USB partition"
  usb_part="${usb_parts[0]}"
  [[ "$(blkid -s PARTUUID -o value "$usb_part")" == "$RECOVERY_USB_OLD_PARTUUID" ]] ||
    die "recovery USB original PARTUUID mismatch"
  [[ "$(blkid -s UUID -o value "$usb_part")" == "$RECOVERY_USB_OLD_UUID" ]] ||
    die "recovery USB original filesystem UUID mismatch"

  source_device="$(findmnt -rn -T "$WINDOWS_ISO" -o SOURCE | head -n 1)"
  source_parent="$(lsblk -ndo PKNAME "$source_device")"
  [[ -n "$source_parent" && "/dev/$source_parent" != "$usb" ]] ||
    die "Windows ISO must not reside on the recovery USB"

  actual_sha="$(sha256sum "$WINDOWS_ISO" | awk '{ print $1 }')"
  [[ "${actual_sha,,}" == "$WINDOWS_ISO_SHA256" ]] ||
    die "Windows ISO checksum mismatch: got $actual_sha"
  repair_size="$(
    7z l -slt "$WINDOWS_ISO" |
      awk '
        /^----------$/ { entries=1; next }
        entries && /^Path = / { path=substr($0, 8) }
        entries && /^Size = / {
          lower=tolower(path)
          if (lower != "sources/install.wim" && lower != "sources/install.esd") total += $3
        }
        END { print total }
      '
  )"
  [[ "$repair_size" =~ ^[0-9]+$ ]] || die "could not calculate recovery-media size"
  ((repair_size + 134217728 < size)) || die "repair-only ISO contents do not fit the USB"

  [[ -f "$BACKUP_DIR/SHA256SUMS" ]] || die "protected-partition backup manifest is missing"
  (
    cd "$BACKUP_DIR"
    sha256sum --check SHA256SUMS
  )

  lsblk -e7 -o NAME,PATH,SIZE,MODEL,SERIAL,TRAN,RM,TYPE,FSTYPE,LABEL,PARTUUID,UUID,MOUNTPOINTS "$usb"
  printf '%s\n' "DESTRUCTIVE TARGET: $RECOVERY_USB -> $usb"
  printf '%s\n' "All existing contents on the $RECOVERY_USB_MODEL USB will be erased."
  printf '%s\n' "The Samsung external system SSD and internal NVMe are excluded by identity."
  read -r -p "Type ERASE-GENERAL-UDISK-ONLY to continue: " confirmation
  [[ "$confirmation" == "ERASE-GENERAL-UDISK-ONLY" ]] ||
    die "recovery USB formatting was not confirmed"

  mapfile -t usb_mounts < <(findmnt -rn -S "$usb_part" -o TARGET)
  for mount_dir in "${usb_mounts[@]}"; do
    umount "$mount_dir"
  done

  wipefs --all "$usb"
  sgdisk --zap-all "$usb"
  sgdisk \
    --clear \
    --new=1:2048:0 \
    --typecode=1:ef00 \
    --change-name=1:WINDOWS-RE \
    "$usb"
  partprobe "$usb"
  udevadm settle
  usb_part="${RECOVERY_USB}-part1"
  [[ -b "$usb_part" ]] || die "new recovery USB partition did not appear"
  mkfs.vfat -F 32 -n WIN11_RE "$usb_part"

  mount_dir="$(mktemp -d /run/windows-recovery-usb.XXXXXX)"
  cleanup_recovery_mount() {
    mountpoint -q "$mount_dir" && umount "$mount_dir"
    rmdir "$mount_dir" 2>/dev/null || true
  }
  trap cleanup_recovery_mount EXIT
  mount "$usb_part" "$mount_dir"
  7z x -y "-o$mount_dir" "$WINDOWS_ISO" \
    '-xr!sources/install.wim' \
    '-xr!sources/install.esd'
  [[ -f "$mount_dir/efi/boot/bootx64.efi" ]] || die "recovery USB is missing bootx64.efi"
  [[ -f "$mount_dir/boot/bcd" ]] || die "recovery USB is missing the boot BCD"
  [[ -f "$mount_dir/sources/boot.wim" ]] || die "recovery USB is missing boot.wim"
  [[ ! -e "$mount_dir/sources/install.wim" && ! -e "$mount_dir/sources/install.esd" ]] ||
    die "full Windows install image was unexpectedly copied"
  sync -f "$mount_dir"
  df -h "$mount_dir"
  du -sh "$mount_dir"
  cleanup_recovery_mount
  trap - EXIT

  lsblk -e7 -o NAME,PATH,SIZE,MODEL,SERIAL,TRAN,RM,TYPE,FSTYPE,LABEL,PARTLABEL,PARTUUID,UUID,MOUNTPOINTS "$usb"
  log "Windows repair-only USB prepared from the verified Microsoft ISO"
  printf '%s\n' "Boot the General UDisk in UEFI mode and press Shift+F10 at Windows Setup."
}

verify_backups() {
  require_root
  verify_backup_filesystem
  [[ -f "$BACKUP_DIR/windows-validation.txt" ]] ||
    die "Windows validation marker is missing"
  [[ -f "$BACKUP_DIR/SHA256SUMS" ]] || die "backup checksum manifest is missing"
  (
    cd "$BACKUP_DIR"
    sha256sum --check SHA256SUMS
  )
}

mount_target() {
  require_root
  local root_part="/dev/disk/by-partuuid/$ROOT_PARTUUID"
  local mapped="/dev/mapper/$MAPPER_NAME"

  [[ -b "$root_part" ]] || die "new encrypted root partition does not exist"
  if [[ ! -b "$mapped" ]]; then
    cryptsetup open "$root_part" "$MAPPER_NAME"
  fi
  [[ "$(blkid -s UUID -o value "$mapped")" == "$BTRFS_UUID" ]] ||
    die "Btrfs UUID does not match the declared configuration"
  mountpoint -q "$TARGET" && die "$TARGET is already mounted"

  mkdir -p "$TARGET"
  mount -o subvol=@root,compress=zstd:3,discard=async,noatime "$mapped" "$TARGET"
  mkdir -p \
    "$TARGET/home" \
    "$TARGET/nix" \
    "$TARGET/var/log" \
    "$TARGET/.snapshots" \
    "$TARGET/boot"
  mount -o subvol=@home,compress=zstd:3,discard=async,noatime "$mapped" "$TARGET/home"
  mount -o subvol=@nix,compress=zstd:3,discard=async,noatime "$mapped" "$TARGET/nix"
  mount -o subvol=@log,compress=zstd:3,discard=async,noatime "$mapped" "$TARGET/var/log"
  mount -o subvol=@snapshots,compress=zstd:3,discard=async,noatime "$mapped" "$TARGET/.snapshots"
  mount -o fmask=0077,dmask=0077 "/dev/disk/by-partuuid/$ESP_PARTUUID" "$TARGET/boot"
  log "target filesystems mounted under $TARGET"
}

partition_and_format() {
  require_root
  preflight
  verify_windows_boot_entry
  verify_backups

  local disk start_sector end_sector sector_size esp_sectors esp_end root_start confirmation
  local partition_number protected_before protected_after
  disk="$(real_disk)"
  sector_size="$(blockdev --getss "$disk")"
  [[ "$sector_size" == "512" ]] || die "unexpected sector size $sector_size"
  start_sector="$(sgdisk --info=6 "$disk" | awk -F: '/First sector/ { gsub(/^ +/, "", $2); split($2, value, " "); print value[1] }')"
  end_sector="$(sgdisk --info=6 "$disk" | awk -F: '/Last sector/ { gsub(/^ +/, "", $2); split($2, value, " "); print value[1] }')"
  [[ "$start_sector" =~ ^[0-9]+$ && "$end_sector" =~ ^[0-9]+$ ]] ||
    die "could not determine the original p6 boundaries"
  esp_sectors=$((2 * 1024 * 1024 * 1024 / sector_size))
  esp_end=$((start_sector + esp_sectors - 1))
  root_start=$((esp_end + 1))
  ((root_start < end_sector)) || die "calculated root partition is empty"

  printf '%s\n' "DESTRUCTIVE TARGET: $disk serial $INTERNAL_SERIAL"
  printf '%s\n' "Only old p6 PARTUUID $OLD_ROOT_PARTUUID will be replaced."
  printf '%s\n' "Protected Windows partitions p1-p5 will not be formatted."
  read -r -p "Type ERASE-BLANK-P6-ONLY to continue: " confirmation
  [[ "$confirmation" == "ERASE-BLANK-P6-ONLY" ]] || die "destructive confirmation declined"

  protected_before="$BACKUP_DIR/protected-p1-p5-before.txt"
  protected_after="$BACKUP_DIR/protected-p1-p5-after.txt"
  {
    for partition_number in 1 2 3 4 5; do
      printf '%s\n' "=== protected partition $partition_number ==="
      sgdisk --info="$partition_number" "$disk"
    done
  } >"$protected_before"

  sgdisk --delete=6 "$disk"
  sgdisk \
    --new=6:"$start_sector":"$esp_end" \
    --typecode=6:EF00 \
    --change-name=6:NIXOS-ESP \
    --partition-guid=6:"$ESP_PARTUUID" \
    "$disk"
  sgdisk \
    --new=7:"$root_start":"$end_sector" \
    --typecode=7:8309 \
    --change-name=7:NIXOS-LUKS \
    --partition-guid=7:"$ROOT_PARTUUID" \
    "$disk"
  partprobe "$disk"
  udevadm settle

  verify_protected_partitions
  [[ -b "/dev/disk/by-partuuid/$ESP_PARTUUID" ]] || die "new ESP was not created"
  [[ -b "/dev/disk/by-partuuid/$ROOT_PARTUUID" ]] || die "new LUKS partition was not created"
  sgdisk --verify "$disk"
  {
    for partition_number in 1 2 3 4 5; do
      printf '%s\n' "=== protected partition $partition_number ==="
      sgdisk --info="$partition_number" "$disk"
    done
  } >"$protected_after"
  [[ "$(<"$protected_before")" == "$(<"$protected_after")" ]] ||
    die "protected p1-p5 GPT metadata changed; refusing to format the new partitions"
  log "protected p1-p5 GPT metadata is unchanged"
  lsblk -e7 -o NAME,PATH,SIZE,TYPE,FSTYPE,LABEL,PARTLABEL,PARTUUID,UUID "$disk" \
    >"$BACKUP_DIR/lsblk-after-partitioning.txt"
  sgdisk --print "$disk" >"$BACKUP_DIR/partition-table-after.txt"

  mkfs.fat -F 32 -n NIXOS-ESP -i A0C12EDF "/dev/disk/by-partuuid/$ESP_PARTUUID"
  cryptsetup luksFormat \
    --type luks2 \
    --uuid "$LUKS_UUID" \
    --label NIXOS-LUKS \
    "/dev/disk/by-partuuid/$ROOT_PARTUUID"
  [[ "$(cryptsetup luksUUID "/dev/disk/by-partuuid/$ROOT_PARTUUID")" == "$LUKS_UUID" ]] ||
    die "LUKS UUID mismatch after formatting"

  printf '%s\n' "The next command prints a LUKS recovery key."
  printf '%s\n' "Store it somewhere independent before continuing."
  systemd-cryptenroll --recovery-key "/dev/disk/by-partuuid/$ROOT_PARTUUID"
  cryptsetup open "/dev/disk/by-partuuid/$ROOT_PARTUUID" "$MAPPER_NAME"
  mkfs.btrfs -f -L NIXOS-ROOT -U "$BTRFS_UUID" "/dev/mapper/$MAPPER_NAME"

  mkdir -p "$TARGET"
  mount "/dev/mapper/$MAPPER_NAME" "$TARGET"
  local subvolume
  for subvolume in @root @home @nix @log @snapshots; do
    btrfs subvolume create "$TARGET/$subvolume"
  done
  umount "$TARGET"
  mount_target
  log "partitioning and formatting complete"
}

write_excludes() {
  local destination="$1"
  printf '%s\n' \
    '/.cache/' \
    '/.local/share/Trash/' \
    '/.local/share/hatch/' \
    '/.local/share/pnpm/' \
    '/.local/state/nix/profiles/' \
    '/.nix-defexpr/' \
    '/.nix-profile' \
    '/.npm/' \
    '/.bun/install/cache/' \
    '/.cargo/registry/' \
    '/go/pkg/mod/' \
    '/.codex/.tmp/' \
    '/.config/google-chrome/OptGuideOnDeviceModel/' \
    '/Downloads/nixos-*.iso' \
    '/http-nu/target/' \
    '/lib/reedline/target/' \
    '/lib/xs/target/' \
    '/lib/marimo/node_modules/' \
    '/lib/marimo/.venv/' \
    '/lib/marimo/.pixi/' \
    '/supro-ai/node_modules/' \
    '/supro-ai/dist/' \
    '/bootstrap-ai/.venv/' \
    '/nix-ui/node_modules/' \
    '/nix-ui/.venv/' \
    '/nix-ui/apps/xr/node_modules/' \
    '/nix-ui/apps/xr/dist/' \
    '/nix-xr/node_modules/' \
    '/nix-xr/dist/' \
    '/snorkel/evals/.venv/' \
    '/nix-tui/.venv/' \
    '/xr-term/node_modules/' >"$destination"
}

verify_external_source_root() {
  local root_uuid
  root_uuid="$(findmnt -rn -T / -o UUID | head -n 1)"
  [[ "$root_uuid" == "$EXTERNAL_ROOT_UUID" ]] ||
    die "current root is not the preserved external installation"
  mountpoint -q "$TARGET/home" || die "target home is not mounted"
}

copy_home() {
  require_root
  verify_external_source_root
  verify_backup_filesystem

  local excludes log_file
  excludes="$(mktemp)"
  write_excludes "$excludes"
  mkdir -p "$TARGET/home/schlich" "$BACKUP_DIR"
  log_file="$BACKUP_DIR/rsync-home-$(date -u +%Y%m%dT%H%M%SZ).log"
  rsync \
    -aHAX \
    --numeric-ids \
    --human-readable \
    --info=stats2,progress2 \
    --exclude-from="$excludes" \
    /home/schlich/ "$TARGET/home/schlich/" | tee "$log_file"
  rm -f "$excludes"
  chown 1001:100 "$TARGET/home/schlich"
  sync
  log "home copy complete; log: $log_file"
}

copy_system_state() {
  require_root
  verify_external_source_root

  local source relative
  local -a sources=()
  shopt -s nullglob
  for source in \
    /etc/machine-id \
    /etc/ssh/ssh_host_* \
    /etc/NetworkManager/system-connections \
    /var/lib/bluetooth \
    /var/lib/NetworkManager \
    /var/lib/AccountsService \
    /var/lib/systemd/linger \
    /var/lib/noctalia-greeter; do
    [[ -e "$source" ]] || continue
    relative=".$source"
    sources+=("$relative")
  done
  shopt -u nullglob
  ((${#sources[@]} > 0)) || die "no system state sources were found"
  (
    cd /
    rsync -aHAXR --numeric-ids "${sources[@]}" "$TARGET/"
  )
  sync
  log "machine identity, network, Bluetooth, SSH, and small service state copied"
}

install_system() {
  require_root
  verify_external_source_root
  [[ -f "$REPO/flake.nix" ]] || die "flake not found at $REPO"
  nixos-install \
    --root "$TARGET" \
    --flake "path:$REPO#asus" \
    --no-root-password
  copy_system_state
  printf '%s\n' "Set the schlich login password for the fresh installation."
  nixos-enter --root "$TARGET" -c "passwd schlich"
  log "NixOS installation complete"
}

snapshot_root() {
  require_root
  mountpoint -q "$TARGET/.snapshots" || die "snapshot subvolume is not mounted"
  local name
  name="root-installed-$(date -u +%Y%m%dT%H%M%SZ)"
  btrfs subvolume snapshot -r "$TARGET" "$TARGET/.snapshots/$name"
  log "created read-only root snapshot $name"
}

verify_target() {
  require_root
  local target_name available minimum
  for target_name in / /home /nix /var/log /.snapshots /boot; do
    findmnt -rn "$TARGET$target_name" >/dev/null ||
      die "missing target mount: $target_name"
  done
  [[ "$(blkid -s UUID -o value "/dev/mapper/$MAPPER_NAME")" == "$BTRFS_UUID" ]] ||
    die "mounted Btrfs UUID mismatch"
  [[ "$(blkid -s UUID -o value "/dev/disk/by-partuuid/$ESP_PARTUUID")" == "$ESP_UUID" ]] ||
    die "mounted ESP UUID mismatch"
  available="$(df --output=avail -B1 "$TARGET" | tail -n 1 | xargs)"
  minimum=$((20 * 1024 * 1024 * 1024))
  ((available >= minimum)) ||
    die "less than 20 GiB remains free on the target"
  findmnt -R "$TARGET"
  btrfs filesystem usage "$TARGET"
  log "target verification passed with at least 20 GiB free"
}

dry_run_home() {
  require_root
  verify_external_source_root
  verify_backup_filesystem

  local excludes log_file
  excludes="$(mktemp)"
  write_excludes "$excludes"
  log_file="$BACKUP_DIR/rsync-home-final-dry-run.txt"
  rsync \
    -aHAXn \
    --numeric-ids \
    --itemize-changes \
    --exclude-from="$excludes" \
    /home/schlich/ "$TARGET/home/schlich/" | tee "$log_file"
  rm -f "$excludes"
  log "review unexplained entries in $log_file"
}

unmount_target() {
  require_root
  local mount_path
  for mount_path in \
    "$TARGET/boot" \
    "$TARGET/.snapshots" \
    "$TARGET/var/log" \
    "$TARGET/nix" \
    "$TARGET/home" \
    "$TARGET"; do
    mountpoint -q "$mount_path" && umount "$mount_path"
  done
  [[ -b "/dev/mapper/$MAPPER_NAME" ]] && cryptsetup close "$MAPPER_NAME"
  log "target unmounted and LUKS mapping closed"
}

status() {
  local disk
  disk="$(real_disk)"
  lsblk -e7 -o NAME,PATH,SIZE,TYPE,FSTYPE,LABEL,PARTLABEL,PARTUUID,UUID,MOUNTPOINTS "$disk"
  efibootmgr || true
  findmnt -R "$TARGET" || true
}

usage() {
  cat <<'EOF'
Usage: internal-nvme-migration <subcommand>

Run these subcommands in order from the external NixOS installation:
  preflight       Verify disk serial, protected Windows partitions, and blank p6
  backup          Back up GPT/EFI/MSR/WinRE/ASUS data before Windows EFI repair
  prepare-recovery-usb
                  Verify the Microsoft ISO and replace the General UDisk contents
  validate-windows
                  After repair, confirm Windows checks and enable partitioning
  partition       Replace only blank p6, format ESP/LUKS/Btrfs, and mount /mnt
  mount-target    Unlock and mount an already formatted target under /mnt
  copy-home       Copy high-value home state with the reviewed exclusion policy
  install         Install .#asus, copy system state, and set the login password
  copy-home       Run again after closing mutable desktop applications
  dry-run         Produce the final rsync comparison manifest
  snapshot-root   Create the manual read-only root baseline snapshot
  verify          Verify mounts, identifiers, Btrfs health, and 20 GiB headroom
  unmount         Unmount /mnt and close the LUKS mapping
  status          Show the current disk, firmware-entry, and target-mount state

Run these post-migration subcommands from the internal NixOS installation:
  backup-luks-header
                  Back up and checksum the LUKS2 header on the external archive
  enroll-tpm2     Add TPM2 PCR-7 auto-unlock and preserve existing recovery slots

The partition subcommand is destructive and requires two explicit confirmations.
It refuses to touch any disk or partition whose immutable identifiers differ.
EOF
}

case "${1:-}" in
  preflight) preflight ;;
  backup) backup_windows_boot_partitions ;;
  prepare-recovery-usb) prepare_windows_recovery_usb ;;
  validate-windows) record_windows_validation ;;
  partition) partition_and_format ;;
  mount-target) mount_target ;;
  copy-home) copy_home ;;
  install) install_system ;;
  copy-system-state) copy_system_state ;;
  dry-run) dry_run_home ;;
  snapshot-root) snapshot_root ;;
  verify) verify_target ;;
  unmount) unmount_target ;;
  status) status ;;
  backup-luks-header) backup_luks_header ;;
  enroll-tpm2) enroll_tpm2 ;;
  *) usage; exit 2 ;;
esac
