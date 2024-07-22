#!/usr/bin/bash
# -----------------------------------------------------------------------------------------
#  Example Installation Script Template
#  This convenience script encapsulates command-line instructions highlighted in
#  an OpenHPC Install Guide that can be used as a starting point to perform a local
#  cluster install beginning with bare-metal. Necessary inputs that describe local
#  hardware characteristics, desired network settings, and other customizations
#  are controlled via a companion input file that is used to initialize variables
#  within this script.
#  Please see the OpenHPC Install Guide(s) for more information regarding the
#  procedure. Note that the section numbering included in this script refers to
#  corresponding sections from the companion install guide.
# -----------------------------------------------------------------------------------------

#inputFile=${OHPC_INPUT_LOCAL:-/opt/ohpc/pub/doc/recipes/centos8/input.local}
inputFile=${OHPC_INPUT_LOCAL:-./input.local}
if [ ! -e ${inputFile} ];then
   echo "Error: Unable to access local input file -> ${inputFile}"
   exit 1
else
   . ${inputFile} || { echo "Error sourcing ${inputFile}"; exit 1; }
fi

# ---------------------------- Begin OpenHPC Recipe ---------------------------------------
# Commands below are extracted from an OpenHPC install guide recipe and are intended for
# execution on the master SMS host.
# -----------------------------------------------------------------------------------------

# Disable firewall
systemctl disable firewalld
systemctl stop firewalld


# --------------------------------------
# Enable confluent repositories (Section 3.1)
# --------------------------------------
dnf -y install https://hpc.lenovo.com/yum/latest/el9/x86_64/lenovo-hpc-yum-1-1.x86_64.rpm

# ------------------------------------------------------------
# Add baseline OpenHPC and provisioning services (Section 3.2)
# ------------------------------------------------------------
dnf -y install lenovo-confluent confluent_osdeploy-x86_64 tftp-server

systemctl enable confluent --now
systemctl enable httpd --now
systemctl enable tftp.socket --now

# ------------------------------------------------
# ADD confluent bin to path
# ------------------------------------------------
PATH="$PATH:/opt/confluent/bin"

# ------------------------------------------------------
# Initialize OS images for use with confluent (Section 3.4.1)
# ------------------------------------------------------
# generate an ssh key before running this command
osdeploy initialize -$initialize_options
osdeploy import  ${iso_path}/Rocky-9.4-x86_64-dvd.iso

# add nodegroup addtribs
nodegroupattrib everything deployment.useinsecureprotocols=${deployment_protocols} console.method=${console_method} dns.domain=${dns_domain} dns.servers=${dns_servers}

# create compute nodegroup
nodegroupdefine compute


# Add hosts to cluster (Section 3.5)
for ((i=0; i<$num_computes; i++)) ; do
   nodedefine ${c_name[$i]} groups=everything,compute hardwaremanagement.manager=${c_bmc[$i]} secret.hardwaremanagementuser=$bmc_username secret.hardwaremanagementpassword=$bmc_password
   nodediscover assign -n ${c_name[$i]} -e ${c_bmac[$i]}  # this command works best with Lenovo systems but we can do without it. 
done
# Set default root password
#chtab key=system passwd.username=root passwd.password=`openssl rand -base64 12`



# Setup IPoIB networking
if [[ ${enable_ipoib} -eq 1 ]];then
     chdef -t network -o ib0 mask=$ipoib_netmask net=${c_ipoib[0]}
     chdef compute -p postbootscripts=confignics
     for ((i=0; i<$num_computes; i++)) ; do
        chdef ${c_name[i]} nicips.ib0=${c_ipoib[i]} nictypes.ib0="InfiniBand" nicnetworks.ib0=ib0
     done
fi

# Complete networking setup, Preparing name resolution
for ((i=0; i<$num_computes; i++)); do
     echo "${c_ip[$i]} ${c_name[$i]} ${c_name[$i]}.$dns_domain" >> /etc/hosts
done


# ----------------------------------------------------------------
# Have to make sure that name resolution is working 
# if name resolution is not working the deployment will not work
# -----------------------------------------------------------------
##dnf -y install dnsmasq
##systemctl enable dnsmasq --now

# Initiate os deployment over network to compute nodes
nodedeploy -n compute rocky-9.4-x86_64-default
# Need to have a way to wait for deployment to finish before proceeding

while true; do
    deployment_pending=false
    while read line; do
        dp=$(echo $line | cut -d ":" -f 2)
          if [ "$dp" == " pending" ];
          then
               deployment_pending=true
          fi
    done <<< `nodedeploy compute`
    if $deployment_pending;
     then
          echo "deployment still pending"
          deployment_pending=false
          sleep 20
          # look into finding out how long we have been waiting for os deployment to finish (maybe add a timeout)
     else
          break
     fi
done

# --------------------------------------------------------
# Download OHPC repo and create local mirror (Section 3.1)
# --------------------------------------------------------
wget http://repos.openhpc.community/dist/3.1/OpenHPC-3.1.EL_9.x86_64.tar
mkdir -p $ohpc_repo_dir
tar xvf OpenHPC-3.1.EL_9.x86_64.tar -C $ohpc_repo_dir
$ohpc_repo_dir/make_repo.sh

# Verify OpenHPC repository has been enabled before proceeding

dnf repolist | grep -q OpenHPC
if [ $? -ne 0 ];then
   echo "Error: OpenHPC repository must be enabled locally"
   exit 1
fi
 dnf -y install epel-release
 dnf -y install ohpc-base
# Enable NTP services on SMS host
systemctl enable chronyd.service
echo "local stratum 10" >> /etc/chrony.conf
echo "server ${ntp_server}" >> /etc/chrony.conf
echo "allow all" >> /etc/chrony.conf
systemctl restart chronyd

# -------------------------------------------------------------
# Add resource management services on master node (Section 4.4)
# -------------------------------------------------------------
dnf -y install ohpc-slurm-server
cp /etc/slurm/slurm.conf.ohpc /etc/slurm/slurm.conf
cp /etc/slurm/cgroup.conf.example /etc/slurm/cgroup.conf
perl -pi -e "s/SlurmctldHost=\S+/SlurmctldHost=${sms_name}/" /etc/slurm/slurm.conf

# ----------------------------------------
# Update node configuration for slurm.conf
# ----------------------------------------
if [[ ${update_slurm_nodeconfig} -eq 1 ]];then
     perl -pi -e "s/^NodeName=.+$/#/" /etc/slurm/slurm.conf
     perl -pi -e "s/ Nodes=c\S+ / Nodes=${compute_prefix}[1-${num_computes}] /" /etc/slurm/slurm.conf
     echo -e ${slurm_node_config} >> /etc/slurm/slurm.conf
fi

# -----------------------------------------------------------------------
# Optionally add InfiniBand support services on master node (Section 4.5)
# -----------------------------------------------------------------------
if [[ ${enable_ib} -eq 1 ]];then
     dnf -y groupinstall "InfiniBand Support"
     udevadm trigger --type=devices --action=add
     systemctl restart rdma-load-modules@infiniband.service
fi

# Optionally enable opensm subnet manager
if [[ ${enable_opensm} -eq 1 ]];then
     dnf -y install opensm
     systemctl enable opensm
     systemctl start opensm
fi

# Optionally enable IPoIB interface on SMS
if [[ ${enable_ipoib} -eq 1 ]];then
     # Enable ib0
     cp /opt/ohpc/pub/examples/network/centos/ifcfg-ib0 /etc/sysconfig/network-scripts
     perl -pi -e "s/master_ipoib/${sms_ipoib}/" /etc/sysconfig/network-scripts/ifcfg-ib0
     perl -pi -e "s/ipoib_netmask/${ipoib_netmask}/" /etc/sysconfig/network-scripts/ifcfg-ib0
     echo "[main]"   >  /etc/NetworkManager/conf.d/90-dns-none.conf
     echo "dns=none" >> /etc/NetworkManager/conf.d/90-dns-none.conf
     systemctl start NetworkManager
fi

# ----------------------------------------------------------------------
# Optionally add Omni-Path support services on master node (Section 4.6)
# ----------------------------------------------------------------------
if [[ ${enable_opa} -eq 1 ]];then
     dnf -y install opa-basic-tools
fi

# Optionally enable OPA fabric manager
if [[ ${enable_opafm} -eq 1 ]];then
     dnf -y install opa-fm
     systemctl enable opafm
     systemctl start opafm
fi

# --------------------------------------------------------------------
# Setup nodes repositories and Install OHPC components (Section 4.6.1)
# --------------------------------------------------------------------
nodeshell compute dnf --setopt=\*.skip_if_unavailable=1 -y install dnf-plugins-core perl
nodeshell compute dnf config-manager --enable crb
nodeshell compute dnf config-manager --add-repo=http://$sms_ip/$ohpc_repo_remote_dir/OpenHPC.local.repo
nodeshell compute "perl -pi -e 's/file:\/\/\@PATH\@/http:\/\/$sms_ip\/"${ohpc_repo_remote_dir//\//"\/"}"/s' /etc/yum.repos.d/OpenHPC.local.repo"

# ---------------------------------
# Configure access to EPEL packages
# ---------------------------------
mkdir -p $epel_repo_dir
dnf -y install dnf-plugins-core createrepo
dnf download --destdir $epel_repo_dir fping libconfuse libunwind
createrepo $epel_repo_dir
nodeshell compute dnf config-manager --add-repo=http://$sms_ip/$epel_repo_remote_dir
nodeshell compute "echo gpgcheck=0 >> /etc/yum.repos.d/${sms_ip}_"${epel_repo_remote_dir//\//"_"}.repo
nodeshell compute echo -e %_excludedocs 1 \>\> ~/.rpmmacros

# --------------------------------------------
# Add OpenHPC base components to compute image
# --------------------------------------------
nodeshell compute dnf -y install ohpc-base-compute
# Add OpenHPC components to compute instance
nodeshell compute dnf -y install ohpc-slurm-client
nodeshell compute dnf -y install ntp
nodeshell compute dnf -y install kernel
nodeshell compute dnf -y install  --enablerepo=powertools lmod-ohpc

# ----------------------------------------------
# Customize system configuration (Section 4.6.2)
# ----------------------------------------------
perl -pi -e "s|/tftpboot|#/tftpboot|" /etc/exports
perl -pi -e "s|/install|#/install|" /etc/exports
echo "/home *(rw,no_subtree_check,fsid=10,no_root_squash)" >> /etc/exports
echo "/opt/ohpc/pub *(ro,no_subtree_check,fsid=11)" >> /etc/exports
exportfs -a
systemctl restart nfs-server
systemctl enable nfs-server
nodeshell compute echo "\""${sms_ip}:/home /home nfs nfsvers=3,nodev,nosuid 0 0"\"" \>\> /etc/fstab
nodeshell compute echo "\""${sms_ip}:/opt/ohpc/pub /opt/ohpc/pub nfs nfsvers=3,nodev 0 0"\"" \>\> /etc/fstab
nodeshell compute systemctl restart nfs
nodeshell compute mount /home
nodeshell compute mkdir -p /opt/ohpc/pub
nodeshell compute mount /opt/ohpc/pub

# Update basic slurm configuration if additional computes defined
# This is performed on the SMS, nodes will pick it up config file is copied there later
if [ ${num_computes} -gt 4 ];then
   perl -pi -e "s/^NodeName=(\S+)/NodeName=${compute_prefix}[1-${num_computes}]/" /etc/slurm/slurm.conf
   perl -pi -e "s/^PartitionName=normal Nodes=(\S+)/PartitionName=normal Nodes=${compute_prefix}[1-${num_computes}]/" /etc/slurm/slurm.conf
fi

# Update memlock settings
perl -pi -e 's/# End of file/\* soft memlock unlimited\n$&/s' /etc/security/limits.conf
perl -pi -e 's/# End of file/\* hard memlock unlimited\n$&/s' /etc/security/limits.conf
nodeshell compute perl -pi -e "'s/# End of file/\* soft memlock unlimited\n$&/s' /etc/security/limits.conf"
nodeshell compute perl -pi -e "'s/# End of file/\* hard memlock unlimited\n$&/s' /etc/security/limits.conf"

# Enable slurm pam module
nodeshell compute echo "\""account required pam_slurm.so"\"" \>\> /etc/pam.d/sshd

# Enable Optional packages

if [[ ${enable_lustre_client} -eq 1 ]];then
     # Install Lustre client on master
     dnf -y install lustre-client-ohpc
     # Enable lustre on compute nodes
     nodeshell compute dnf -y install lustre-client-ohpc
     nodeshell compute mkdir /mnt/lustre
     nodeshell compute echo  "\""${mgs_fs_name} /mnt/lustre lustre defaults,_netdev,localflock,retry=2 0 0"\"" \>\> /etc/fstab
     # Enable o2ib for Lustre
     echo "options lnet networks=o2ib(ib0)" >> /etc/modprobe.d/lustre.conf
     nodeshell compute echo "\""options lnet networks=o2ib\(ib0\)"\"" \>\> /etc/modprobe.d/lustre.conf
     # mount Lustre client on master and compute
     mkdir /mnt/lustre
     mount -t lustre -o localflock ${mgs_fs_name} /mnt/lustre
     nodeshell compute mount /mnt/lustre
fi


if [[ ${enable_clustershell} -eq 1 ]];then
     # Install clustershell
     dnf -y install clustershell
     cd /etc/clustershell/groups.d
     mv local.cfg local.cfg.orig
     echo "adm: ${sms_name}" > local.cfg
     echo "compute: ${compute_prefix}[1-${num_computes}]" >> local.cfg
     echo "all: @adm,@compute" >> local.cfg
fi

if [[ ${enable_genders} -eq 1 ]];then
     # Install genders
     dnf -y install genders-ohpc
     echo -e "${sms_name}\tsms" > /etc/genders
     for ((i=0; i<$num_computes; i++)) ; do
        echo -e "${c_name[$i]}\tcompute,bmc=${c_bmc[$i]}"
     done >> /etc/genders
fi

if [[ ${enable_magpie} -eq 1 ]];then
     # Install magpie
     dnf -y install magpie-ohpc
fi

# Optionally, enable conman and configure
if [[ ${enable_ipmisol} -eq 1 ]];then
     dnf -y install conman-ohpc
     for ((i=0; i<$num_computes; i++)) ; do
        echo -n 'CONSOLE name="'${c_name[$i]}'" dev="ipmi:'${c_bmc[$i]}'" '
        echo 'ipmiopts="'U:${bmc_username},P:${IPMI_PASSWORD:-undefined},W:solpayloadsize'"'
     done >> /etc/conman.conf
     systemctl enable conman
     systemctl start conman
fi

# Optionally, enable nhc and configure
dnf -y install nhc-ohpc
nodeshell compute dnf -y install nhc-ohpc

echo "HealthCheckProgram=/usr/sbin/nhc" >> /etc/slurm/slurm.conf
echo "HealthCheckInterval=300" >> /etc/slurm/slurm.conf  # execute every five minutes

# ---------------------------------------
# Install Development Tools (Section 5.1)
# ---------------------------------------
dnf -y install ohpc-autotools
dnf -y install EasyBuild-ohpc
dnf -y install hwloc-ohpc
dnf -y install spack-ohpc
dnf -y install valgrind-ohpc

# -------------------------------
# Install Compilers (Section 5.2)
# -------------------------------
dnf -y install gnu13-compilers-ohpc

# --------------------------------
# Install MPI Stacks (Section 5.3)
# --------------------------------
if [[ ${enable_mpi_defaults} -eq 1 ]];then
     dnf -y install openmpi5-pmix-gnu13-ohpc mpich-ofi-gnu13-ohpc
fi

if [[ ${enable_ib} -eq 1 ]];then
     dnf -y install mvapich2-gnu13-ohpc
fi
if [[ ${enable_opa} -eq 1 ]];then
     dnf -y install mvapich2-psm2-gnu13-ohpc
fi

# ---------------------------------------
# Install Performance Tools (Section 5.4)
# ---------------------------------------
dnf -y install ohpc-gnu13-perf-tools
dnf -y install lmod-defaults-gnu13-openmpi5-ohpc

# ---------------------------------------------------
# Install 3rd Party Libraries and Tools (Section 5.6)
# ---------------------------------------------------
dnf -y install ohpc-gnu13-serial-libs
dnf -y install ohpc-gnu13-io-libs
dnf -y install ohpc-gnu13-python-libs
dnf -y install ohpc-gnu13-runtimes
if [[ ${enable_mpi_defaults} -eq 1 ]];then
     dnf -y install ohpc-gnu13-mpich-parallel-libs
     dnf -y install ohpc-gnu13-openmpi5-parallel-libs
fi
if [[ ${enable_ib} -eq 1 ]];then
     dnf -y install ohpc-gnu13-mvapich2-parallel-libs
fi
if [[ ${enable_opa} -eq 1 ]];then
     dnf -y install ohpc-gnu13-mvapich2-parallel-libs
fi

# ----------------------------------------
# Install Intel oneAPI tools (Section 5.7)
# ----------------------------------------
if [[ ${enable_intel_packages} -eq 1 ]];then
     dnf -y install intel-oneapi-toolkit-release-ohpc
     rpm --import https://yum.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB
     dnf -y install intel-compilers-devel-ohpc
     dnf -y install intel-mpi-devel-ohpc
     if [[ ${enable_opa} -eq 1 ]];then
          dnf -y install mvapich2-psm2-intel-ohpc
     fi
     dnf -y install openmpi5-pmix-intel-ohpc
     dnf -y install ohpc-intel-serial-libs
     dnf -y install ohpc-intel-geopm
     dnf -y install ohpc-intel-io-libs
     dnf -y install ohpc-intel-perf-tools
     dnf -y install ohpc-intel-python3-libs
     dnf -y install ohpc-intel-mpich-parallel-libs
     dnf -y install ohpc-intel-mvapich2-parallel-libs
     dnf -y install ohpc-intel-openmpi5-parallel-libs
     dnf -y install ohpc-intel-impi-parallel-libs
fi

# ------------------------------------
# Resource Manager Startup (Section 6)
# ------------------------------------
nodersync /etc/slurm/slurm.conf compute:/etc/slurm/slurm.conf
nodersync /etc/munge/munge.key compute:/etc/munge/munge.key
systemctl enable munge
systemctl enable slurmctld
systemctl start munge
systemctl start slurmctld
nodeshell compute systemctl enable munge
nodeshell compute systemctl enable slurmd
nodeshell compute systemctl start munge
nodeshell compute systemctl start slurmd
useradd -m test
#echo "MERGE:" > syncusers
#echo "/etc/passwd -> /etc/passwd" >> syncusers
#echo "/etc/group -> /etc/group"       >> syncusers
#echo "/etc/shadow -> /etc/shadow" >> syncusers
#xdcp compute -F syncusers
nodersync /etc/passwd /etc/group /etc/shadow compute:/etc/


