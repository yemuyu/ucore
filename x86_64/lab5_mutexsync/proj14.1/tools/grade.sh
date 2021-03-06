#!/bin/sh

verbose=false
if [ "x$1" = "x-v" ]; then
    verbose=true
    out=/dev/stdout
    err=/dev/stderr
else
    out=/dev/null
    err=/dev/null
fi

## make & makeopts
if gmake --version > /dev/null 2>&1; then
    make=gmake;
else
    make=make;
fi

makeopts="--quiet --no-print-directory -j"

make_print() {
    echo `$make $makeopts print-$1`
}

## command tools
awk='awk'
bc='bc'
date='date'
grep='grep'
rm='rm -f'
sed='sed'

## symbol table
sym_table='obj/kernel.sym'

## gdb & gdbopts
gdb="$(make_print GDB)"
gdbport='1234'

gdb_in="$(make_print GRADE_GDB_IN)"

## qemu & qemuopts
qemu="$(make_print qemu)"

qemu_out="$(make_print GRADE_QEMU_OUT)"

if $qemu -nographic -help | grep -q '^-gdb'; then
    qemugdb="-gdb tcp::$gdbport"
else
    qemugdb="-s -p $gdbport"
fi

## default variables
default_timeout=30
default_pts=5

pts=5
part=0
part_pos=0
total=0
total_pos=0

## default functions
update_score() {
    total=`expr $total + $part`
    total_pos=`expr $total_pos + $part_pos`
    part=0
    part_pos=0
}

get_time() {
    echo `$date +%s.%N 2> /dev/null`
}

show_part() {
    echo "Part $1 Score: $part/$part_pos"
    echo
    update_score
}

show_final() {
    update_score
    echo "Total Score: $total/$total_pos"
    if [ $total -lt $total_pos ]; then
        exit 1
    fi
}

show_time() {
    t1=$(get_time)
    time=`echo "scale=1; ($t1-$t0)/1" | $sed 's/.N/.0/g' | $bc 2> /dev/null`
    echo "(${time}s)"
}

show_build_tag() {
    echo "$1:" | $awk '{printf "%-24s ", $0}'
}

show_check_tag() {
    echo "$1:" | $awk '{printf "  -%-40s  ", $0}'
}

show_msg() {
    echo $1
    shift
    if [ $# -gt 0 ]; then
        echo "$@" | awk '{printf "   %s\n", $0}'
        echo
    fi
}

pass() {
    show_msg OK "$@"
    part=`expr $part + $pts`
    part_pos=`expr $part_pos + $pts`
}

fail() {
    show_msg WRONG "$@"
    part_pos=`expr $part_pos + $pts`
}

run_qemu() {
    # Run qemu with serial output redirected to $qemu_out. If $brkfun is non-empty,
    # wait until $brkfun is reached or $timeout expires, then kill QEMU
    qemuextra=
    if [ "$brkfun" ]; then
        qemuextra="-S $qemugdb"
    fi

    if [ -z "$timeout" ] || [ $timeout -le 0 ]; then
        timeout=$default_timeout;
    fi

    t0=$(get_time)
    (
        ulimit -t $timeout
        exec $qemu -nographic $qemuopts -serial file:$qemu_out -monitor null -no-reboot $qemuextra
    ) > $out 2> $err &
    pid=$!

    # wait for QEMU to start
    sleep 1

    if [ -n "$brkfun" ]; then
        # find the address of the kernel $brkfun function
        brkaddr=`$grep " $brkfun\$" $sym_table | $sed -e's/ .*$//g'`
        (
            echo "target remote localhost:$gdbport"
            echo "set architecture i386:x86-64:intel"
            echo "break *0x$brkaddr"
            echo "continue"
        ) > $gdb_in

        $gdb -batch -nx -x $gdb_in > /dev/null 2>&1

        # make sure that QEMU is dead
        # on OS X, exiting gdb doesn't always exit qemu
        kill $pid > /dev/null 2>&1
    fi
}

build_run() {
    # usage: build_run <tag> <args>
    show_build_tag "$1"
    shift

    if $verbose; then
        echo "$make $@ ..."
    fi
    $make $makeopts $@ 'DEFS+=-DDEBUG_GRADE' > $out 2> $err

    if [ $? -ne 0 ]; then
        echo $make $@ failed
        exit 1
    fi

    # now run qemu and save the output
    run_qemu

    show_time
}

check_result() {
    # usage: check_result <tag> <check> <check args...>
    show_check_tag "$1"
    shift

    # give qemu some time to run (for asynchronous mode)
    if [ ! -s $qemu_out ]; then
        sleep 4
    fi

    if [ ! -s $qemu_out ]; then
        fail > /dev/null
        echo 'no $qemu_out'
    else
        check=$1
        shift
        $check "$@"
    fi
}

check_regexps() {
    okay=yes
    not=0
    reg=0
    error=
    for i do
        if [ "x$i" = "x!" ]; then
            not=1
        elif [ "x$i" = "x-" ]; then
            reg=1
        else
            if [ $reg -ne 0 ]; then
                $grep '-E' "^$i\$" $qemu_out > /dev/null
            else
                $grep '-F' "$i" $qemu_out > /dev/null
            fi
            found=$(($? == 0))
            if [ $found -eq $not ]; then
                if [ $found -eq 0 ]; then
                    msg="!! error: missing '$i'"
                else
                    msg="!! error: got unexpected line '$i'"
                fi
                okay=no
                if [ -z "$error" ]; then
                    error="$msg"
                else
                    error="$error\n$msg"
                fi
            fi
            not=0
            reg=0
        fi
    done
    if [ "$okay" = "yes" ]; then
        pass
    else
        fail "$error"
        if $verbose; then
            exit 1
        fi
    fi
}

run_test() {
    # usage: run_test [-tag <tag>] [-prog <prog>] [-Ddef...] [-check <check>] checkargs ...
    tag=
    prog=
    check=check_regexps
    while true; do
        select=
        case $1 in
            -tag|-prog)
                select=`expr substr $1 2 ${#1}`
                eval $select='$2'
                ;;
        esac
        if [ -z "$select" ]; then
            break
        fi
        shift
        shift
    done
    defs=
    while expr "x$1" : "x-D.*" > /dev/null; do
        defs="DEFS+='$1' $defs"
        shift
    done
    if [ "x$1" = "x-check" ]; then
        check=$2
        shift
        shift
    fi

    if [ -z "$prog" ]; then
        $make $makeopts touch > /dev/null 2>&1
        args="$defs"
    else
        if [ -z "$tag" ]; then
            tag="$prog"
        fi
        args="build-$prog $defs"
    fi

    build_run "$tag" "$args"

    check_result 'check result' "$check" "$@"
}

quick_run() {
    # usage: quick_run <tag> [-Ddef...]
    tag="$1"
    shift
    defs=
    while expr "x$1" : "x-D.*" > /dev/null; do
        defs="DEFS+='$1' $defs"
        shift
    done

    $make $makeopts touch > /dev/null 2>&1
    build_run "$tag" "$defs"
}

quick_check() {
    # usage: quick_check <tag> checkargs ...
    tag="$1"
    shift
    check_result "$tag" check_regexps "$@"
}

## kernel image
osimg=$(make_print ucoreimg)

## swap image
swapimg=$(make_print swapimg)

## set default qemu-options
qemuopts="-m 256m -hda $osimg -drive file=$swapimg,media=disk,cache=writeback"

## set break-function, default is readline
brkfun=readline

default_check() {
    pts=7
    check_regexps "$@"

    pts=3
    quick_check 'check output'                                                  \
        'check_alloc_page() succeeded!'                                         \
        'check_boot_pgdir() succeeded!'                                         \
        'check_slab() succeeded!'                                               \
        'check_vma_struct() succeeded!'                                         \
        'check_pgfault() succeeded!'                                            \
        'check_vmm() succeeded.'                                                \
        'check_swap() succeeded.'                                               \
        'check_mm_swap: step1, mm_map ok.'                                      \
        'check_mm_swap: step2, mm_unmap ok.'                                    \
        'check_mm_swap: step3, exit_mmap ok.'                                   \
        'check_mm_swap: step4, dup_mmap ok.'                                    \
        'check_mm_swap() succeeded.'                                            \
        'check_mm_shm_swap: step1, share memory ok.'                            \
        'check_mm_shm_swap: step2, dup_mmap ok.'                                \
        'check_mm_shm_swap() succeeded.'                                        \
        '++ setup timer interrupts'
}

## check now!!

run_test -prog 'semtest' -check default_check                                   \
        'kernel_execve: pid = 3, name = "semtest".'                             \
      - 'sem_id = 0x................'                                           \
        'post ok.'                                                              \
        'wait ok.'                                                              \
        'wait semaphore...'                                                     \
        'sleep 0'                                                               \
        'sleep 1'                                                               \
        'sleep 2'                                                               \
        'sleep 3'                                                               \
        'sleep 4'                                                               \
        'sleep 5'                                                               \
        'sleep 6'                                                               \
        'sleep 7'                                                               \
        'sleep 8'                                                               \
        'sleep 9'                                                               \
        'hold semaphore.'                                                       \
        'fork pass.'                                                            \
        'semtest pass.'                                                         \
        'all user-mode processes have quit.'                                    \
        'init check memory pass.'                                               \
    ! - 'user panic at .*'

run_test -prog 'semtest2' -check default_check                                  \
        'kernel_execve: pid = 3, name = "semtest2".'                            \
        'semtest2 test1:'                                                       \
        'child start 0.'                                                        \
        'child end.'                                                            \
        'parent start 0.'                                                       \
        'parent end.'                                                           \
        'child start 1.'                                                        \
        'child end.'                                                            \
        'parent start 1.'                                                       \
        'parent end.'                                                           \
        'child start 2.'                                                        \
        'child end.'                                                            \
        'child exit.'                                                           \
        'parent start 2.'                                                       \
        'parent end.'                                                           \
        'semtest2 test2:'                                                       \
        'child 0'                                                               \
        'parent 0'                                                              \
        'child 1'                                                               \
        'parent 1'                                                              \
        'child 2'                                                               \
        'parent 2'                                                              \
        'semtest2 pass.'                                                        \
        'all user-mode processes have quit.'                                    \
        'init check memory pass.'                                               \
    ! - 'user panic at .*'

run_test -prog 'spipetest' -check default_check                                 \
        'kernel_execve: pid = 3, name = "spipetest".'                           \
        'child write ok'                                                        \
        'parent read ok'                                                        \
        'spipetest pass'                                                        \
        'all user-mode processes have quit.'                                    \
        'init check memory pass.'                                               \
    ! - 'user panic at .*'

pts=20
timeout=240

run_test -prog 'spipetest2'                                                     \
        'kernel_execve: pid = 3, name = "spipetest2".'                          \
        '0 reads 200000'                                                        \
        '1 reads 200000'                                                        \
        '2 reads 200000'                                                        \
        '3 reads 200000'                                                        \
        '4 reads 200000'                                                        \
        '5 reads 200000'                                                        \
        '6 reads 200000'                                                        \
        '7 reads 200000'                                                        \
        '8 reads 200000'                                                        \
        '9 reads 200000'                                                        \
        'spipetest2 pass.'                                                      \
        'all user-mode processes have quit.'                                    \
        'init check memory pass.'                                               \
    !   'pipe is closed, too early.'                                            \
    !   'spipe close failed.'                                                   \
    ! - 'user panic at .*'

pts=30
timeout=500

run_test -prog 'primer2'                                                        \
        'kernel_execve: pid = 3, name = "primer2".'                             \
        'sharemem init ok.'                                                     \
        '5 is a primer.'                                                        \
        '71 is a primer.'                                                       \
        '223 is a primer.'                                                      \
        '409 is a primer.'                                                      \
        '601 is a primer.'                                                      \
        '881 is a primer.'                                                      \
        '1163 is a primer.'                                                     \
        '1451 is a primer.'                                                     \
        '1733 is a primer.'                                                     \
        '2069 is a primer.'                                                     \
        '2383 is a primer.'                                                     \
        '2729 is a primer.'                                                     \
        '3079 is a primer.'                                                     \
        '3413 is a primer.'                                                     \
        '3767 is a primer.'                                                     \
        '4219 is a primer.'                                                     \
        '4561 is a primer.'                                                     \
        '4937 is a primer.'                                                     \
        '5387 is a primer.'                                                     \
        '5779 is a primer.'                                                     \
        '6247 is a primer.'                                                     \
        '6659 is a primer.'                                                     \
        '7069 is a primer.'                                                     \
        '7529 is a primer.'                                                     \
      - '...... 7 quit.'                                                        \
      - '...... 23 quit.'                                                       \
      - '...... 43 quit.'                                                       \
      - '...... 67 quit.'                                                       \
      - '...... 89 quit.'                                                       \
      - '...... 109 quit.'                                                      \
      - '...... 139 quit.'                                                      \
      - '...... 167 quit.'                                                      \
      - '...... 193 quit.'                                                      \
      - '...... 227 quit.'                                                      \
      - '...... 251 quit.'                                                      \
      - '...... 277 quit.'                                                      \
      - '...... 311 quit.'                                                      \
      - '...... 347 quit.'                                                      \
      - '...... 373 quit.'                                                      \
      - '...... 401 quit.'                                                      \
      - '...... 433 quit.'                                                      \
      - '...... 461 quit.'                                                      \
      - '...... 491 quit.'                                                      \
      - '...... 523 quit.'                                                      \
      - '...... 569 quit.'                                                      \
      - '...... 599 quit.'                                                      \
      - '...... 619 quit.'                                                      \
      - '...... 653 quit.'                                                      \
      - '...... 683 quit.'                                                      \
      - '...... 727 quit.'                                                      \
      - '...... 757 quit.'                                                      \
      - '...... 797 quit.'                                                      \
      - '...... 827 quit.'                                                      \
      - '...... 859 quit.'                                                      \
      - '...... 887 quit.'                                                      \
      - '...... 937 quit.'                                                      \
      - '...... 971 quit.'                                                      \
        'primer2 pass.'                                                         \
        'all user-mode processes have quit.'                                    \
        'init check memory pass.'                                               \
    ! - 'user panic at .*'

## print final-score
show_final

