#!/usr/bin/env bash
set -e
BASE_DIR=$(readlink -f $(dirname $0))
[[ -z "$TEST_DIR" ]] && TEST_DIR="$(cd $BASE_DIR/../../../../ && pwd)"
[[ -z "$COMMON_DIR" ]] && COMMON_DIR="$(cd $BASE_DIR/../common && pwd)"

. $COMMON_DIR/common.sh
rpc_py="python $SPDK_BUILD_DIR/scripts/rpc.py "

vm_count=1
max_disks=""
ctrl_type="vhost_scsi"
use_fs=false
nested_lvol=false
distribute_cores=false

function usage()
{
    [[ ! -z $2 ]] && ( echo "$2"; echo ""; )
    echo "Shortcut script for doing automated test"
    echo "Usage: $(basename $1) [OPTIONS]"
    echo
    echo "-h, --help                Print help and exit"
    echo "    --fio-bin=PATH        Path to FIO binary.;"
    echo "    --vm-count=INT        Virtual machines to use in test;"
    echo "                          Each VM will get one lvol bdev on each NVMe."
    echo "                          Default: 1"
    echo "    --max-disks=INT       Maximum number of NVMe drives to use in test."
    echo "                          Default: will use all available NVMes."
    echo "    --ctrl-type=TYPE      Controller type to use for test:"
    echo "                          vhost_scsi - use spdk vhost scsi"
    echo "                          vhost_blk - use spdk vhost block"
    echo "    --nested-lvol         If enabled will create additional lvol bdev"
    echo "                          on each NVMe for use as base device for next"
    echo "                          lvol store and lvol bdevs."
    echo "                          (NVMe->lvol_store->lvol_bdev->lvol_store->lvol_bdev)"
    echo "                          Default: False"
    echo "-x                        set -x for script debug"
    echo "    --distribute-cores    Use custom config file and run vhost controllers"
    echo "                          on different CPU cores instead of single core."
    echo "                          Default: False"
    exit 0
}

function clean_lvol_cfg()
{
    echo "INFO: Removing nested lvol bdevs"
    for lvol_bdev in "${nest_lvol_bdevs[@]}"; do
        $rpc_py delete_bdev $lvol_bdev
        echo -e "\tINFO: nested lvol bdev $lvol_bdev removed"
    done

    echo "INFO: Removing nested lvol stores"
    for lvol_store in "${nest_lvol_stores[@]}"; do
        $rpc_py destroy_lvol_store -u $lvol_store
        echo -e "\tINFO: nested lvol store $lvol_store removed"
    done

    echo "INFO: Removing lvol bdevs"
    for lvol_bdev in "${lvol_bdevs[@]}"; do
        $rpc_py delete_bdev $lvol_bdev
        echo -e "\tINFO: lvol bdev $lvol_bdev removed"
    done

    echo "INFO: Removing lvol stores"
    for lvol_store in "${lvol_stores[@]}"; do
        $rpc_py destroy_lvol_store -u $lvol_store
        echo -e "\tINFO: lvol store $lvol_store removed"
    done
}

while getopts 'xh-:' optchar; do
    case "$optchar" in
        -)
        case "$OPTARG" in
            help) usage $0 ;;
            fio-bin=*) fio_bin="--fio-bin=${OPTARG#*=}" ;;
            vm-count=*) vm_count="${OPTARG#*=}" ;;
            max-disks=*) max_disks="${OPTARG#*=}" ;;
            ctrl-type=*) ctrl_type="${OPTARG#*=}" ;;
            nested-lvol) nested_lvol=true ;;
            distribute-cores) distribute_cores=true ;;
            *) usage $0 "Invalid argument '$OPTARG'" ;;
        esac
        ;;
    h) usage $0 ;;
    x) set -x
        x="-x" ;;
    *) usage $0 "Invalid argument '$OPTARG'"
    esac
done

echo "INFO: Get NVMe disks:"
nvmes=($(lspci -mm -n | grep 0108 | tr -d '"' | awk -F " " '{print "0000:"$1}'))

if [[ -z $max_disks ]]; then
    max_disks=${#nvmes[@]}
fi

if [[ ${#nvmes[@]} -lt max_disks ]]; then
    echo -e "ERROR: Number of NVMe drives (${#nvmes[@]})\n\
is lower than number of requested disks for test ($max_disks)"
    exit 1
fi

if $distribute_cores; then
    # FIXME: this need to be handled entirely in common.sh
    source $BASE_DIR/autotest.config
fi

trap 'error_exit "${FUNCNAME}" "${LINENO}"' SIGTERM SIGABRT ERR

vm_kill_all

echo "INFO: running SPDK"
echo ""
$COMMON_DIR/run_vhost.sh $x --work-dir=$TEST_DIR --conf-dir=$BASE_DIR
echo ""

trap 'clean_lvol_cfg; error_exit "${FUNCNAME}" "${LINENO}"' SIGTERM SIGABRT ERR

lvol_stores=()
lvol_bdevs=()
nest_lvol_stores=()
nest_lvol_bdevs=()
used_vms=""

# On each NVMe create one lvol store
for (( i=0; i<$max_disks; i++ ));do

    # Create base lvol store on NVMe
    echo "INFO: Creating lvol store on device Nvme${i}n1"
    ls_guid=$($rpc_py construct_lvol_store Nvme${i}n1 lvs_$i)
    lvol_stores+=("$ls_guid")

    if $nested_lvol; then
        free_mb=$(get_lvs_free_mb "$ls_guid")
        size=$((free_mb / (vm_count+1) ))

        echo "INFO: Creating lvol bdev on lvol store: $ls_guid"
        lb_name=$($rpc_py construct_lvol_bdev -u $ls_guid lbd_nest $size)

        echo "INFO: Creating nested lvol store on lvol bdev: $lb_name"
        nest_ls_guid=$($rpc_py construct_lvol_store $lb_name lvs_n_$i)
        nest_lvol_stores+=("$nest_ls_guid")

        for (( j=0; j<$vm_count; j++)); do
            echo "INFO: Creating nested lvol bdev for VM $i on lvol store $nest_ls_guid"
            free_mb=$(get_lvs_free_mb "$nest_ls_guid")
            nest_size=$((free_mb / (vm_count-j) ))
            lb_name=$($rpc_py construct_lvol_bdev -u $nest_ls_guid lbd_vm_$j $nest_size)
            nest_lvol_bdevs+=("$lb_name")
        done
    fi

    # Create base lvol bdevs
    for (( j=0; j<$vm_count; j++)); do
        echo "INFO: Creating lvol bdev for VM $i on lvol store $ls_guid"
        free_mb=$(get_lvs_free_mb "$ls_guid")
        size=$((free_mb / (vm_count-j) ))
        lb_name=$($rpc_py construct_lvol_bdev -u $ls_guid lbd_vm_$j $size)
        lvol_bdevs+=("$lb_name")
    done
done

bdev_info=$($rpc_py get_bdevs)
echo "INFO: Configuration after initial set-up:"
$rpc_py get_lvol_stores
echo "$bdev_info"

# Set up VMs
for (( i=0; i<$vm_count; i++)); do
    vm="vm_$i"

    # Get all lvol bdevs associated with this VM number
    bdevs=$(jq -r "map(select(.product_name==\"Logical Volume\") |
        select(.name | contains(\"$vm\")) | .name) | join(\" \")" <<< "$bdev_info")
    bdevs=($bdevs)

    setup_cmd="$COMMON_DIR/vm_setup.sh $x --work-dir=$TEST_DIR"
    if [[ "$ctrl_type" == "vhost_scsi" ]]; then
        setup_cmd+=" --test-type=spdk_vhost_scsi"
    elif [[ "$ctrl_type" == "vhost_blk" ]]; then
        setup_cmd+=" --test-type=spdk_vhost_blk"
    fi
    setup_cmd+=" -f $i"
    setup_cmd+=" --os=/home/sys_sgsw/vhost_vm_image.qcow2"

    # Create single SCSI controller or multiple BLK controllers for this VM
    if $distribute_cores; then
        mask="VM_${i}_qemu_mask"
        mask_arg="--cpumask ${!mask}"
    fi

    if [[ "$ctrl_type" == "vhost_scsi" ]]; then
        $rpc_py construct_vhost_scsi_controller naa.0.$i $mask_arg
        for (( j=0; j<${#bdevs[@]}; j++)); do
            $rpc_py add_vhost_scsi_lun naa.0.$i $j ${bdevs[$j]}
        done
        setup_cmd+=" --disk=0"
    elif [[ "$ctrl_type" == "vhost_blk" ]]; then
        disk=""
        for (( j=0; j<${#bdevs[@]}; j++)); do
            blk_dev_size=$(get_bdev_size "${bdevs[$j]}")

            $rpc_py construct_vhost_blk_controller naa.$j.$i ${bdevs[$j]} $mask_arg
            disk+="${j}_size_${blk_dev_size}M:"
        done
        disk="${disk::-1}"
        setup_cmd+=" --disk=$disk"
    fi

    $setup_cmd
    used_vms+=" $i"
done

$rpc_py get_vhost_controllers
$rpc_py get_luns

# Run VMs
$COMMON_DIR/vm_run.sh $x --work-dir=$TEST_DIR $used_vms
vm_wait_for_boot 600 $used_vms

# Get disk names from VMs and run FIO traffic

fio_disks=""
for vm_num in $used_vms; do
    vm_dir=$VM_BASE_DIR/$vm_num
    qemu_mask_param="VM_${vm_num}_qemu_mask"

    host_name="VM-$vm_num-${!qemu_mask_param}"
    vm_ssh $vm_num "hostname $host_name"
    vm_start_fio_server $fio_bin $vm_num

    if [[ "$ctrl_type" == "vhost_scsi" ]]; then
        vm_check_scsi_location $vm_num
    elif [[ "$ctrl_type" == "vhost_blk" ]]; then
        vm_check_blk_location $vm_num
    fi

    fio_disks+=" --vm=${vm_num}$(printf ':/dev/%s' $SCSI_DISK)"
done

# Run FIO traffic
run_fio $fio_bin --job-file=$COMMON_DIR/fio_jobs/default_integrity.job --out="$TEST_DIR/fio_results" $fio_disks

echo "INFO: Shutting down virtual machines..."
vm_shutdown_all
sleep 2

echo "INFO: Cleaning up vhost - remove LUNs, controllers, lvol bdevs and lvol stores"
if [[ "$ctrl_type" == "vhost_scsi" ]]; then
    for (( i=0; i<$vm_count; i++)); do
        echo "INFO: Removing devices from vhost SCSI controller naa.0.$i"
        for (( j=0; j<${#bdevs[@]}; j++)); do
            $rpc_py remove_vhost_scsi_target naa.0.$i $j
            echo -e "\tINFO: Removed device $j"
        done
        echo "Removing vhost SCSI controller naa.0.$i"
        $rpc_py remove_vhost_controller naa.0.$i
    done
elif [[ "$ctrl_type" == "vhost_blk" ]]; then
    for (( i=0; i<$vm_count; i++)); do
        for (( j=0; j<${#bdevs[@]}; j++)); do
            echo "INFO: Removing vhost BLK controller naa.$j.$i"
            $rpc_py remove_vhost_controller naa.$j.$i
            echo -e "\tINFO: Removed naa.$j.$i"
        done
    done
fi

clean_lvol_cfg

$rpc_py get_lvol_stores
$rpc_py get_bdevs
$rpc_py get_vhost_controllers
$rpc_py get_luns

echo "INFO: Shutting down SPDK vhost app..."
spdk_vhost_kill
