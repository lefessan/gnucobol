# IBM TXSeries with GnuCOBOL as the compiler and runtime of its COBOL
# language method for CobolCloud (COBCLD), see README.md.
#
# In a directory with this file and a distribution of GnuCOBOL
# (make dist):
#
#   docker build --build-arg GNUCOBOL_DIST=gnucobol-4.0-early-dev.tar.gz \
#       -t txseries-gnucobol .
#
# TXSERIES_IMAGE: the TXSeries image loaded from IBM (docker load).

ARG TXSERIES_IMAGE=localhost/ibm-txseries-trial:11.1.0.0
FROM ${TXSERIES_IMAGE}

ARG GNUCOBOL_DIST=gnucobol.tar.gz

USER root

# compiler and libraries (UBI 8 repositories)
RUN microdnf --disablerepo="*" --enablerepo=ubi-8-baseos-rpms \
      --enablerepo=ubi-8-appstream-rpms \
      install -y gcc make gmp-devel diffutils findutils tar gzip \
 && microdnf clean all

# GnuCOBOL in /opt/gnucobol, then libcobcld
COPY ${GNUCOBOL_DIST} /tmp/gnucobol.tar.gz
RUN mkdir /tmp/gnucobol \
 && tar xzf /tmp/gnucobol.tar.gz --strip-components=1 -C /tmp/gnucobol \
 && cd /tmp/gnucobol \
 && ./configure --prefix=/opt/gnucobol --disable-nls \
      --without-db --without-lmdb --without-xml2 --without-json \
      --without-curses > configure.log \
 && { make -j"$(nproc)" > make.log 2>&1 || { tail -30 make.log; exit 1; }; } \
 && make install > install.log \
 && make -C txseries COB_CONFIG=/opt/gnucobol/bin/cob-config \
 && make -C txseries COB_CONFIG=/opt/gnucobol/bin/cob-config install \
 && echo /opt/gnucobol/lib > /etc/ld.so.conf.d/gnucobol.conf && ldconfig \
 && cd / && rm -rf /tmp/gnucobol /tmp/gnucobol.tar.gz

ENV PATH=${PATH}:/opt/gnucobol/bin

# the COBCLD language method of TXSeries, linked with libcobcld
RUN COBOLCLDIR=/opt/gnucobol cicsmkcobcld -o ${CICSPATH}/bin \
 && chown cics:cics ${CICSPATH}/bin/cicsprCOBCLD

# options of cobc for cicstcl -lCOBCLD
ENV CICS_COBCLD_CCFLAGS="-std=txseries -Wno-goto-section -Wno-goto-different-section"

USER cics:cics
