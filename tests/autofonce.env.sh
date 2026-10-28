# look at 'build_anchors' to see how the build dir is detected among upper dirs

abs_builddir=${AUTOFONCE_BUILD_DIR}/tests

# these files are generated during configure or first `make check`

. ${abs_builddir}/atconfig
. ${abs_builddir}/atlocal

# test env by AF_ENV

