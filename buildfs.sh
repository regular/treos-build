#!/usr/bin/bash
set -eux -o pipefail

export ssb_appname=ssb-pacman
root=root
bin="$HOME/.ssb-pacman/node_modules/ssb-pacman/bin"
sudo echo "thanks" # so sudo will not prompt soon
source ./config
get-config

ssb-pacman () {
  local cmd=$1
  shift
  $bin/ssb-pacman-$cmd $*
}

install_packages () {
  # syslinux is needed for memdiskfind
  local pkgs="\
    haveged \
    intel-ucode \
    syslinux \
    memtest86+ \
    efitools \
    ${packages[@]} \
  "

  sudo arch-chroot "$root" bash -c "pacman --noconfirm -S $pkgs"
  #sudo arch-chroot "$root" bash -c "pacman -Scc --noconfirm"
  sudo rm ${root}/var/cache/pacman/pkg/*
}

make_initcpio () {
  sudo arch-chroot "$root" bash -c "efi_volume_id="$efi_volume_id" mkinitcpio -p kiosk"
}

copy_efi_files() {
  local efitools="$root/usr/share/efitools"
  local EFI="$root/boot/EFI"
  sudo mkdir -p "$EFI/boot"
  sudo cp "$efitools/efi/PreLoader.efi" "$EFI/boot/bootx64.efi"
  sudo cp "$efitools/efi/HashTool.efi" "$EFI/boot/"
  sudo cp "$root/usr/lib/systemd/boot/efi/systemd-bootx64.efi" \
    "$EFI/boot/loader.efi"
  sudo cp -r build/loader "$root/boot/"
}

makeLUKSContainer () {
  local luks_img=$1
  local rootfs_img=$2
  local passphrase=$(head -c9 /dev/urandom|base64|tr 'O01lzZyY+/' 'abcdefghij')
  echo "New LUKS password is: ${passphrase}"

  local blocks=$(( 2048 + $(du -B 1024 "$rootfs_img" | cut -f1) ))
  truncate -s $(( $blocks * 1024 )) "$luks_img" 

  local loop=$(sudo losetup -f)
  sudo losetup "$loop" "$luks_img"
  echo -n "${passphrase}" | sudo cryptsetup luksFormat "$loop" -
  echo -n "${passphrase}" | sudo cryptsetup luksOpen "$loop" cryptroot
  local dev=/dev/mapper/cryptroot
  sudo dd "if=$rootfs_img" "of=$dev" bs=512
  sudo cryptsetup luksClose cryptroot
  sudo losetup -d "$loop"
}

make_cowspace () {
  if [[ -n "${cowspace_size}" ]] && (( $(echo "$cowspace_size"|tr -d [A-Z][a-z]) )); then
    local cowspace_img="build/cowspace.img"
    if ! [[ -f "${cowspace_img}" ]]; then
      dd of=build/cowspace.img if=/dev/zero "bs=${cowspace_size}" count=1
      sudo mkfs.ext3 -L cowspace -U random "${cowspace_img}"
    fi
    cowspace_uuid=$(sudo blkid -s UUID -o value "${cowspace_img}")
  fi
}

make_datapart () {
  local src="$1"
  if [[ -n "${datapart_size}" ]] && (( $(echo "$datapart_size"|tr -d [A-Z][a-z]) )); then
    local datapart_img="build/datapart.img"
    if ! [[ -f "${datapart_img}" ]]; then
      truncate --size=${datapart_size} "${datapart_img}"
      sudo mkfs.ext3 -L datapart -U random "${datapart_img}"
    fi
    local tmp=$(mktemp -d)
    sudo mount "${datapart_img}" "${tmp}"
    pushd "${src}"
    for d in ${datapart_dirs[@]}; do
      if [[ -d ".${d}" ]]; then
        sudo cp --parents -rav ".${d}" "${tmp}"
      else
        sudo mkdir -p "${tmp}${d}"
      fi
    done
    popd
    if [ -n populate-datapart ]; then
      echo "Populating data partition"
      populate-datapart "${tmp}"
    fi
    sudo umount "${tmp}"
    rm -rf "${tmp}"

    datapart_uuid=$(sudo blkid -s UUID -o value "${datapart_img}")

    if [ -n fix-permissions ]; then
      sudo cp "${datapart_img}" "${root}"
      sudo cp config "${root}"
      cat - > >(sudo tee "${root}/fix-perms.sh") <<EOF
set -eux

function cleanup {
  umount datapart
  rm -rf datapart
}

mkdir datapart
mount datapart.img datapart
trap cleanup EXIT

source config
fix-permissions datapart
sync
EOF
      sudo -E arch-chroot "${root}" bash fix-perms.sh
      sudo mv "${root}/datapart.img" "${datapart_img}"
      sudo rm "${root}/config"
    fi
  fi
}

# Prepare efiboot.img::/EFI for "El Torito" EFI boot mode
make_efiboot_image () {
  local payload=$1

  # we allocate 500MB plus the size of the payload
  local size=$(( 500 + $(du --block-size=1M "$payload"|cut -f1) ))
  local tmp=$(mktemp -d)
  truncate -s ${size}M "$tmp/efiboot.img"
  mkfs.fat -i "$(echo "${efi_volume_id}"|tr -d '-')" -n "$iso_label" "$tmp/efiboot.img"
  local efiboot="$tmp/efiboot"
  mkdir -p "$efiboot"
  sudo mount "$tmp/efiboot.img" "$efiboot"
  sudo mkdir -p "$efiboot/EFI"
  sudo cp -v "$root"/boot/{kiosk-initramfs.img,intel-ucode.img,vmlinuz-linux} "$efiboot"
  sudo cp -rv "$root/boot/EFI/boot" "$efiboot/EFI"
  sudo cp -rv "build/loader" "$efiboot"
  sudo mkdir -p "$efiboot/arch/x86_64"
  sudo cp "$payload" "$efiboot"
  if [[ -v cowspace_uuid ]]; then
    echo "$cowspace_uuid" | sudo tee "$efiboot/cowspace_uuid"
  fi
  if [[ -v rootfs_hash ]]; then
    echo "$rootfs_hash" | sudo tee "$efiboot/rootfs_hash"
  fi
  if [[ -v datapart_uuid ]]; then
    echo "$datapart_uuid" | sudo tee "$efiboot/datapart_uuid"
    sudo rm "$efiboot/datapart_dirs" || true
    for d in ${datapart_dirs[@]}; do
      echo "${d}" | sudo tee -a "$efiboot/datapart_dirs"
    done
  fi
  treos-create-meta --format=ssb | sudo tee "$efiboot/treos-issue.json"
  sudo tre-deployment-find "$efiboot/treos-issue.json" --type system --write-back
  treos-create-meta --include-paths > treos-issue.json
  sudo umount -d "$efiboot"
  mkdir -p build/EFI
  sudo cp "$tmp/efiboot.img" "build/EFI"
  sudo rm -rf "$tmp"
}

make_iso () {
  # add an EFI "El Torito" boot image (FAT filesystem) to ISO-9660 image.
  local eltorito_args=(
    -eltorito-alt-boot
    -e efiboot.img
    -no-emul-boot
    -eltorito-alt-boot
    -efi-boot-part --efi-boot-image
  )
  local meta_args=(
    -iso-level 3
    -full-iso9660-filenames
    -volid "${iso_label}"
    -appid "${iso_application}"
    -publisher "${iso_publisher}"
    -preparer "prepared by treos-build"
  )

  if [[ -v cowspace_uuid ]]; then
    local cowspace_args=(
      -append_partition 2 Linux build/cowspace.img
      -appended_part_as_gpt
    )
  else
    local cowspace_args=()
  fi

  if [[ -v datapart_uuid ]]; then
    local datapart_args=(
      -append_partition 3 Linux build/datapart.img
      -appended_part_as_gpt
    )
  else
    local datapart_args=()
  fi

  sudo xorriso -as mkisofs \
    "${meta_args[@]}" \
    "${eltorito_args[@]}" \
    -boot-load-size 4 \
    -boot-info-table \
    \
    "${cowspace_args[@]}" \
    "${datapart_args[@]}" \
    -output "${iso_label}.iso" \
    "build/EFI"

  parted "${iso_label}.iso" print
}

enable-service () {
  sudo systemctl --root "$root" enable "$1"
}

disable-service () {
  sudo systemctl --root "$root" disable "$1"
}

set_efi_volume_id () {
  if [[ -f efi_volume_id ]]; then
    efi_volume_id=$(cat efi_volume_id)
  else
    local x="$(hexdump -n 4 -e '2/2 "%04X-"' /dev/random)"
    efi_volume_id="${x%-}"
    echo "${efi_volume_id}" > efi_volume_id
  fi
}

mkdir -p build
set_efi_volume_id
make_cowspace 

ssb-pacman bootstrap "$root"
install_packages
enable-services
copy_efi_files

make_initcpio
make_datapart "$root"

sudo mksquashfs "$root" "build/rootfs.sfs" -noappend -comp xz -wildcards -e 'boot/*'
rootfs_hash=$(cat build/rootfs.sfs | shasum -a 256 -b | cut -d' ' -f1)
echo "rootfs hash is ${rootfs_hash}"
sudo arch-chroot root ssb-pacman-shrinkwrap > packages.shrinkwrap
if (( $encrypt_root_fs )); then
  makeLUKSContainer "build/luks.img" "build/rootfs.sfs"
  make_efiboot_image "build/luks.img"
else
  make_efiboot_image "build/rootfs.sfs"
fi
make_iso

# --
# Now copy to USB stick with
# sudo dd bs=4M if=PROJECT.iso "of=/dev/disk/by-id/<id-of-usbstick>" status=progress
# or `gzip PROJECT.iso` for upload
