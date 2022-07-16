#!/bin/bash
# Program: cdp-deploy.sh
# Description: wrapper controlling the cdp deployment

err_msg() {

  echo "ERROR: $0 failed at `date`"
  echo "ErrMsg: $1"
  exit 1

}

# various checks to ensure deployment readiness
verify_setup() {

  # Check if the paywall username/password has values, otherwise quit the script
  export TOQUIT=0
  #if [ -n "${REMOTE_PARCELS}" ]
  #then
  #    if [ -z "${PWALL_USER}" ];
  #    then
  #        echo "Please set a valid username for your PWALL_USER in repo.env"
  #        export TOQUIT=1
  #    fi
  #    if [ -z "${PWALL_PASS}" ];
  #    then
  #        echo "Please set a valid password for your PWALL_PASS in repo.env"
  #        export TOQUIT=1
  #    fi
  #fi
  
  # Check that we are the root user
  whoami | grep root > /dev/null
  if [ $? -ne 0 ]
  then
    echo "You need to run this script as the root user, or with sudo."
    export TOQUIT=1
  fi

  # If any of the above failed, then we need to quit
  if [ ${TOQUIT} -eq 1 ]
  then
    echo ""
    echo "Exiting..."
    exit 1
  fi

  # Make sure we have curl and wget installed
  yum -y install curl wget dmidecode

  # Set TimeZone
  ln -sf /usr/share/zoneinfo/${LOCALTZ} /etc/localtime

  # Find out if we are running on a specific cloud provider
  #dmidecode | grep -i 'Asset Tag: Amazon EC2'
  #if [ $? -eq 0 ] # we are on AWS
  #then
  #    export FQDN=$(curl -s ipinfo.io/hostname)
  #    if [ $? -ne 0 ]
  #    then
  #        export FQDN=$(curl -s ipinfo.io/ip)
  #    fi
  #fi

  # Check that we are running on CentOS7
  cat /etc/os-release | grep VERSION_ID | grep 7 > /dev/null;
  if [ $? -ne 0 ]
  then
      echo "This system must be a CentOS7/RHEL7 based installation."
      echo ""
      echo "Suggested cloud image names:"
      echo "AWS: ami-ee6a718a "
      echo ""
      echo "Quitting...."
      exit 1;
  fi

}

# environment changes for the deployment
env_setup() {
  
  # Disable SELinux
  setenforce 0 > /dev/null 2> /dev/null
  sed -i 's/enforcing/disabled/' /etc/sysconfig/selinux
  
  # Disable Transparent Hugepages
  echo never > /sys/kernel/mm/transparent_hugepage/defrag
  echo never > /sys/kernel/mm/transparent_hugepage/enabled

}

# run postgres as the backend RDBMS metadata repository for all the services
setup_postgres() {

# Setup PostgreSQL 10 repo, and install
yum -y install https://download.postgresql.org/pub/repos/yum/reporpms/EL-7-x86_64/pgdg-redhat-repo-latest.noarch.rpm
yum -y install postgresql10-server postgresql10
wget -O - https://jdbc.postgresql.org/download/postgresql-42.2.9.jar > /usr/lib/postgresql-jdbc.jar
/usr/pgsql-10/bin/postgresql-10-setup initdb

# Allow listeners from any host
sed -e 's,#listen_addresses = \x27localhost\x27,listen_addresses = \x27*\x27,g' -i /var/lib/pgsql/10/data/postgresql.conf

# Increase number of connections
sed -e 's,max_connections = 100,max_connections = 300,g' -i  /var/lib/pgsql/10/data/postgresql.conf

# Save the original & replace with a new pg_hba.conf
mv /var/lib/pgsql/10/data/pg_hba.conf /var/lib/pgsql/10/data/pg_hba.conf.backup

# Setup the new pg_hba.conf file
cat > /var/lib/pgsql/10/data/pg_hba.conf << EOF
  # TYPE  DATABASE        USER            ADDRESS                 METHOD
  local   all             all                                     peer
  host    scm             scm             0.0.0.0/0               md5
  host    das             das             0.0.0.0/0               md5
  host    hive            hive            0.0.0.0/0               md5
  host    hue             hue             0.0.0.0/0               md5
  host    oozie           oozie           0.0.0.0/0               md5
  host    ranger          rangeradmin     0.0.0.0/0               md5
  host    rman            rman            0.0.0.0/0               md5
  host    streamsmsgmgr   streamsmsgmgr   0.0.0.0/0               md5
  host    registry        registry        0.0.0.0/0               md5
  host    activitymonitor activitymonitor 0.0.0.0/0               md5
  host    schemaregistry  schemaregistry  0.0.0.0/0               md5
EOF

chown postgres:postgres /var/lib/pgsql/10/data/pg_hba.conf;
chmod 600 /var/lib/pgsql/10/data/pg_hba.conf

# Enable and start PostgreSQL
systemctl enable postgresql-10.service
systemctl start postgresql-10.service

# Create a DDL file for all our DBs
cat > /tmp/create_ddl_cdp.sql << EOF
CREATE ROLE activitymonitor LOGIN PASSWORD 'supersecret1';
CREATE ROLE das LOGIN PASSWORD 'supersecret1';
CREATE ROLE hive LOGIN PASSWORD 'supersecret1';
CREATE ROLE hue LOGIN PASSWORD 'supersecret1';
CREATE ROLE oozie LOGIN PASSWORD 'supersecret1';
CREATE ROLE rangeradmin LOGIN PASSWORD 'supersecret1';
CREATE ROLE rman LOGIN PASSWORD 'supersecret1';
CREATE ROLE scm LOGIN PASSWORD 'supersecret1';
CREATE ROLE streamsmsgmgr LOGIN PASSWORD 'supersecret1';
CREATE ROLE registry LOGIN PASSWORD 'supersecret1';
CREATE ROLE schemaregistry LOGIN PASSWORD 'supersecret1';
CREATE DATABASE activitymonitor OWNER activitymonitor ENCODING 'UTF-8';
CREATE DATABASE das OWNER das ENCODING 'UTF-8';
CREATE DATABASE hive OWNER hive ENCODING 'UTF-8';
CREATE DATABASE hue OWNER hue ENCODING 'UTF-8';
CREATE DATABASE oozie OWNER oozie ENCODING 'UTF-8';
CREATE DATABASE ranger OWNER rangeradmin ENCODING 'UTF-8';
CREATE DATABASE rman OWNER rman ENCODING 'UTF-8';
CREATE DATABASE scm OWNER scm ENCODING 'UTF-8';
CREATE DATABASE streamsmsgmgr OWNER scm ENCODING 'UTF-8';
CREATE DATABASE registry OWNER scm ENCODING 'UTF-8';
CREATE DATABASE schemaregistry OWNER schemaregistry ENCODING 'UTF-8';
EOF

# Run the sql file to create the schema for all DB’s
su - postgres -c 'psql < /tmp/create_ddl_cdp.sql'

}

# Install additional dependencies
install_setup_deps() {

  yum --nogpgcheck -y install java-1.8.0-openjdk-devel mlocate telnet at jq rng-tools vim nc python3-pip.noarch

  # We'll need atd later on to schedule additional steps
  systemctl enable atd
  systemctl start atd

  systemctl enable rngd
  systemctl start rngd

}

# Download Cloudera Manager repo and install
download_cm() {

  if [ -n "${PWALL_USER}" ] || [ -n "${PWALL_PASS}" ]
  then
    if [ -z "${PWALL_USER}" ] || [ -z "${PWALL_PASS}" ]
    then
      err_msg "PWALL_USER and PWALL_PASS require to be set if you have a valid license"
    fi
    wget $CM_BASEURL/cloudera-manager.repo -P /etc/yum.repos.d/
    sed -e "s,username=changeme,username="${PWALL_USER}",g" -i /etc/yum.repos.d/cloudera-manager.repo
    sed -e "s,password=changeme,password="${PWALL_PASS}",g" -i /etc/yum.repos.d/cloudera-manager.repo
    #sed -i "s/archive/${PWALL_USER}:${PWALL_PASS}@archive/g" /etc/yum.repos.d/cloudera-manager.repo
  else
    wget $CM_BASEURL/cloudera-manager-trial.repo -P /etc/yum.repos.d/
  fi
  # Import the GPG Key
  rpm --import $CM_BASEURL/RPM-GPG-KEY-cloudera

}

# Install CM Server & Agent
install_cm() {
  if [ ${LOCALREPO} -eq 1 ]
  then
    yum -y install ${LOCAL_CM_SERVER} cloudera-manager-agent
    yum -y install cloudera-manager-server
  else
    yum -y install cloudera-manager-server cloudera-manager-agent
  fi
}

# Run the prepare script for SCM db
prep_scm_db() {
  /opt/cloudera/cm/schema/scm_prepare_database.sh postgresql scm scm supersecret1
}

# Setup AutoTLS for Cloudera Manager and Services
setup_autotls() {
  #JAVA_HOME=/usr/lib/jvm/java-1.8.0-openjdk/ /opt/cloudera/cm-agent/bin/certmanager --location /opt/cloudera/CMCA setup --configure-services
  echo "AutoTLS - TBD"
}

# Download CSDs to /opt/cloudera/csd
download_cfm_csds() {

  if [ ${CDPONLY} -eq 0 ]
  then
    if [ -n "${CFM_NIFI_CSD_URL}" ]; then wget ${CFM_NIFI_CSD_URL} -P /opt/cloudera/csd/; fi
    if [ -n "${STREAMS_MESSAGING_MANAGER_CSD_URL}" ]; then wget ${STREAMS_MESSAGING_MANAGER_CSD_URL} -P /opt/cloudera/csd/; fi
    if [ -n "${SCHEMAREGISTRY_CSD_URL}" ]; then wget ${SCHEMAREGISTRY_CSD_URL} -P /opt/cloudera/csd/; fi
    if [ -n "${CFM_NIFIREG_CSD_URL}" ]; then wget ${CFM_NIFIREG_CSD_URL} -P /opt/cloudera/csd/; fi
    chown cloudera-scm:cloudera-scm -R /opt/cloudera/csd/*
  fi

}

# Start the CM services
start_cm() {

  # Start the Cloudera Node Agent
  systemctl enable cloudera-scm-agent
  systemctl start cloudera-scm-agent

  # Start the CM Server
  systemctl enable cloudera-scm-server
  systemctl start cloudera-scm-server
  echo "Please wait while Cloudera Manager Server starts up:"

  # Wait for CM to run on port 7183
  RET=1
  while [ $RET -eq 1 ]; do
    echo -n .; sleep 2
    echo "" | nc -v localhost ${CM_PORT} > /dev/null 2> /dev/null
    RET=$?
  done
}

# Setup license if have one
install_license() {
  curl -i -X POST -F license=@license/license.txt -u ${CM_USER}:${CM_PASS} -H "Content-Type:multipart/form-data" ${CM_PROTOCOL}://${FQDN}:${CM_PORT}/api/${APIV}/cm/license
}

# Setup the template for installation
setup_deployment_template() {

  if [ ${CDPONLY} -eq 1 ]
  then
    # Install only Base CDP, no CDF
    cat cluster_template_base.json > ${TMP_DT_FILE}
  else
    # Install CDP and CDF
    cat cluster_template_full.json > ${TMP_DT_FILE}
  fi

  sed  -i "s/xxCM_VERSIONxx/${CM_VERSION}/g" ${TMP_DT_FILE}
  sed  -i "s/xxCDP_VERSIONxx/${CDP_VERSION}/g" ${TMP_DT_FILE}
  sed  -i "s/xxCDP_FULL_VERSIONxx/${CDP_FULL_VERSION}/g" ${TMP_DT_FILE}
  sed  -i "s/xxFQDNxx/${FQDN}/g" ${TMP_DT_FILE}
  sed  -i "s/xxPWxx/supersecret1/g" ${TMP_DT_FILE}

}

# Setup Cloudera Manager Python3 SDK
setup_cm_sdk() {
  pip3 install cm_client
}

# Install CMS and CDP clusters
install_cms_and_cdp() {

  if [ ${LOCALREPO} -eq 1 ]
  then
    python3 cm_install.py --hostname $FQDN --cdponly ${CDPONLY} --localrepo ${LOCALREPO} --parcelsuri ${LOCAL_PARCELS} --cmprotocol ${CM_PROTOCOL} --cmport ${CM_PORT} --license ${LICENSE} --apiversion ${APIV}
  else
    if [ -n "${REMOTE_PARCELS}" ]
    then
        python3 cm_install.py --hostname $FQDN --cdponly ${CDPONLY} --localrepo ${LOCALREPO} --parcelsuri ${REMOTE_PARCELS} --cmprotocol ${CM_PROTOCOL} --cmport ${CM_PORT} --license ${LICENSE} --apiversion ${APIV}
    else
        python3 cm_install.py --hostname $FQDN --cdponly ${CDPONLY} --localrepo ${LOCALREPO} --cmprotocol ${CM_PROTOCOL} --cmport ${CM_PORT} --license ${LICENSE} --apiversion ${APIV}
    fi
  fi

}

# Post install/setup bits and pieces
epilogue() {

  CM_INSTALL_INFO_FILE=/root/cm_install.txt
  if [ ! -f ${CM_INSTALL_INFO_FILE} ]
  then
    echo ""
    echo "Add the following to your hosts file:" | tee -a ${CM_INSTALL_INFO_FILE}
    ipaddr=$(hostname -I | awk '{print $1}')
    echo ${ipaddr} | grep '192.168.0.' > /dev/null
    if [ $? -eq 0 ]
    then
        echo "${ipaddr} $(hostname -f)" | tee -a ${CM_INSTALL_INFO_FILE}
    else
        ipaddr=$(curl -s ipinfo.io/ip)
        echo "${ipaddr} ${FQDN}" | tee -a ${CM_INSTALL_INFO_FILE}
    fi
    echo "" | tee -a ${CM_INSTALL_INFO_FILE} 
    
    echo "You can now browse to: ${CM_PROTOCOL}://${FQDN}:${CM_PORT}" | tee -a ${CM_INSTALL_INFO_FILE}
    echo "username: ${CM_USER}" | tee -a ${CM_INSTALL_INFO_FILE}
    echo "password: ${CM_PASS}" | tee -a ${CM_INSTALL_INFO_FILE}
    
    echo "echo '" >> /root/.bash_profile
    cat ${CM_INSTALL_INFO_FILE}  >> /root/.bash_profile
    echo "'" >> /root/.bash_profile
    
  fi
 
  echo "Cluster installation will take a little while to complete"
  echo ""
  echo "Note - if the install_cms_and_cdp step fails, you may need to cleanup the following in CM before rerunning:"
  echo ""
  echo "       * delete CMS"
  echo "       * delete the host"
  echo '       * delete the "singlenode" cluster'
  echo ""

}

# Main

# Check that we "in" our directory
ls -l cdp-deploy.sh > /dev/null 2> /dev/null
if [ $? -ne 0 ]
then
  BASEDIR=$(dirname "$0")
  cd ${BASEDIR}
fi

# Setup script variables - note some in repo.env file
source repo.env
export FQDNx="$(hostname -f)" # There will be an annoying space added to the end. Next command will clear it with xargs
export FQDN=$(echo $FQDNx | xargs)
export TMP_DT_FILE=/tmp/cluster_template.json

# TBD - ensure this only runs once - this is currently not being used
# Generate a 12 char random password
RAND_STRING="a$(echo "$(date)$(hostname)" | md5sum);"
RAND_PW=$(echo ${RAND_STRING:0:12})

# bit brutal - for rerunnability
rm -f /etc/yum.repos.d/cloudera-manager*.repo

verify_setup                    # checks pre deployment
env_setup                       # env settings for the deployment

setup_postgres                  # postgres used as the backing rdbms
#setup_mariadb                  # TBC

install_setup_deps              # install deps including jdk

download_cm                     # download the cm packages
install_cm                      # install cm server, daemons and agents
prep_scm_db                     # install the scm database
setup_autotls                   # TBC
download_cfm_csds               # for nifi and streaming 
start_cm                        # start CM

install_license                 # install the license via a file if available and enabled in repo.env file

setup_deployment_template       # replace version specific patterns in the deployment template
setup_cm_sdk                    # use the cm python api client to set some of this up
install_cms_and_cdp             # calls cm_install.py python script to install CMS and CDP

epilogue                        # completion messages

