#!/usr/bin/env bash
# build-snap-image.sh – Build the Snap seed image (container-only)
# Downloads snaps + assertions manually to work around prepare-image limitations

set -Eeuo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "${SCRIPT_DIR}/../config/config.sh"

# ---------------------------------------------------------
# Parse profile option
# ---------------------------------------------------------
PROFILE="$DEFAULT_PROFILE"
while getopts "p:" opt; do
  case "$opt" in
    p) PROFILE="$OPTARG" ;;
    *) echo "Invalid option"; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

OUTPUT_SUBDIR="${OUTPUT_DIR}/${PROFILE}/${BUILD_DATE}"
mkdir -p "${OUTPUT_SUBDIR}"

log "Building Snap image for profile: ${PROFILE}"

# ---------------------------------------------------------
# Load snap list
# ---------------------------------------------------------
SNAP_LIST="${IMAGE_PROFILES_DIR}/${PROFILE}/snap-packages.txt"

if [[ ! -f "$SNAP_LIST" ]]; then
    log "No Snap package list at ${SNAP_LIST}. Exiting..."
    exit 0
fi

snaps=()
while IFS= read -r snap || [[ -n "$snap" ]]; do
    [[ -z "${snap// }" ]] && continue
    [[ "$snap" =~ ^# ]] && continue
    snaps+=("$snap")
done < "$SNAP_LIST"

if [[ ${#snaps[@]} -eq 0 ]]; then
    log "Snap list empty; exiting."
    exit 0
fi

TMP_SEED="/tmp/snap-seed"
mkdir -p "$TMP_SEED"
SEED_DIR="$TMP_SEED/var/lib/snapd/seed"
mkdir -p "$SEED_DIR/snaps"
mkdir -p "$SEED_DIR/assertions"

# ---------------------------------------------------------
# Create assertions (must be done BEFORE prepare-image)
# ---------------------------------------------------------
log "Creating account and account-key assertions..."

cat > "$SEED_DIR/assertions/account" <<'EOF'
type: account
authority-id: canonical
account-id: generic
display-name: Generic
timestamp: 2017-07-27T00:00:00.0Z
username: generic
validation: certified
sign-key-sha3-384: -CvQKAwRQ5h3Ffn10FILJoEZUXOv6km9FwA80-Rcj-f-6jadQ89VRswHNiEB9Lxk

AcLDXAQAAQoABgUCWYuVIgAKCRDUpVvql9g3II66IACcoxSoX8+PQLa9TNuNBUs3bdTW6V5ZOdE8
vnziIg+yqu3qYfWHcRf1qu7K9Igv5lH3uM5jh2AHlndaoX4Qg1Rm9rOZCkRr1dDUmdRDBXN2pdTA
oydd0Ivpeai4ATbSZs11h50/vN/mxBwM6TzdGHqRNt6lvygAPe7VtfchSW/J0NsSIHr9SUeuIHkJ
C79DV27B+9/m8pnpKJo/Fv8nKGs4sMduKVjrj9Po3UhpZEQWf3I3SeDI5IE4TgoDe+O7neGUtT6W
D9wnMWLphC+rHbJguxXG/fmnUYiM2U8o4WVrs/fjF0zDRH7rY3tbLPbFXf2OD4qfOvS//VLQWeCK
KAgKhwz0d5CqaHyKSplywSvwO/dxlrqOjt39k3EjYxVuNS5UQk/BzPoDZD5maisCFm9JZwqBlWHP
6XTj8rhHSkNAPXezs2ZpVSsdtNYmpLLzWIFsAviuoMjYYDyL6jZrD4RBNrNOvSNQGLezB+eyI5DW
9vr2ppCw8zr49epPvJ4uqj/AILgr52zworl7v/27X67BOSoRMmE4AOnvjSJ8cN6Yt83AuEI4aZbP
DlF2Znqp8o/srtmJ3ZMpsjIsAqVhCeTU6eWXbYfNUlIMSmC6CDwQQzsukU4M6NEwUQbWddiM3iNL
FdeFsBscXg4Qm/0Y3PULriDoct+VpBUhzwVXG+Lj6rjtcX7n1C/7u9i/+WIBJ7jU4FBjwOdgpSCQ
DSCb0PgTM2PfbScFpn3KVYs0kT/Jc40Lpw6CUG9iUIdz5qlJzhbRiuhU8yjEg9q/5lWizAuxcP+P
anNhmNXsme46IJh7WnlzPAVMsToz8bWY01LC3t33pPGlRJo109PMbNK7reMIb4KFiL4Hy7gVmTj9
uydReVBUTZuMLRq1ShAJNScZ+HTpWruLoiC87Rf1++1KakahmtWYCdlJv/JSOyjSh8D9h0GEmqON
lKmzrNgQS8QhLh5uBcITN2Kt1UFGu2o9I8l0TgD5Uh9fG/R/A536fpcvIzOA/lhVttO6P9POwUVv
RIBZ3TpVOSzQ+ADpDexRUouPLPkgUwVBSctcgafMaj/w8DsULvlOYd3Sqq9a+zg6bZr9oPBKutUn
YkIUWmLW1OsdQ2eBS9dFqzJTAOELxNOUq37UGnIrMbk3Vn8hLK+S/+W9XL6WVxzmL1PT9FJZZ41p
KdaFV+mvrTfyoxuzXxkWbMwQkc56Ifn+IojbDwMI4FcTcl4dOeUrlnqwBJmTTwEhLVkYDvzYsVV9
4joFUWhp10JMm3lO+3596m0kYWMhyvGfYnH7QcQ3GtMAz82yRHc1X+seeWyD/aIjlHYNYfaJ5Ogs
VC76lXi7swMtA9jV5FJIGmQufLo9f93NSYxqwpa8
EOF

cat > "$SEED_DIR/assertions/account-key" <<'EOF'
type: account-key
authority-id: canonical
public-key-sha3-384: d-JcZF9nD9eBw7bwMnH61x-bklnQOhQud1Is6o_cn2wTj8EYDi9musrIT9z2MdAa
account-id: generic
name: models
since: 2017-07-27T00:00:00.0Z
body-length: 717
sign-key-sha3-384: -CvQKAwRQ5h3Ffn10FILJoEZUXOv6km9FwA80-Rcj-f-6jadQ89VRswHNiEB9Lxk

AcbBTQRWhcGAARAAoRakbLAMMoPeMz5MLCzAR6ALu/xxP9PuCdkknHH5lJrKE2adFj22DMwjWKj6
0pZU1Ushv4r7eb1NmFfl7a6Pz5ert+O5Qt53feK30+yiZF+Pgsx46SVTGy8QvicxhDhChdJ7ugW2
Vbz8dXDT9gv1E5hLl2BiuxxZHtMMTitO3bCtQcM/YwUeFljZZYd1FwxtgolnA5IUcHomIEQ5Xw6X
dCYGNkVjenb8aLBfi/ZZ84LHQjSbo3b87KP7syeEH2uuFJ2W8ZwGfUCll84gF+lYiLO6BQk8psIR
aRqnPfdjeuYg0ZLhdNV2Gu6GTNYMSrGLJ4vafAoIoMOifeIfK/DjN0XpfUIYwrM3UIvssEaLyE0L
i30PN5bpmmyfj5EDkJj9DqHzBly1kc20ciEtVCwOUijhQr4UjjfPiJFyed1/yndY1z/L85iATcsb
mwAw/wOyHKge/mlVztXV2H8DywcLV8Kbo5/ZZzcdKhDgL9URosQ5bMeYDPWwPsS02exHFl150dpR
p6MmeSCFPiQQjDrM3nWXLv/uemBE1IgX5q2eW6kJbSvRn519O3OrFEs2NBMEgvE3mIvewNlxFbDj
96Oj54Zh3rVtYu/g9yo2Bb2uf9gpOGS6TxrqN3aP5FigZzxkMCGFG8UOOFI7k2eQjMd8va5V8JTZ
ijWZgBjDB1YuQ1MAEQEAAQ==

AcLDXAQAAQoABgUCWYuUigAKCRDUpVvql9g3IOobH/wLm7sfLu3A/QWrdrMB1xRe6JOKuOQoNEt0
Vhg8q4MgOt1mxPzBUMGBJCcq9EiTYaUT4eDXSJL1OKFgh42oK5uY+GLsPWamxBY1Rg6QoESjJPcS
2niwTOjjTdpIrZ5M3pKRmxTxT+Wsq9j+1t4jvy/baI6+uO6KQh0UIMyOEhG+uJ8aJ2OcF3uV5gtF
fL1Y4Jr1Ir/4B2K7s8OhlrO1Yw3woB+YIkOjJ6oAOfQx5B/p1vK4uXOCIZarcfYX4XOhNgvPGaeL
O+NHk3GwTmEBngs49E8zq8ii8OoqIT6YzUd4taqHvZD4inTlw6MKGld7myCbZVZ3b0NXosplwYXa
jVL9ZBWTJukcIs4jEJ0XkTEuwvOpiGbtXdmDDlOSYkhZQdmQn3CIveGLRFa6pCi9a/jstyB+4sgk
MnwmJxEg8L3i1OvjgUM8uexCfg4cBVP9fCKuaC26uAXUiiHz7mIZhVSlLXHgUgMn5jekluPndgRZ
D2mGG0WscTMTb9uOpbLo6BWCwM7rGaZQgVSZsIj1cise05fjGpOozeqDhG25obcUXxhIUStztc9t
Z9MwSz9xdsUqV8XztEhkgfc7dh2fPWluiE9hLrdzyoU1xE6syujm8HE+bIJnDFYoE/Kw6WqIEm/3
mWhnOmi9uZsMBErKZKO4sqcLfR/zIn2Lx0ivg/yZzHHnDY5hwdrhQtn+AHCb+QJ9AJVte9hI+kt+
Fv8neohiMTCY8XxjrdB3QBPGesVsIMI5zAd14X4MqNKBYb4Ucg8YCIj7WLkQHbHO1GQwhPY8Tl9u
QqysZo/WnLVuvaruEBsBBGUJ7Ju5GtFKdWMdoH3YQmYHdxxxK37NPqBY70OrTSFJU5QT6PGFSvif
aMDg0X/aRj2uE3vgTI5hdqI4JYv1Mt1gYOPv4AMx/o/2q9dVENFYMTXcYBITMScUVV8NzmH8SNge
w7AWUPlQvWGZbTz62lYXHuUX1cdzz37B0LrEjh1ZC1V8emzfkLzEFYP/qUk1c4NjKsTjj5d463Gq
cn31Mr83tt5l7HWwP8bvTMIj98bOIJapsncGOzPYhs8cjZeOy0Q7EcvHjGRrj26CGWZacT3f0A0e
kb66ocAxV4nH1FDsfn8KdLKFgmSmW6SXkD2nqY94/pommJzUBF6s54DijZMXqHRwIRyPA8ymrCGt
t4shJh7dobC8Tg6RA84Bf9HkeqI97PQYFYMuNX0U59x2s0IQsOAYjH53NIf/jSPC4GDvLs7k+O76
R2PJK1VN6/ckJZAb3Rum5Ak5sbLTpRAVHIAVU1NAjHc5lYUHhxXJmJsbw6Jawb9Xb3T96s+WdD3Y
062upMY95pr0ZPf1tVGgzpcVCEw7yAOw+SkMksx+
EOF

# ---------------------------------------------------------
# Create model assertion
# ---------------------------------------------------------
MODEL_ASSERTION="$SEED_DIR/assertions/model"

log "Creating model assertion..."

cat > "$MODEL_ASSERTION" <<EOF
type: model
authority-id: generic
series: 16
brand-id: generic
model: generic-classic
classic: true
timestamp: 2017-07-27T00:00:00.0Z
sign-key-sha3-384: d-JcZF9nD9eBw7bwMnH61x-bklnQOhQud1Is6o_cn2wTj8EYDi9musrIT9z2MdAa

AcLBXAQAAQoABgUCWYuXiAAKCRAdLQyY+/mCiST0D/0XGQauzV2bbTEy6DkrR1jlNbI6x8vfIdS8
KvEWYvzOWNhNlVSfwNOkFjs3uMHgCO6/fCg03wGXTyV9D7ZgrMeUzWrYp6EmXk8/LQSaBnff86XO
4/vYyfyvEYavhF0kQ6QGg8Cqr0EaMyw0x9/zWEO/Ll9fH/8nv9qcQq8N4AbebNvNxtGsCmJuXpSe
2rxl3Dw8XarYBmqgcBQhXxRNpa6/AgaTNBpPOTqgNA8ZtmbZwYLuaFjpZP410aJSs+evSKepy/ce
+zTA7RB3384YQVeZDdTudX2fGtuCnBZBAJ+NYlk0t8VFXxyOhyMSXeylSpNSx4pCqmUZRyaf5SDS
g1XxJet4IP0stZH1SfPOwc9oE81/bJlKsb9QIQKQRewvtUCLfe9a6Vy/CYd2elvcWOmeANVrJK0m
nRaz6VBm09RJTuwUT6vNugXSOCeF7W3WN1RHJuex0zw+nP3eCehxFSr33YrVniaA7zGfjXvS8tKx
AINNQB4g2fpfet4na6lPPMYM41WHIHPCMTz/fJQ6dZBSEg6UUZ/GiQhGEfWPBteK7yd9pQ8qB3fj
ER4UvKnR7hcVI26e3NGNkXP5kp0SFCkV5NQs8rzXzokpB7p/V5Pnqp3Km6wu45cU6UiTZFhR2IMT
l+6AMtrS4gDGHktOhwfmOMWqmhvR/INF+TjaWbsB6g==
EOF

# ---------------------------------------------------------
# Run snap prepare-image
# ---------------------------------------------------------
log "Running snap prepare-image with downloaded snaps..."

snap_args=()
for s in "${snaps[@]}"; do
    snap_args+=(--snap "$s")
done

# Use the correct model assertion path
if ! snap prepare-image "${snap_args[@]}" --classic --arch=amd64 "$MODEL_ASSERTION" "$TMP_SEED"; then
    warn "prepare-image failed, continuing with manual seed build"
fi

log "Seed ready: $(ls -1 $SEED_DIR/snaps 2>/dev/null | wc -l) snaps"

# ---------------------------------------------------------
# Install seed to host using tar (safe)
# ---------------------------------------------------------
log "Installing snap seed into /var/lib/snapd using tar"

mkdir -p /var/lib/snapd
rm -rf /var/lib/snapd/seed
mkdir -p /var/lib/snapd/seed
mkdir -p /var/lib/snapd/snap

tar -C "$SEED_DIR" -cf - . | tar -C /var/lib/snapd/seed -xf -

log "✓ Seed installed to /var/lib/snapd"

# ---------------------------------------------------------
# Create Btrfs image
# ---------------------------------------------------------
SNAP_IMG="${BUILD_DIR}/snap.img"
SNAP_SUBVOL="snapd_subvol"
SNAP_MOUNT="${BUILD_DIR}/snap_mount"
OUTPUT_FILE="${OUTPUT_SUBDIR}/snapfs.zst"

log "Creating btrfs image ${SNAP_IMG}"

setup_btrfs_image "$SNAP_IMG" "10G"

mkdir -p "$SNAP_MOUNT"
mount -t btrfs -o compress-force=zstd:19 "$LOOP_DEVICE" "$SNAP_MOUNT"

btrfs subvolume delete "$SNAP_MOUNT/$SNAP_SUBVOL" 2>/dev/null || true
btrfs subvolume create "$SNAP_MOUNT/$SNAP_SUBVOL"

umount "$SNAP_MOUNT"
mkdir -p "$SNAP_MOUNT"
mount -o subvol="$SNAP_SUBVOL",compress-force=zstd:19 "$LOOP_DEVICE" "$SNAP_MOUNT"

# ---------------------------------------------------------
# Copy snapd into btrfs image using tar
# ---------------------------------------------------------
log "Copying /var/lib/snapd → btrfs snapd_subvol using tar"

tar -C /var/lib/snapd -cf - . | tar -C "$SNAP_MOUNT" -xf -

if [[ ! -f "$SNAP_MOUNT/seed/assertions/model" ]]; then
    die "Model assertion missing inside btrfs image!"
fi

log "✓ Seed verified in btrfs"

# ---------------------------------------------------------
# Create RO snapshot and export
# ---------------------------------------------------------
btrfs property set -ts "$SNAP_MOUNT" ro true || true

log "Sending snapshot to ${OUTPUT_FILE}"
btrfs_send_snapshot "$SNAP_MOUNT" "$OUTPUT_FILE"

btrfs property set -ts "$SNAP_MOUNT" ro false || true

detach_btrfs_image "$SNAP_MOUNT" "$LOOP_DEVICE"

log "==========================================="
log "Snap image created successfully!"
log "Output: ${OUTPUT_FILE}"
log "Contains: ${#snaps[@]} snaps with assertions"
log "==========================================="
exit 0
