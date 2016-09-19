#
# Removes source after build
#
# To use it add that line to conf/local.conf:
#
# INHERIT += "rm_work"
#
# To inhibit rm_work for some recipes, specify them in RM_WORK_EXCLUDE.
# For example, in conf/local.conf:
#
# RM_WORK_EXCLUDE += "icu-native icu busybox"
#

# Use the completion scheduler by default when rm_work is active
# to try and reduce disk usage
BB_SCHEDULER ?= "completion"

# Run the rm_work task in the idle scheduling class
BB_TASK_IONICE_LEVEL_task-rm_work = "3.0"

do_rm_work () {
    # If the recipe name is in the RM_WORK_EXCLUDE, skip the recipe.
    for p in ${RM_WORK_EXCLUDE}; do
        if [ "$p" = "${PN}" ]; then
            bbnote "rm_work: Skipping ${PN} since it is in RM_WORK_EXCLUDE"
            exit 0
        fi
    done

    cd ${WORKDIR}
    for dir in *
    do
        # Retain only logs and other files in temp, safely ignore
        # failures of removing pseudo folers on NFS2/3 server.
        if [ $dir = 'pseudo' ]; then
            rm -rf $dir 2> /dev/null || true
        elif [ $dir != 'temp' ]; then
            rm -rf $dir
        fi
    done

    # Need to add pseudo back or subsqeuent work in this workdir
    # might fail since setscene may not rerun to recreate it
    mkdir -p ${WORKDIR}/pseudo/

    # Change normal stamps into setscene stamps as they better reflect the
    # fact WORKDIR is now empty
    # Also leave noexec stamps since setscene stamps don't cover them
    cd `dirname ${STAMP}`
    for i in `basename ${STAMP}`*
    do
        for j in ${SSTATETASKS} do_shared_workdir
        do
            case $i in
            *do_setscene*)
                break
                ;;
            *sigdata*|*sigbasedata*)
                i=dummy
                break
                ;;
            *do_package_write*)
                i=dummy
                break
                ;;
            *do_rootfs*|*do_image*|*do_bootimg*|*do_bootdirectdisk*|*do_vmimg*)
                i=dummy
                break
                ;;
            *do_build*)
                i=dummy
                break
                ;;
            # We remove do_package entirely, including any
            # sstate version since otherwise we'd need to leave 'plaindirs' around
            # such as 'packages' and 'packages-split' and these can be large. No end
            # of chain tasks depend directly on do_package anymore.
            *do_package|*do_package.*|*do_package_setscene.*)
                rm -f $i;
                i=dummy
                break
                ;;
            *_setscene*)
                i=dummy
                break
                ;;
            *$j|*$j.*)
                mv $i `echo $i | sed -e "s#${j}#${j}_setscene#"`
                i=dummy
                break
            ;;
            esac
        done
        rm -f $i
    done
}

do_populate_sdk[postfuncs] += "rm_work_populatesdk"
rm_work_populatesdk () {
    :
}
rm_work_populatesdk[cleandirs] = "${WORKDIR}/sdk"

do_image_complete[postfuncs] += "rm_work_rootfs"
rm_work_rootfs () {
    :
}
rm_work_rootfs[cleandirs] = "${WORKDIR}/rootfs"

python () {
    if bb.data.inherits_class('kernel', d):
        d.appendVar("RM_WORK_EXCLUDE", ' ' + d.getVar("PN", True))
    # If the recipe name is in the RM_WORK_EXCLUDE, skip the recipe.
    excludes = (d.getVar("RM_WORK_EXCLUDE", True) or "").split()
    pn = d.getVar("PN", True)
    if pn in excludes:
        d.delVarFlag('rm_work_rootfs', 'cleandirs')
        d.delVarFlag('rm_work_populatesdk', 'cleandirs')
    else:
        # Inject do_rm_work into the tasks of the current recipe such that do_build
        # depends on it and that it runs after all other tasks that block do_build,
        # i.e. after all work on the current recipe is done. do_build inherits
        # additional runtime dependencies on other recipes and thus will typically
        # run later.
        #
        # This approach ensures that do_rm_work runs as soon as possible. The downside
        # is the non-deterministic execution of anonymous python functions: if some
        # other function runs after us and makes further changes to tasks, we will
        # miss those changes. TODO: is there a better solution?
        #
        # TODO: is the 'deps' varflag part of the public API, i.e. can we rely upon it here?
        deps = d.getVarFlag('do_build', 'deps', True)
        # Packaging classes add tasks, and due to ordering we do indeed miss those
        # tasks. INHERIT_append in local.conf did not help?
        deps.extend(['do_package_write_rpm', 'do_package_write_ipk', 'do_package_write_deb'])
        bb.build.addtask('do_rm_work', 'do_build', ' '.join(deps), d)
}
