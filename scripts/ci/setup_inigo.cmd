$ErrorActionPreference = "Stop";
trap { $host.SetShouldExit(1) }

$env:TMP_HOME=($pwd).path
$env:GOROOT="C:\\go"
$env:PATH= "$env:GOROOT/bin;$env:PATH"

rem # Setup DNS for *.service.cf.internal, used by the Diego components, and
rem # *.test.internal, used by the collocated DUSTs as a routable domain.
rem function setup_dnsmasq() {
rem   local host_addr
rem   host_addr=$(ip route get 8.8.8.8 | head -n1 | awk '{print $NF}')
rem
rem   dnsmasq --address=/service.cf.internal/127.0.0.1 --address=/test.internal/${host_addr}
rem   echo -e "nameserver $host_addr\n$(cat /etc/resolv.conf)" > /etc/resolv.conf
rem }

push-location garden-runc-release
  # Upstream garden-runc-release switched to go-modules
  # We still use GOPATH, so move guardian accordingly
  mkdir ./src/gopath/src/code.cloudfoundry.org -ea 0
  if (Test-Path ./src/guardian) {
    mv ./src/guardian ./src/gopath/src/code.cloudfoundry.org/
  }
  go build -o gdn.exe ./src/gopath/src/code.cloudfoundry.org/guardian/cmd/gdn
  if ($LastExitCode -ne 0) {
      throw "Building gdn.exe process returned error code: $LastExitCode"
  }

  # Kill any existing garden servers
  Kill-Garden

  $depotDir = "$env:TEMP\depot"
  Remove-Item -Recurse -Force -ErrorAction Ignore $depotDir
  mkdir $depotDir -Force

  $env:GARDEN_ADDRESS = "127.0.0.1"
  $env:GARDEN_PORT = "8888"

  $tarBin = (get-command tar.exe).source

  Start-Process `
    -NoNewWindow `
    -RedirectStandardOutput gdn.out.log `
    -RedirectStandardError gdn.err.log `
    .\gdn.exe -ArgumentList `
    "server `
    --skip-setup `
    --runtime-plugin=$wincPath `
    --image-plugin=$grootBinary `
    --image-plugin-extra-arg=--driver-store=$grootImageStore `
    --image-plugin-extra-arg=--config=$grootConfigPath `
    --network-plugin=$wincNetworkPath `
    --network-plugin-extra-arg=--configFile=$env:TEMP/interface.json `
    --network-plugin-extra-arg=--log=winc-network.log `
    --network-plugin-extra-arg=--debug `
    --bind-ip=$env:GARDEN_ADDRESS `
    --bind-port=$env:GARDEN_PORT `
    --default-rootfs=$env:WINC_TEST_ROOTFS `
    --nstar-bin=$nstarPath `
    --tar-bin=$tarBin `
    --init-bin=$gardenInitBinary `
    --depot $depotDir `
    --log-level=debug"

  # wait for server to start up
  # and then curl to confirm that it is
  Start-Sleep -s 5
  $pingResult = (curl -UseBasicParsing "http://${env:GARDEN_ADDRESS}:${env:GARDEN_PORT}/ping").StatusCode
  if ($pingResult -ne 200) {
      throw "Pinging garden server failed with code: $pingResult"
  }

  $env:GARDEN_TEST_ROOTFS="$env:WINC_TEST_ROOTFS"
  $env:WINC_BINARY="$wincPath"
  $env:GROOT_BINARY="$grootBinary"
  $env:GROOT_IMAGE_STORE="$grootImageStore"
  Push-Location src/garden-integration-tests
    ginkgo -p -randomizeSuites -noisyPendings=false
  Pop-Location
Pop-Location

create_garden_storage() {
  # Configure cgroup
  mount -t tmpfs cgroup_root /sys/fs/cgroup
  mkdir -p /sys/fs/cgroup/devices
  mkdir -p /sys/fs/cgroup/memory

  mount -tcgroup -odevices cgroup:devices /sys/fs/cgroup/devices
  devices_mount_info=$(cat /proc/self/cgroup | grep devices)
  devices_subdir=$(echo $devices_mount_info | cut -d: -f3)

  # change permission to allow us to run mknod later
  echo 'b 7:* rwm' > /sys/fs/cgroup/devices/devices.allow
  echo 'b 7:* rwm' > /sys/fs/cgroup/devices${devices_subdir}/devices.allow

  # Setup loop devices
  for i in {0..256}
  do
    rm -f /dev/loop$i
    mknod -m777 /dev/loop$i b 7 $i
  done

  # Make XFS volume
  truncate -s 8G /xfs_volume
  mkfs.xfs -b size=4096 /xfs_volume

  # Mount XFS
  mkdir /mnt/garden-storage
  mount -t xfs -o pquota,noatime,nobarrier /xfs_volume /mnt/garden-storage
  chmod 777 -R /mnt/garden-storage

  umount /sys/fs/cgroup/devices
}

build_grootfs () {
  echo "Building grootfs..."
  export GARDEN_RUNC_PATH=${PWD}/garden-runc-release
  export GROOTFS_BINPATH=${GARDEN_RUNC_PATH}/bin
  mkdir -p ${GROOTFS_BINPATH}

  pushd ${GARDEN_RUNC_PATH}/src/grootfs
    export PATH=${GROOTFS_BINPATH}:${PATH}

    # Set up btrfs volume and loopback devices in environment
    create_garden_storage
    umount /sys/fs/cgroup

    make

    mv $PWD/build/grootfs $GROOTFS_BINPATH
    echo "grootfs installed."

    groupadd iamgroot -g 4294967294
    useradd iamgroot -u 4294967294 -g 4294967294
    echo "iamgroot:1:4294967293" > /etc/subuid
    echo "iamgroot:1:4294967293" > /etc/subgid
  popd
}

set_garden_rootfs () {
  # use the 1.29 version of tar that's installed in the inigo-ci docker image
  ln -sf /usr/local/bin/tar "${GARDEN_BINPATH}"

  tar cpf /tmp/rootfs.tar -C /opt/inigo/rootfs .
  export GARDEN_ROOTFS=/tmp/rootfs.tar
}

setup_gopath() {
  pushd $1

  bosh sync-blobs


  if [ -d "$1/blobs/proxy" ]; then
    mkdir /tmp/envoy
    tar -C /tmp/envoy -xf blobs/proxy/envoy*.tgz
    export ENVOY_PATH=/tmp/envoy
    chmod 777 $ENVOY_PATH
  fi

  export GOPATH_ROOT=$PWD

  export GOPATH=${GOPATH_ROOT}
  export PATH=${GOPATH_ROOT}/bin:${PATH}

  # install application dependencies
  echo "Installing go dependencies ..."
  for package in github.com/apcera/gnatsd; do
    go install $package
  done

  popd
}

install_ginkgo() {
  pushd $1
  go install github.com/onsi/ginkgo/ginkgo
  popd
}

setup_database() {
  orig_ca_file="${GOPATH_ROOT}/src/code.cloudfoundry.org/inigo/fixtures/certs/sql-certs/server-ca.crt"
  orig_cert_file="${GOPATH_ROOT}/src/code.cloudfoundry.org/inigo/fixtures/certs/sql-certs/server.crt"
  orig_key_file="${GOPATH_ROOT}/src/code.cloudfoundry.org/inigo/fixtures/certs/sql-certs/server.key"

  ca_file="/tmp/server-ca.crt"
  cert_file="/tmp/server.crt"
  key_file="/tmp/server.key"

  # do not chown/chmod files in the inigo repo that is annoying
  cp $orig_ca_file $ca_file
  cp $orig_cert_file $cert_file
  cp $orig_key_file $key_file

  chmod 0600 "$ca_file"
  chmod 0600 "$cert_file"
  chmod 0600 "$key_file"

  if [ "${SQL_FLAVOR}" = "mysql" ]; then
    source ${GOPATH_ROOT}/scripts/ci/initialize_mysql.sh

    sed -i 's/#max_connections.*= 100/max_connections = 2000/g' /etc/mysql/mysql.conf.d/mysqld.cnf

    chown mysql:mysql "$ca_file"
    chown mysql:mysql "$cert_file"
    chown mysql:mysql "$key_file"

    sed -i "s%# ssl-cert=/etc/mysql/server-cert.pem%ssl-cert=$cert_file%g" /etc/mysql/mysql.conf.d/mysqld.cnf
    sed -i "s%# ssl-key=/etc/mysql/server-key.pem%ssl-key=$key_file%g" /etc/mysql/mysql.conf.d/mysqld.cnf
    sed -i "s%# ssl-ca=/etc/mysql/cacert.pem%ssl-ca=$ca_file%g" /etc/mysql/mysql.conf.d/mysqld.cnf
    initialize_mysql
  else
    sed -i 's/max_connections = 100/max_connections = 2000/g' /etc/postgresql/9.4/main/postgresql.conf

    chown postgres:postgres "$ca_file"
    chown postgres:postgres "$cert_file"
    chown postgres:postgres "$key_file"

    sed -i 's/ssl = false/ssl = true/g' /etc/postgresql/9.4/main/postgresql.conf
    sed -i "s%ssl_cert_file = '/etc/ssl/certs/ssl-cert-snakeoil.pem'%ssl_cert_file = '$cert_file'%g" /etc/postgresql/9.4/main/postgresql.conf
    sed -i "s%ssl_key_file = '/etc/ssl/private/ssl-cert-snakeoil.key'%ssl_key_file = '$key_file'%g" /etc/postgresql/9.4/main/postgresql.conf
    sed -i "s%#ssl_ca_file = ''%ssl_ca_file = '$ca_file'%g" /etc/postgresql/9.4/main/postgresql.conf

    service postgresql start
  fi
}

rm -rf $PWD/diego-release/src/code.cloudfoundry.org/guardian/vendor/github.com/onsi/{ginkgo,gomega}

setup_dnsmasq

build_gardenrunc $PWD/garden-runc-release

build_grootfs

# setup v0 env vars for dusts-v2
if [ -d $PWD/diego-release-v0 ]; then
    setup_gopath $PWD/diego-release-v0
    export GOPATH_V0=${GOPATH_ROOT}
    export AUCTIONEER_GOPATH_V0=${GOPATH_ROOT}
    export BBS_GOPATH_V0=${GOPATH_ROOT}
    export HEALTHCHECK_GOPATH_V0=${GOPATH_ROOT}
    export REP_GOPATH_V0=${GOPATH_ROOT}
    export ROUTE_EMITTER_GOPATH_V0=${GOPATH_ROOT}
    export SSHD_GOPATH_V0=${GOPATH_ROOT}
    export SSH_PROXY_GOPATH_V0=${GOPATH_ROOT}
fi

export ROUTER_GOPATH="$PWD/routing-release"
export ROUTING_API_GOPATH=${ROUTER_GOPATH}

setup_gopath $PWD/diego-release
install_ginkgo $PWD/diego-release
set_garden_rootfs

export APP_LIFECYCLE_GOPATH=${GOPATH_ROOT}
export AUCTIONEER_GOPATH=${GOPATH_ROOT}
export BBS_GOPATH=${GOPATH_ROOT}
export FILE_SERVER_GOPATH=${GOPATH_ROOT}
export HEALTHCHECK_GOPATH=${GOPATH_ROOT}
export LOCKET_GOPATH=${GOPATH_ROOT}
export REP_GOPATH=${GOPATH_ROOT}
export ROUTE_EMITTER_GOPATH=${GOPATH_ROOT}
export SSHD_GOPATH=${GOPATH_ROOT}
export SSH_PROXY_GOPATH=${GOPATH_ROOT}
export GARDEN_GOPATH=${GOPATH_ROOT}

# used for routing to apps; same logic that Garden uses.
EXTERNAL_ADDRESS=$(ip route get 8.8.8.8 | sed 's/.*src\s\(.*\)\s/\1/;tx;d;:x')
export EXTERNAL_ADDRESS

setup_database

# display ginkgo dots properly
export LESSCHARSET=utf-8

export GARDEN_GRAPH_PATH=/tmp/aufs_mount
mkdir -p "${GARDEN_GRAPH_PATH}"
mount -t tmpfs tmpfs "${GARDEN_GRAPH_PATH}"

# workaround until Concourse's garden sets this up for us
if ! grep -qs '/sys' /proc/mounts; then
  mount -t sysfs sysfs /sys
fi

# shellcheck source=/dev/null
source "${GARDEN_RUNC_PATH}/ci/helpers/device-control"
permit_device_control
create_loop_devices 256
